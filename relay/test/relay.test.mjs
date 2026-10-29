// Protocol test against a running relay (default: `npm run dev` on :8787).
// RELAY=wss://... node test/relay.test.mjs  to test a deployed one.
import { generateKeyPairSync, createHash, sign } from "node:crypto";

const BASE = process.env.RELAY || "ws://127.0.0.1:8787";
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
let failures = 0;

function codeFor(pem) {
	const d = createHash("sha256").update(pem.trim()).digest();
	let bits = 0n;
	for (let i = 0; i < 7; i++) bits = (bits << 8n) | BigInt(d[i]);
	let out = "";
	for (let i = 0; i < 10; i++) out += ALPHABET[Number((bits >> BigInt(51 - 5 * i)) & 31n)];
	return out.slice(0, 5) + "-" + out.slice(5);
}

function identity(name) {
	const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
	const pub = publicKey.export({ type: "spki", format: "pem" });
	return { name, pub, privateKey, code: codeFor(pub) };
}

function check(label, ok) {
	console.log(`${ok ? "PASS" : "FAIL"} ${label}`);
	if (!ok) failures++;
}

class Client {
	constructor(id, { badSignature = false } = {}) {
		this.id = id;
		this.inbox = [];
		this.closed = null;
		this.ws = new WebSocket(`${BASE}/v1/connect?code=${id.code}`);
		this.ws.onmessage = (e) => {
			const m = JSON.parse(e.data);
			if (m.type === "challenge") {
				const sig = sign("sha256", Buffer.from(m.nonce, "base64"), id.privateKey);
				if (badSignature) sig[10] ^= 0xff;
				this.send({ type: "auth", sig: sig.toString("base64") });
			} else {
				this.inbox.push(m);
			}
		};
		this.ws.onclose = (e) => (this.closed = e.code);
		this.ws.onopen = () => this.send({ type: "hello", pub: id.pub, name: id.name, version: "test" });
	}
	send(obj) {
		this.ws.send(JSON.stringify(obj));
	}
	async waitFor(pred, ms = 3000) {
		const end = Date.now() + ms;
		while (Date.now() < end) {
			const i = this.inbox.findIndex(pred);
			if (i >= 0) return this.inbox.splice(i, 1)[0];
			await new Promise((r) => setTimeout(r, 25));
		}
		return null;
	}
}

const A = identity("Alpha"), B = identity("Bravo"), C = identity("Charlie");
const a = new Client(A), b = new Client(B), c = new Client(C);
check("A signs in", !!(await a.waitFor((m) => m.type === "welcome")));
check("B signs in", !!(await b.waitFor((m) => m.type === "welcome")));
check("C signs in", !!(await c.waitFor((m) => m.type === "welcome")));
b.send({ type: "friends", codes: [] });
c.send({ type: "friends", codes: [] });
await b.waitFor((m) => m.type === "friends");

a.send({ type: "friends", codes: [B.code] });
const req = await b.waitFor((m) => m.type === "request");
check("adding B sends B a friend request from A", req && req.code === A.code && req.name === "Alpha");
const aSnap = await a.waitFor((m) => m.type === "friends");
check("A can't see B's status before B adds A back", aSnap && aSnap.friends.length === 0);

b.send({ type: "friends", codes: [A.code] });
const bSnap = await b.waitFor((m) => m.type === "friends");
check("once mutual, B sees A online", bSnap && bSnap.friends.some((p) => p.code === A.code && p.online));
const seeB = await a.waitFor((m) => m.type === "presence" && m.code === B.code);
check("and A is told B is online", seeB && seeB.online === true);

a.send({ type: "status", state: "hosting", detail: { players: 1, max: 4, address: "203.0.113.7", port: 47820 } });
const host = await b.waitFor((m) => m.type === "presence" && m.code === A.code && m.state === "hosting");
check("B sees A hosting with the address", host && host.detail.address === "203.0.113.7" && host.detail.port === 47820);
check("C (not a friend) sees nothing", !(await c.waitFor((m) => m.type === "presence", 600)));

a.send({ type: "invite", to: B.code, address: "203.0.113.7", port: 47820 });
const inv = await b.waitFor((m) => m.type === "invite");
check("A's invite reaches B", inv && inv.code === A.code && inv.address === "203.0.113.7");
c.send({ type: "invite", to: B.code, address: "198.51.100.1", port: 1 });
check("C can't invite B (not mutual)", !(await b.waitFor((m) => m.type === "invite", 600)));

b.ws.close();
const off = await a.waitFor((m) => m.type === "presence" && m.code === B.code && m.online === false);
check("A sees B go offline with a last-seen time", off && off.last_seen > 0);

const b2 = new Client(B);
await b2.waitFor((m) => m.type === "welcome");
b2.send({ type: "friends", codes: [A.code] });
const back = await a.waitFor((m) => m.type === "presence" && m.code === B.code && m.online === true);
check("B reconnecting shows online again", !!back);

const evil = new Client(identity("Mallory"), { badSignature: true });
await new Promise((r) => setTimeout(r, 1500));
check("a bad signature is refused", evil.closed !== null && !evil.inbox.some((m) => m.type === "welcome"));

for (const x of [a, b2, c]) x.ws.close();
console.log(failures ? `${failures} FAILED` : "all relay checks passed");
process.exit(failures ? 1 : 0);
