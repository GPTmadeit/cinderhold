extends Node
## Encryption check: a client pinned to the host's certificate connects; a
## client pinned to someone else's is refused.
## `godot --headless --path . res://tests/dtls_pinning.tscn` (exit 0 = pass)
const Identity := preload("res://scripts/core/identity.gd")

var _server: ENetConnection
var _clients := {}     # label -> [connection, expect_ok, connected]
var _t := 0.0


func _ready() -> void:
	var crypto := Crypto.new()
	var host_key := crypto.generate_rsa(2048)
	var host_code := Identity.code_for(host_key.save_to_string(true))
	var host_name := Identity.host_name_for(host_code)
	var host_cert := crypto.generate_self_signed_certificate(host_key, "CN=%s,O=Cinderhold" % host_name, "20250101000000", "20991231235959")
	var other_key := crypto.generate_rsa(2048)
	var other_code := Identity.code_for(other_key.save_to_string(true))
	var other_cert := crypto.generate_self_signed_certificate(other_key, "CN=%s,O=Cinderhold" % Identity.host_name_for(other_code), "20250101000000", "20991231235959")
	_server = ENetConnection.new()
	_server.create_host_bound("127.0.0.1", 47851, 4)
	_server.dtls_server_setup(TLSOptions.server(host_key, host_cert))
	_add("pinned to the host", TLSOptions.client(host_cert, host_name), host_name, true)
	_add("pinned to someone else", TLSOptions.client(other_cert, Identity.host_name_for(other_code)), Identity.host_name_for(other_code), false)
	_add("first contact (unpinned)", TLSOptions.client_unsafe(), "cinderhold", true)


func _add(label: String, opts: TLSOptions, name: String, expect_ok: bool) -> void:
	var c := ENetConnection.new()
	c.create_host(1)
	c.dtls_client_setup(name, opts)
	c.connect_to_host("127.0.0.1", 47851)
	_clients[label] = [c, expect_ok, false]


func _process(dt: float) -> void:
	_t += dt
	_server.service(0)
	for label in _clients:
		var ev: Array = _clients[label][0].service(0)
		if ev[0] == ENetConnection.EVENT_CONNECT:
			_clients[label][2] = true
	if _t < 4.0:
		return
	var bad := 0
	for label in _clients:
		var connected: bool = _clients[label][2]
		var ok: bool = connected == _clients[label][1]
		print("%s %s: %s" % ["PASS" if ok else "FAIL", label, "connected" if connected else "refused"])
		bad += 0 if ok else 1
	get_tree().quit(1 if bad else 0)
