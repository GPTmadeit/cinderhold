extends Node
## Lobby and connection management. Solo play uses the offline peer, so the
## local player is always the server and every game path is shared.

signal roster_changed
signal connection_failed(reason: String)
signal connected
signal disconnected(reason: String)
signal game_starting

const MAX_PLAYERS := 4
const V := preload("res://scripts/core/version.gd")

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


func port() -> int:
	return int(Settings.get_v("net", "port"))


func start_solo() -> void:
	_reset()
	solo = true
	players[1] = _me()
	roster_changed.emit()


func host() -> Error:
	_reset()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port(), MAX_PLAYERS - 1)
	if err != OK:
		return err
	peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = peer
	solo = false
	players[1] = _me()
	roster_changed.emit()
	return OK


func join(address: String) -> Error:
	_reset()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port())
	if err != OK:
		return err
	peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = peer
	solo = false
	return OK


func leave() -> void:
	_reset()


func _reset() -> void:
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
	return {"name": Settings.player_name(), "color": int(Settings.get_v("player", "color")), "ready": false}


## Addresses friends can type to reach this machine (LAN, ZeroTier, Tailscale…).
func local_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return out


# --- lobby protocol -----------------------------------------------------

func _on_connected() -> void:
	_register.rpc_id(1, Settings.player_name(), int(Settings.get_v("player", "color")), V.VERSION)
	connected.emit()


func _on_peer_connected(_id: int) -> void:
	pass


func _on_peer_disconnected(id: int) -> void:
	if players.erase(id):
		roster_changed.emit()
		if is_host():
			_sync_roster.rpc(players)


@rpc("any_peer", "reliable")
func _register(pname: String, color: int, version: String) -> void:
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
	players[id] = {"name": pname.strip_edges().substr(0, 16), "color": _free_color(color), "ready": false}
	_sync_roster.rpc(players)
	roster_changed.emit()


@rpc("authority", "reliable")
func _kick(reason: String) -> void:
	_reset()
	connection_failed.emit(reason)


@rpc("authority", "reliable", "call_local")
func _sync_roster(roster: Dictionary) -> void:
	players = roster
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
	_begin.rpc(players)


@rpc("authority", "reliable", "call_local")
func _begin(roster: Dictionary) -> void:
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
