extends Node
## Friend status, friend requests, invites and join requests, through the Cinderhold relay
## (relay/ in the repository: a small Cloudflare Worker). Lives under the
## Net service as "Presence".
##
## The connection is a WebSocket over TLS. We sign in by signing the
## relay's random challenge with our identity key, so nobody can use our
## friend code. Friends see our status only once they've added us back; the
## relay never sees game traffic, only: our friend code and name, our friend
## list, what we're doing (menu, lobby, hosting, in a match) and, while we
## host with an open port, the address friends need to join.
##
## Join requests: a friend who sees us hosting can ask to be let in; when we
## say yes, their game connects and opens our lobby by itself. Their game
## only follows a yes to a request it actually sent.

signal changed

const V := preload("res://scripts/core/version.gd")
const Notes := preload("res://scripts/ui/notifications.gd")

## identity.gd and friends.gd as Net runs them (see Net.identity_script())
var Identity
var Friends

## Where the relay runs. Dev runs can point elsewhere with `-- --relay URL`
## or the CINDER_RELAY environment variable.
const RELAY := "wss://cinderhold-relay.cinderhold-relay.workers.dev"
const PING_EVERY := 25.0

enum Link { OFF, CONNECTING, ONLINE }

var link := Link.OFF
## code -> {online, name, state, detail, since, last_seen}, mutual friends only
var statuses := {}
## code -> name: people who added us and wait for us to add them back
var requests := {}
## code -> {name, same_network, t}: friends asking to join the game we host
var join_requests := {}
## code -> when we asked (msec): our join requests still waiting for an answer
var asked := {}

const ASK_TIMEOUT_MS := 60000
const JOIN_REQUEST_TTL_MS := 120000

var _ws: WebSocketPeer
var _retry := 0.0
var _backoff := 2.0
var _ping_t := 0.0
## the friend codes last sent to the relay; the list is resent when it changes
## (compared by content: copies updated from 0.2.0 run an older friends.gd)
var _friends_sent := "-"
var _status_sent := ""
var _status_t := 0.0
var _ready_for_notes := false
var _hello_sent := false


func _enter_tree() -> void:
	Identity = get_parent().identity_script()
	Friends = get_parent().friends_script()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func relay_url() -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--relay")
	if i != -1 and i + 1 < args.size():
		return args[i + 1]
	var env := OS.get_environment("CINDER_RELAY")
	return env if env != "" else RELAY


func enabled() -> bool:
	return bool(Settings.get_v("net", "presence"))


func _process(dt: float) -> void:
	if not enabled():
		if _ws:
			_ws.close()
			_ws = null
			_set_link(Link.OFF)
		return
	if not Identity.ready():
		return
	if _ws == null:
		_retry -= dt
		if _retry <= 0.0:
			_open()
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _hello_sent:
				_hello_sent = true
				_send({"type": "hello", "pub": Identity.public_pem(), "name": Settings.player_name(), "version": V.VERSION})
			while _ws.get_available_packet_count() > 0:
				_receive(_ws.get_packet().get_string_from_utf8())
			if link == Link.ONLINE:
				_ping_t -= dt
				if _ping_t <= 0.0:
					_ping_t = PING_EVERY
					_ws.send_text("ping")
				if _friend_codes_key() != _friends_sent:
					_send_friends()
				_status_t -= dt
				if _status_t <= 0.0:
					_status_t = 1.0
					_send_status()
					_expire_join_requests()
		WebSocketPeer.STATE_CLOSED:
			# 4000: this friend code signed in from another running copy; don't
			# take the session straight back, or the two would trade it forever
			_retry = 300.0 if _ws.get_close_code() == 4000 else _backoff
			_ws = null
			_backoff = minf(_backoff * 2.0, 60.0)
			for code in statuses:
				statuses[code].online = false
			_set_link(Link.CONNECTING)


func _open() -> void:
	_ws = WebSocketPeer.new()
	_ws.outbound_buffer_size = 1 << 16
	var err := _ws.connect_to_url("%s/v1/connect?code=%s" % [relay_url(), Identity.code()])
	if err != OK:
		_ws = null
		_retry = _backoff
		return
	_set_link(Link.CONNECTING)
	_ready_for_notes = false
	_hello_sent = false   # sent once the socket opens


func _send(obj: Dictionary) -> void:
	if _ws and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(obj))


func _receive(text: String) -> void:
	if text == "pong":
		return
	var m = JSON.parse_string(text)
	if not m is Dictionary:
		return
	match str(m.get("type", "")):
		"challenge":
			var nonce := Marshalls.base64_to_raw(str(m.nonce))
			_send({"type": "auth", "sig": Marshalls.raw_to_base64(Identity.sign(nonce))})
		"welcome":
			_backoff = 2.0
			_ping_t = PING_EVERY
			_friends_sent = "-"
			_status_sent = ""
			_set_link(Link.ONLINE)
		"friends":
			for p in m.get("friends", []):
				_update(p, false)
			_ready_for_notes = true
			changed.emit()
		"presence":
			_update(m, _ready_for_notes)
			changed.emit()
		"request":
			var code := str(m.code)
			if not Friends.is_friend(code):
				requests[code] = str(m.get("name", ""))
				changed.emit()
				Notes.post("%s wants to be friends" % _label(code, str(m.get("name", ""))), Notes.FRIEND,
					[["Accept", func(): accept(code)], ["Ignore", func(): ignore(code)]], 20.0)
		"invite":
			var code := str(m.code)
			var addr := _pick_address(m)
			var port := int(m.get("port", 0))
			Notes.post("%s invited you to their game" % _label(code, str(m.get("name", ""))), Notes.INVITE,
				[["Join", func(): _join(code, addr, port)]] if addr != "" else [], 30.0)
		"join_request":
			_on_join_request(m)
		"join_reply":
			_on_join_reply(m)


## A friend's status changed; maybe tell the player.
func _update(p: Dictionary, notify: bool) -> void:
	var code := str(p.get("code", ""))
	if code == "":
		return
	if p.get("gone", false):
		statuses.erase(code)
		return
	var before: Dictionary = statuses.get(code, {})
	var now := {"online": bool(p.get("online", false)), "name": str(p.get("name", "")), "state": str(p.get("state", "")),
		"detail": p.get("detail", {}), "since": float(p.get("since", 0)), "last_seen": float(p.get("last_seen", 0))}
	statuses[code] = now
	if Settings.bot_driving():
		print("PRESENCE %s %s %s" % [code, "online" if now.online else "offline", now.state])
	if now.name != "":
		Friends.touch(code, now.name)
	if not notify or not Friends.is_friend(code):
		return
	var who := _label(code, now.name)
	if now.online and now.state == "hosting" and before.get("state", "") != "hosting":
		var d: Dictionary = now.detail
		var addr := str(d.get("address", ""))
		var port := int(d.get("port", 0))
		Notes.post("%s is hosting (%d/%d)" % [who, int(d.get("players", 1)), int(d.get("max", 4))], Notes.INVITE,
			[["Join", func(): _join(code, addr, port)]] if addr != "" else [], 15.0)
	elif now.online and not before.get("online", false):
		Notes.post("%s is online" % who, Notes.FRIEND, [], 6.0)


func _label(code: String, name: String) -> String:
	var f: Dictionary = Friends.find(code)
	var n: String = name if name != "" else str(f.get("name", ""))
	return n if n != "" else code


func _send_friends() -> void:
	_friends_sent = _friend_codes_key()
	var codes := []
	for f in Friends.all():
		codes.append(f.code)
	_send({"type": "friends", "codes": codes})


func _friend_codes_key() -> String:
	var codes := PackedStringArray()
	for f in Friends.all():
		codes.append(str(f.code))
	return ",".join(codes)


func _send_status() -> void:
	var s := my_status()
	var key := JSON.stringify(s)
	if key != _status_sent:
		_status_sent = key
		_send({"type": "status", "state": s.state, "detail": s.detail})


## What we're doing, as friends will see it.
func my_status() -> Dictionary:
	var net := get_parent()
	var scene := get_tree().current_scene
	if scene and "round_num" in scene and "enemies" in scene:
		return {"state": "playing", "detail": {"round": int(scene.round_num), "players": maxi(net.players.size(), 1), "map": net.match_map()}}
	if not net.solo and net.is_host():
		var d := {"players": net.players.size(), "max": net.MAX_PLAYERS, "map": net.match_map()}
		var ps: Dictionary = net.port_status()
		if ps.get("state", "") == "open" and str(ps.get("public_ip", "")) != "":
			d.address = str(ps.public_ip)
			d.port = int(ps.port)
		return {"state": "hosting", "detail": d}
	if not net.solo and not net.players.is_empty():
		return {"state": "lobby", "detail": {"players": net.players.size()}}
	return {"state": "menu", "detail": {}}


func accept(code: String) -> void:
	Friends.remember(code, requests.get(code, ""))
	requests.erase(code)
	changed.emit()


func ignore(code: String) -> void:
	requests.erase(code)
	_send({"type": "dismiss", "code": code})
	changed.emit()


## Invite a friend into the game we're hosting.
func invite(code: String) -> bool:
	var msg := _where({"type": "invite", "to": code})
	if (msg.address == "" and msg.lan == "") or link != Link.ONLINE:
		return false
	_send(msg)
	return true


## Ask a hosting friend to let us in. When they do, we join on our own.
func request_join(code: String) -> bool:
	if link != Link.ONLINE or not online(code):
		return false
	asked[code] = Time.get_ticks_msec()
	_send({"type": "join_request", "to": code})
	changed.emit()
	return true


## Host: let a friend who asked into our game (they join by themselves).
func let_in(code: String) -> void:
	join_requests.erase(code)
	changed.emit()
	if not _hosting():
		_send({"type": "join_reply", "to": code, "accept": false})
		return
	_send(_where({"type": "join_reply", "to": code, "accept": true}))


func turn_away(code: String) -> void:
	join_requests.erase(code)
	changed.emit()
	_send({"type": "join_reply", "to": code, "accept": false})


func _hosting() -> bool:
	var net := get_parent()
	return not net.solo and net.is_host() and not net.in_game


func _on_join_request(m: Dictionary) -> void:
	var code := str(m.get("code", ""))
	if not Friends.is_friend(code):
		return
	if not _hosting():
		_send({"type": "join_reply", "to": code, "accept": false})
		return
	var name := str(m.get("name", ""))
	join_requests[code] = {"name": name, "same_network": bool(m.get("same_network", false)), "t": Time.get_ticks_msec()}
	changed.emit()
	Notes.post("%s wants to join your game" % _label(code, name), Notes.INVITE,
		[["Let in", func(): let_in(code)], ["Decline", func(): turn_away(code)]], 30.0)


func _on_join_reply(m: Dictionary) -> void:
	var code := str(m.get("code", ""))
	if not asked.has(code):
		return   # never follow a yes to a request we didn't send
	asked.erase(code)
	changed.emit()
	var who := _label(code, str(m.get("name", "")))
	if not bool(m.get("accept", false)):
		Notes.post("%s can't let you in right now." % who, Notes.INFO, [], 6.0)
		return
	var addr := _pick_address(m)
	if addr == "":
		Notes.post("%s let you in, but their game can't be reached from here (their router's port is closed)." % who, Notes.INFO, [], 10.0)
		return
	Notes.post("%s let you in. Joining…" % who, Notes.FRIEND, [], 4.0)
	_join(code, addr, int(m.get("port", 0)))


func _expire_join_requests() -> void:
	var now := Time.get_ticks_msec()
	for code in asked.keys():
		if now - int(asked[code]) > ASK_TIMEOUT_MS:
			asked.erase(code)
			changed.emit()
			Notes.post("No answer from %s. They may be in a match, or need to update." % _label(code, ""), Notes.INFO, [], 8.0)
	for code in join_requests.keys():
		if now - int(join_requests[code].t) > JOIN_REQUEST_TTL_MS or not _hosting():
			join_requests.erase(code)
			changed.emit()


## Where friends can reach the game we host: our internet address (it works
## when the router's port is open, by UPnP or by hand) and a local address
## for friends on the same network.
func _where(msg: Dictionary) -> Dictionary:
	var net := get_parent()
	var ps: Dictionary = net.port_status()
	msg.address = str(ps.get("public_ip", ""))
	var lan := str(ps.get("lan_ip", ""))
	if lan == "":
		var all: PackedStringArray = net.local_addresses()
		lan = all[0] if all.size() > 0 else ""
	msg.lan = lan
	msg.port = int(net.port())
	return msg


## The address to use from an invite or a yes: the local one when the relay
## says we share their network, otherwise their internet address.
func _pick_address(m: Dictionary) -> String:
	var lan := str(m.get("lan", ""))
	var addr := str(m.get("address", ""))
	if bool(m.get("same_network", false)) and lan != "":
		return lan
	return addr if addr != "" else lan


func _join(code: String, address: String, port: int) -> void:
	var scene := get_tree().current_scene
	if scene and scene.has_method("join_friend_at"):
		scene.join_friend_at(code, address, port)
	else:
		Notes.post("Finish or leave this match, then join from Friends.", Notes.INFO, [], 6.0)


## Friendly text for a friend's status, e.g. "Hosting 2/4" or "Offline · 3 h ago".
func describe(code: String) -> String:
	if link == Link.OFF:
		return "Status is off (Settings → Gameplay)"
	if not statuses.has(code):
		return "Waiting for them to add you back" if link == Link.ONLINE else "Connecting to the friend service…"
	var s: Dictionary = statuses[code]
	if not s.online:
		var seen: float = s.get("last_seen", 0.0)
		if seen <= 0.0:
			return "Offline"
		var ago := Time.get_unix_time_from_system() - seen / 1000.0
		var t := "just now" if ago < 90 else ("%d min ago" % int(ago / 60) if ago < 3600 else ("%d h ago" % int(ago / 3600) if ago < 172800 else "%d days ago" % int(ago / 86400)))
		return "Offline · last seen %s" % t
	var d: Dictionary = s.detail
	var where := ""
	if str(d.get("map", "")) != "":
		var arena_script: GDScript = load("res://scripts/world/arena.gd")   # loaded by the menu already
		if arena_script.MAPS.has(str(d.map)):
			where = " · %s" % arena_script.map_title(str(d.map))
	match s.state:
		"hosting":
			return "Hosting %d/%d%s%s" % [int(d.get("players", 1)), int(d.get("max", 4)), where, "" if d.has("address") else " (port closed)"]
		"lobby":
			return "In a lobby"
		"playing":
			return "In a match · round %d%s" % [int(d.get("round", 1)), where]
	return "Online · in the menu"


func is_online() -> bool:
	return link == Link.ONLINE


func online(code: String) -> bool:
	return statuses.has(code) and statuses[code].online


func join_info(code: String) -> Dictionary:
	if not online(code) or statuses[code].state != "hosting":
		return {}
	var d: Dictionary = statuses[code].detail
	return {"address": str(d.get("address", "")), "port": int(d.get("port", 0))} if d.has("address") else {}


func _set_link(l: int) -> void:
	if link != l:
		link = l
		changed.emit()
