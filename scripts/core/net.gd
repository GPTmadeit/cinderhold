extends Node
## Lobby and connection management. Solo play uses the offline peer, so the
## local player is always the server and every game path is shared.
##
## Every connection is encrypted (ENet over DTLS) with this install's
## certificate (identity.gd). Joining a friend whose certificate we saved
## also checks it really is them. Joining players sign a random challenge
## from the host, which proves the friend code they show is theirs.
## Connection state lives in node metadata ("join", "host_id", "pending").
##
## PATCH SAFETY: never add, remove, retype or reorder this autoload's member
## variables; installed copies keep the old layout when a patch swaps the
## script in. See scripts/tools/check_autoload_layout.py.

signal roster_changed
signal connection_failed(reason: String)
signal connected
signal disconnected(reason: String)
signal game_starting

const MAX_PLAYERS := 4
const V := preload("res://scripts/core/version.gd")
const Identity := preload("res://scripts/core/identity.gd")
const Friends := preload("res://scripts/core/friends.gd")

## peer id -> {name, color, ready}
var players := {}
var in_game := false
var solo := true
## Shown on the main menu after being dropped from a game.
var last_message := ""


func setup() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func(): _reset(); connection_failed.emit("Couldn't reach the host."))
	multiplayer.server_disconnected.connect(func(): _reset(); disconnected.emit("The host closed the game."))
	Identity.prepare()


func port() -> int:
	return int(Settings.get_v("net", "port"))


func start_solo() -> void:
	_reset()
	solo = true
	players[1] = _me()
	roster_changed.emit()


func host() -> Error:
	_reset()
	Identity.wait_ready()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port(), MAX_PLAYERS - 1)
	if err != OK:
		print("Net: couldn't host on %d: %s" % [port(), error_string(err)])
		return err
	# from here on every packet is encrypted with our certificate
	err = peer.host.dtls_server_setup(TLSOptions.server(Identity.key(), Identity.cert()))
	if err != OK:
		peer.close()
		print("Net: couldn't set up encryption: %s" % error_string(err))
		return err
	print("Net: hosting on UDP %d (encrypted)" % port())
	peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	# Ask the router to forward the port and find our public address
	# (not in scripted dev runs, which must never touch the router).
	if not "--host" in OS.get_cmdline_user_args():
		var pm: Node = load("res://scripts/core/port_mapper.gd").new()
		pm.name = "PortMapper"
		add_child(pm)
		pm.changed.connect(func(): roster_changed.emit())
		pm.start(port())
	multiplayer.multiplayer_peer = peer
	solo = false
	players[1] = _me()
	roster_changed.emit()
	return OK


## Join a host. With the `friend_code` of a friend whose certificate we
## saved, the connection only succeeds if it's really them.
func join(address: String, port_override := 0, friend_code := "") -> Error:
	_reset()
	Identity.wait_ready()
	var p := port_override if port_override > 0 else port()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, p)
	if err != OK:
		print("Net: couldn't connect to %s: %s" % [address, error_string(err)])
		return err
	# The handshake hasn't left yet, so this still applies to it.
	var friend := Friends.find(friend_code)
	var pinned := str(friend.get("cert", "")) != ""
	var opts := TLSOptions.client_unsafe()
	var host_name := "cinderhold"
	if pinned:
		var c := X509Certificate.new()
		if c.load_from_string(friend.cert) == OK:
			host_name = Identity.host_name_for(friend_code)
			opts = TLSOptions.client(c, host_name)
		else:
			pinned = false
	err = peer.host.dtls_client_setup(host_name, opts)
	if err != OK:
		peer.close()
		print("Net: couldn't set up encryption: %s" % error_string(err))
		return err
	set_meta("join", {"address": address, "port": p, "code": friend_code, "pinned": pinned})
	print("Net: connecting to %s:%d (encrypted%s)" % [address, p, ", verifying %s" % friend_code if pinned else ""])
	peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = peer
	solo = false
	return OK


func leave() -> void:
	_reset()


func _reset() -> void:
	for m in ["pending", "host_id"]:
		remove_meta(m)
	var pm := get_node_or_null("PortMapper")
	if pm:
		pm.release()          # close the router's forwarding again
		remove_child(pm)
		pm.free()
	if multiplayer.multiplayer_peer and not multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players.clear()
	in_game = false
	solo = true


func is_host() -> bool:
	return multiplayer.is_server()


func me() -> int:
	return multiplayer.get_unique_id()


func _me() -> Dictionary:
	return {"name": Settings.player_name(), "color": int(Settings.get_v("player", "color")), "ready": false,
		"code": Identity.code(), "cert": Identity.cert_pem()}


## How we reached the host this time: {address, port, code, pinned}.
func join_info() -> Dictionary:
	return get_meta("join", {})


## While hosting: how friends outside the home network reach us.
## {state: "working" | "open" | "closed", public_ip, lan_ip, port, note}.
func port_status() -> Dictionary:
	var pm := get_node_or_null("PortMapper")
	if pm == null:
		return {}
	return {"state": ["working", "open", "closed"][pm.state], "public_ip": pm.public_ip, "lan_ip": pm.lan_ip,
		"port": pm.port, "note": pm.note}


## Addresses friends can type to reach this machine (LAN, ZeroTier, Tailscale…).
func local_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	var bridges := PackedStringArray()
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			# x.x.x.1 is almost always a virtual bridge (Docker, VMs), not this machine
			(bridges if a.ends_with(".1") else out).append(a)
	return out if not out.is_empty() else bridges


# --- lobby protocol -----------------------------------------------------

func _on_connected() -> void:
	print("Net: connected to host, registering")
	_register.rpc_id(1, Settings.player_name(), int(Settings.get_v("player", "color")), V.VERSION,
		Identity.public_pem(), Identity.cert_pem())
	connected.emit()


func _on_peer_connected(id: int) -> void:
	print("Net: peer %d connected" % id)


func _on_peer_disconnected(id: int) -> void:
	if players.erase(id):
		roster_changed.emit()
		if is_host():
			_sync_roster.rpc(players)


@rpc("any_peer", "reliable")
func _register(pname: String, color: int, version: String, public_pem: String, cert_pem: String) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	if version != V.VERSION:
		_kick.rpc_id(id, "Version mismatch: host is v%s, you have v%s. Update from the main menu." % [V.VERSION, version])
		return
	if in_game:
		_kick.rpc_id(id, "That game has already started.")
		return
	if players.size() >= MAX_PLAYERS:
		_kick.rpc_id(id, "The lobby is full.")
		return
	# They prove the friend code is theirs by signing a fresh challenge.
	var nonce := Crypto.new().generate_random_bytes(32)
	var pending: Dictionary = get_meta("pending", {})
	pending[id] = {"name": pname.strip_edges().substr(0, 16), "color": color, "pub": public_pem.substr(0, 4096),
		"cert": cert_pem.substr(0, 8192), "nonce": nonce}
	set_meta("pending", pending)
	_challenge.rpc_id(id, nonce, Identity.cert_pem(), Identity.public_pem())


## Client: sign the host's challenge (bound to the host's certificate).
@rpc("authority", "reliable")
func _challenge(nonce: PackedByteArray, host_cert: String, host_pub: String) -> void:
	set_meta("host_id", {"code": Identity.code_for(host_pub), "cert": host_cert})
	_prove.rpc_id(1, Identity.sign(nonce + host_cert.to_utf8_buffer()))


@rpc("any_peer", "reliable")
func _prove(signature: PackedByteArray) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	var pending: Dictionary = get_meta("pending", {})
	var p: Dictionary = pending.get(id, {})
	pending.erase(id)
	if p.is_empty():
		return
	if not Identity.verify(p.nonce + Identity.cert_pem().to_utf8_buffer(), signature, p.pub):
		_kick.rpc_id(id, "Couldn't verify your identity.")
		return
	if in_game or players.size() >= MAX_PLAYERS:
		_kick.rpc_id(id, "That game has already started." if in_game else "The lobby is full.")
		return
	var code := Identity.code_for(p.pub)
	players[id] = {"name": p.name, "color": _free_color(p.color), "ready": false, "code": code, "cert": p.cert}
	print("Net: %s joined as peer %d (%s)" % [p.name, id, code])
	Friends.touch(code, p.name, p.cert)
	_sync_roster.rpc(players)
	roster_changed.emit()


@rpc("authority", "reliable")
func _kick(reason: String) -> void:
	_reset()
	connection_failed.emit(reason)


@rpc("authority", "reliable", "call_local")
func _sync_roster(roster: Dictionary) -> void:
	players = roster
	if not is_host():
		# keep what we know about friends up to date (names, how to reach the host)
		var j := join_info()
		for id in roster:
			var r: Dictionary = roster[id]
			if id == 1:
				var hid: Dictionary = get_meta("host_id", {})
				if hid.get("code", "") == r.get("code", ""):
					Friends.touch(str(r.get("code", "")), str(r.name), str(hid.get("cert", "")), str(j.get("address", "")), int(j.get("port", 0)))
			elif id != me():
				Friends.touch(str(r.get("code", "")), str(r.name), str(r.get("cert", "")))
	roster_changed.emit()


func _free_color(wanted: int) -> int:
	var used := []
	for p in players.values():
		used.append(int(p.color))
	if not wanted in used:
		return wanted
	for c in Settings.PLAYER_COLORS.size():
		if not c in used:
			return c
	return wanted


func set_ready(r: bool) -> void:
	_ready_changed.rpc_id(1, r)


@rpc("any_peer", "reliable", "call_local")
func _ready_changed(r: bool) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	if players.has(id):
		players[id].ready = r
		_sync_roster.rpc(players)


func everyone_ready() -> bool:
	for id in players:
		if id != 1 and not players[id].ready:
			return false
	return true


## Host only: move everyone into the match.
func start_game() -> void:
	if not is_host():
		return
	in_game = true
	_begin.rpc(players, randi() & 0x7fffffff)


## The host's per-match random seed (where the ash vents go), shared with
## everyone at the start. Kept as node metadata: this autoload's member
## variables must not change (see the note at the top).
func match_seed() -> int:
	return int(get_meta("match_seed", 0))


@rpc("authority", "reliable", "call_local")
func _begin(roster: Dictionary, seed: int) -> void:
	print("Net: match starting with %d players" % roster.size())
	set_meta("match_seed", seed)
	players = roster
	in_game = true
	game_starting.emit()
	# let the menu draw its loading screen before the map build blocks
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func return_to_lobby() -> void:
	if is_host():
		in_game = false
		for id in players:
			players[id].ready = false
		_to_lobby.rpc(players)


@rpc("authority", "reliable", "call_local")
func _to_lobby(roster: Dictionary) -> void:
	players = roster
	in_game = false
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
