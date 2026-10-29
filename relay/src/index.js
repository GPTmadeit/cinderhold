// Cinderhold friend relay.
//
// Players connect over a WebSocket (wss), prove who they are by signing a
// random challenge with their game identity key (the same key and friend
// code the game uses for encrypted co-op), and then:
//   - publish their status (in the menu, in a lobby, hosting, in a match),
//   - see the status of friends who have added them back (mutual friends),
//   - send friend requests (adding someone who hasn't added you yet),
//   - invite mutual friends into a game they're hosting.
//
// One Durable Object ("global") holds every socket. Sockets hibernate while
// idle, keep-alive pings are answered without waking it, and everything a
// socket needs survives hibernation in its attachment, so this fits the
// free plan comfortably. Storage keeps only friend lists, last-seen times
// and pending friend requests.

import { DurableObject } from "cloudflare:workers";

const MAX_MESSAGE = 4096;
const MAX_FRIENDS = 100;
const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const CODE_RE = /^[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$/;
const STATES = new Set(["menu", "lobby", "hosting", "playing"]);
const RATE = 3;        // messages per second, sustained
const BURST = 30;

export default {
	async fetch(request, env) {
		const url = new URL(request.url);
		if (url.pathname === "/v1/connect") {
			if (request.headers.get("Upgrade") !== "websocket") {
				return new Response("Expected a WebSocket upgrade\n", { status: 426 });
			}
			const code = (url.searchParams.get("code") || "").toUpperCase();
			if (!CODE_RE.test(code)) {
				return new Response("Bad friend code\n", { status: 400 });
			}
			return env.HUB.get(env.HUB.idFromName("global")).fetch(request);
		}
		if (url.pathname === "/") {
			return new Response("Cinderhold friend relay\n", { headers: { "content-type": "text/plain" } });
		}
		return new Response("Not found\n", { status: 404 });
	},
};

export class Hub extends DurableObject {
	constructor(ctx, env) {
		super(ctx, env);
		// keep-alive: answered without waking the object
		this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
	}

	async fetch(request) {
		const code = new URL(request.url).searchParams.get("code").toUpperCase();
		const pair = new WebSocketPair();
		const [client, server] = Object.values(pair);
		// tagged with the claimed code so the player's sockets can be found;
		// nothing counts until the challenge has been signed
		this.ctx.acceptWebSocket(server, [code]);
		server.serializeAttachment({ stage: "new", code, tokens: BURST, t: Date.now() });
		return new Response(null, { status: 101, webSocket: client });
	}

	async webSocketMessage(ws, message) {
		const me = ws.deserializeAttachment() || {};
		if (typeof message !== "string" || message.length > MAX_MESSAGE) {
			ws.close(1009, "message too big");
			return;
		}
		// token bucket
		const now = Date.now();
		me.tokens = Math.min(BURST, (me.tokens ?? BURST) + ((now - (me.t ?? now)) / 1000) * RATE);
		me.t = now;
		if (me.tokens < 1) {
			ws.close(1008, "slow down");
			return;
		}
		me.tokens -= 1;
		let msg;
		try {
			msg = JSON.parse(message);
		} catch {
			ws.close(1007, "bad message");
			return;
		}
		try {
			await this.handle(ws, me, msg);
		} catch (err) {
			this.send(ws, { type: "error", message: "server error" });
		}
	}

	async handle(ws, me, msg) {
		if (me.stage === "new" && msg.type === "hello") {
			const pub = String(msg.pub || "").trim();
			if (pub.length > 1200 || (await codeFor(pub)) !== me.code) {
				ws.close(1008, "code does not match key");
				return;
			}
			const nonce = crypto.getRandomValues(new Uint8Array(32));
			Object.assign(me, { stage: "challenged", pub, nonce: b64(nonce), name: cleanName(msg.name) });
			ws.serializeAttachment(me);
			this.send(ws, { type: "challenge", nonce: me.nonce });
			return;
		}
		if (me.stage === "challenged" && msg.type === "auth") {
			const ok = await verify(me.pub, unb64(me.nonce), unb64(String(msg.sig || "")));
			if (!ok) {
				ws.close(1008, "signature check failed");
				return;
			}
			// one session per player: a newer connection replaces an older one
			for (const other of this.ctx.getWebSockets(me.code)) {
				if (other !== ws && (other.deserializeAttachment() || {}).stage === "ready") {
					other.serializeAttachment({ stage: "closed", code: me.code });
					other.close(4000, "signed in elsewhere");
				}
			}
			const ready = { stage: "ready", code: me.code, name: me.name, state: "menu", detail: {}, since: Date.now(), tokens: me.tokens, t: me.t };
			ws.serializeAttachment(ready);
			await this.ctx.storage.put("name:" + me.code, me.name);
			this.send(ws, { type: "welcome", code: me.code });
			return;
		}
		if (me.stage !== "ready") {
			ws.close(1008, "sign in first");
			return;
		}
		ws.serializeAttachment(me);
		switch (msg.type) {
			case "friends":
				await this.setFriends(ws, me, msg.codes);
				break;
			case "status":
				await this.setStatus(ws, me, msg);
				break;
			case "invite":
				await this.invite(me, msg);
				break;
			case "dismiss":
				if (CODE_RE.test(String(msg.code || ""))) {
					await this.ctx.storage.delete(`req:${me.code}:${msg.code}`);
				}
				break;
			default:
				this.send(ws, { type: "error", message: "unknown message" });
		}
	}

	// The player's friend list. Mutual friends see each other's status;
	// anyone listed who hasn't listed us back gets a friend request.
	async setFriends(ws, me, codes) {
		if (!Array.isArray(codes)) return;
		const list = [...new Set(codes.map((c) => String(c).toUpperCase()).filter((c) => CODE_RE.test(c) && c !== me.code))].slice(0, MAX_FRIENDS);
		const before = (await this.ctx.storage.get("friends:" + me.code)) || [];
		await this.ctx.storage.put("friends:" + me.code, list);
		const first = !me.listed;
		me.listed = true;
		ws.serializeAttachment(me);
		// whoever we dropped stops seeing us
		for (const gone of before.filter((c) => !list.includes(c))) {
			this.sendTo(gone, { type: "presence", code: me.code, name: me.name, online: false, gone: true });
		}
		const snapshot = [];
		for (const f of list) {
			const theirs = (await this.ctx.storage.get("friends:" + f)) || [];
			if (theirs.includes(me.code)) {
				await this.ctx.storage.delete(`req:${me.code}:${f}`);
				await this.ctx.storage.delete(`req:${f}:${me.code}`);
				snapshot.push(await this.presenceOf(f));
				if (first || !before.includes(f)) {
					this.sendTo(f, this.presence(me, true));
				}
			} else if (!before.includes(f)) {
				await this.ctx.storage.put(`req:${f}:${me.code}`, { name: me.name, at: Date.now() });
				this.sendTo(f, { type: "request", code: me.code, name: me.name });
			}
		}
		this.send(ws, { type: "friends", friends: snapshot });
		if (first) {
			// requests that arrived while we were away
			const pending = await this.ctx.storage.list({ prefix: `req:${me.code}:` });
			for (const [key, value] of pending) {
				const from = key.split(":")[2];
				if (!list.includes(from)) {
					this.send(ws, { type: "request", code: from, name: value.name });
				}
			}
		}
	}

	async setStatus(ws, me, msg) {
		const state = String(msg.state || "");
		if (!STATES.has(state)) return;
		const d = msg.detail || {};
		const detail = {};
		for (const k of ["players", "max", "round", "port"]) {
			if (Number.isInteger(d[k]) && d[k] >= 0 && d[k] < 100000) detail[k] = d[k];
		}
		if (typeof d.address === "string" && d.address.length <= 64) detail.address = d.address;
		if (typeof d.map === "string" && d.map.length <= 32) detail.map = d.map;
		if (state === me.state && JSON.stringify(detail) === JSON.stringify(me.detail)) return;
		me.state = state;
		me.detail = detail;
		me.since = Date.now();
		ws.serializeAttachment(me);
		for (const f of await this.mutual(me.code)) {
			this.sendTo(f, this.presence(me, true));
		}
	}

	async invite(me, msg) {
		const to = String(msg.to || "").toUpperCase();
		if (!CODE_RE.test(to) || !(await this.isMutual(me.code, to))) return;
		const address = typeof msg.address === "string" ? msg.address.slice(0, 64) : "";
		const port = Number.isInteger(msg.port) ? msg.port : 0;
		this.sendTo(to, { type: "invite", code: me.code, name: me.name, address, port });
	}

	async webSocketClose(ws) {
		await this.gone(ws);
	}

	async webSocketError(ws) {
		await this.gone(ws);
	}

	async gone(ws) {
		const me = ws.deserializeAttachment() || {};
		if (me.stage !== "ready") return;
		ws.serializeAttachment({ stage: "closed", code: me.code });
		// still online through another socket?
		if (this.readySockets(me.code).length > 0) return;
		const seen = Date.now();
		await this.ctx.storage.put("seen:" + me.code, seen);
		for (const f of await this.mutual(me.code)) {
			this.sendTo(f, { type: "presence", code: me.code, name: me.name, online: false, last_seen: seen });
		}
	}

	// --- helpers --------------------------------------------------------

	presence(me, online) {
		return { type: "presence", code: me.code, name: me.name, online, state: me.state, detail: me.detail, since: me.since };
	}

	async presenceOf(code) {
		const live = this.readySockets(code)[0];
		if (live) return this.presence(live.deserializeAttachment(), true);
		return {
			type: "presence", code, online: false,
			name: (await this.ctx.storage.get("name:" + code)) || "",
			last_seen: (await this.ctx.storage.get("seen:" + code)) || 0,
		};
	}

	async isMutual(a, b) {
		const la = (await this.ctx.storage.get("friends:" + a)) || [];
		if (!la.includes(b)) return false;
		const lb = (await this.ctx.storage.get("friends:" + b)) || [];
		return lb.includes(a);
	}

	async mutual(code) {
		const mine = (await this.ctx.storage.get("friends:" + code)) || [];
		const out = [];
		for (const f of mine) {
			const theirs = (await this.ctx.storage.get("friends:" + f)) || [];
			if (theirs.includes(code)) out.push(f);
		}
		return out;
	}

	readySockets(code) {
		return this.ctx.getWebSockets(code).filter((s) => (s.deserializeAttachment() || {}).stage === "ready");
	}

	sendTo(code, obj) {
		for (const s of this.readySockets(code)) this.send(s, obj);
	}

	send(ws, obj) {
		try {
			ws.send(JSON.stringify(obj));
		} catch {
			// socket already gone
		}
	}
}

// --- identity (matches scripts/core/identity.gd) -----------------------

// The friend code for a public key: 50 bits of SHA-256 over its PEM text,
// in Crockford base32, as XXXXX-XXXXX.
async function codeFor(pem) {
	const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(pem.trim())));
	let bits = 0n;
	for (let i = 0; i < 7; i++) bits = (bits << 8n) | BigInt(digest[i]);
	let out = "";
	for (let i = 0; i < 10; i++) out += CODE_ALPHABET[Number((bits >> BigInt(51 - 5 * i)) & 31n)];
	return out.slice(0, 5) + "-" + out.slice(5);
}

// RSA PKCS#1 v1.5 with SHA-256, as Godot's Crypto.sign() makes them.
async function verify(pem, data, sig) {
	try {
		const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
		const key = await crypto.subtle.importKey("spki", unb64(body), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
		return await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, sig, data);
	} catch {
		return false;
	}
}

function cleanName(name) {
	return String(name || "").replace(/[\u0000-\u001f]/g, "").trim().slice(0, 16) || "Survivor";
}

function b64(bytes) {
	let s = "";
	for (const b of bytes) s += String.fromCharCode(b);
	return btoa(s);
}

function unb64(text) {
	const s = atob(text);
	const out = new Uint8Array(s.length);
	for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
	return out;
}
