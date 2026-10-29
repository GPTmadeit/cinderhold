extends Node
## While we host, asks the router to forward the game's UDP port to us
## (UPnP), so friends outside the home network can join without anyone
## setting up port forwarding by hand, and finds the public address to give
## them. Lives under the Net service as "PortMapper"; removed (and the
## forwarding closed again) when hosting stops.
##
## The router talk blocks for a few seconds, so it runs on a worker thread.
## If the router has UPnP turned off, we still look up the public address
## (over HTTPS) so the lobby can say exactly what to forward.

signal changed

enum State { WORKING, OPEN, CLOSED }

const IP_LOOKUP := "https://api.ipify.org"
const LEASE := 7200          # seconds; renewed while hosting
const UPNP_SUCCESS := 0

var state := State.WORKING
var port := 0
var lan_ip := ""             # our address as the router sees it
var public_ip := ""
var router_ip := ""          # the router's own external address
var note := ""               # why the port isn't open, when it isn't

var _upnp: Object            # UPNP, created by name in case a build lacks the module
var _task := -1
var _done := {}
var _renew_t := 0.0
var _http: HTTPRequest


func start(p: int) -> void:
	port = p
	if not bool(Settings.get_v("net", "upnp")):
		state = State.CLOSED
		note = "Automatic port opening is off (Settings)."
		_lookup_public_ip()
		return
	_task = WorkerThreadPool.add_task(_open, false, "Cinderhold: UPnP")


## Worker thread: find the router and open the port.
func _open() -> void:
	var out := {"ok": false, "note": "", "lan": "", "router_ip": ""}
	if not ClassDB.class_exists("UPNP"):
		out.note = "This build can't talk to routers."
		_done = out
		return
	var u: Object = ClassDB.instantiate("UPNP")
	var err: int = u.discover(2500, 2, "InternetGatewayDevice")
	var gw: Object = u.get_gateway() if err == UPNP_SUCCESS else null
	if gw == null or not gw.is_valid_gateway():
		out.note = "Your router didn't answer (UPnP may be turned off)."
		_done = out
		return
	out.lan = str(gw.get("igd_our_addr"))
	out.router_ip = str(u.query_external_address())
	var m: int = u.add_port_mapping(port, port, "Cinderhold", "UDP", LEASE)
	if m != UPNP_SUCCESS:
		m = u.add_port_mapping(port, port, "Cinderhold", "UDP", 0)   # some routers only take permanent ones
	if m != UPNP_SUCCESS:
		out.note = "Your router refused to open the port (code %d)." % m
		_done = out
		return
	out.ok = true
	_upnp = u
	_done = out


func _process(dt: float) -> void:
	if _task != -1 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		state = State.OPEN if _done.ok else State.CLOSED
		note = _done.note
		lan_ip = _done.lan
		router_ip = _done.router_ip
		_renew_t = LEASE * 0.75
		_lookup_public_ip()
		changed.emit()
	if state == State.OPEN and _upnp != null and _task == -1:
		_renew_t -= dt
		if _renew_t <= 0.0:
			_renew_t = LEASE * 0.75
			var u := _upnp
			var p := port
			_task = WorkerThreadPool.add_task(func(): u.add_port_mapping(p, p, "Cinderhold", "UDP", LEASE), false, "Cinderhold: UPnP renew")
			_done = {"ok": true, "note": "", "lan": lan_ip, "router_ip": router_ip}


## The address friends type: the router's, or a lookup over HTTPS if the
## router didn't say (or says something private, which means the provider
## shares one public address between many homes).
func _lookup_public_ip() -> void:
	if router_ip != "" and not _is_private(router_ip):
		public_ip = router_ip
		return
	_http = HTTPRequest.new()
	_http.timeout = 8.0
	add_child(_http)
	_http.request_completed.connect(func(result: int, code: int, _h, body: PackedByteArray):
		var ip := body.get_string_from_utf8().strip_edges()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200 and ip.length() <= 45 and ip.count(".") == 3:
			public_ip = ip
			if router_ip != "" and _is_private(router_ip):
				note = "Your internet provider shares your public address with other homes, so forwarding won't reach you. Use Tailscale or ZeroTier instead."
				state = State.CLOSED
		_http.queue_free()
		changed.emit())
	_http.request(IP_LOOKUP)


static func _is_private(ip: String) -> bool:
	var p := ip.split(".")
	if p.size() != 4:
		return true
	var a := int(p[0])
	var b := int(p[1])
	return a == 10 or a == 127 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) \
		or (a == 100 and b >= 64 and b <= 127) or a == 0


## Close the forwarding again (when hosting stops or the game quits).
func release() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _upnp != null:
		_upnp.delete_port_mapping(port, "UDP")
		_upnp = null
	state = State.CLOSED


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		release()
