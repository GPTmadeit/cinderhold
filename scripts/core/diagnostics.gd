extends Node
## Crash diagnostics. Each session keeps a small log in user://diagnostics:
## a heartbeat every few seconds (scene, round, frame rate, memory) plus the
## engine's and scripts' errors. A session that ends without a clean exit
## while the game was in the foreground counts as a crash: the next launch
## turns its log into a report the main menu offers to copy. On Android 11+
## the report also carries the system's own reason for the exit (low memory,
## native crash, not responding…). Nothing leaves the device unless the
## player copies the report themselves.

const NODE_NAME := "Diagnostics"
const DIR := "user://diagnostics"
const STATE := DIR + "/session.json"
const LOG := DIR + "/session.log"
const LOG_PREV := DIR + "/session.prev.log"
const REPORT := DIR + "/last_crash.txt"
const PROBE := DIR + "/exit_probe_2"   # exists while asking Android why the game exited
const BEAT := 5.0
const ROTATE_LINES := 1500
const REPORT_LINES := 120

## android.app.ApplicationExitInfo reasons.
const EXIT_REASONS := {
	0: "unknown", 1: "the game exited by itself", 2: "killed by a signal", 3: "low memory",
	4: "crash (Java)", 5: "native crash", 6: "not responding (ANR)", 7: "failed to start",
	8: "permission change", 9: "excessive resource use", 10: "closed by the user",
	11: "stopped by the user", 12: "a dependency died", 13: "other", 14: "frozen",
	15: "package state change", 16: "package updated",
}

## The previous session ended unexpectedly and its report hasn't been dismissed.
var crashed := false
## One line about the crash, for the main menu.
var summary := ""

var _file: FileAccess
var _lines := 0
var _mutex := Mutex.new()
var _sink: Sink
var _beat_t := 0.0
var _state := {}
var _scene := ""
var _last_msg := ""
var _repeats := 0
var _writing := false


## Forwards every engine message and error into the session log.
class Sink extends Logger:
	var target: WeakRef

	func _log_message(message: String, error: bool) -> void:
		var d = target.get_ref()
		if d:
			d.write(("ERR " if error else "") + message.strip_edges())

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var d = target.get_ref()
		if d:
			var kind: String = ["ERROR", "WARNING", "SCRIPT ERROR", "SHADER ERROR"][clampi(error_type, 0, 3)]
			d.write("%s: %s (%s:%d in %s)" % [kind, rationale if rationale != "" else code, file.get_file(), line, function])


## The running diagnostics node, created on first use.
static func ensure(tree: SceneTree) -> Node:
	var d: Node = tree.root.get_node_or_null(NODE_NAME)
	if d == null:
		d = load("res://scripts/core/diagnostics.gd").new()
		d.name = NODE_NAME
		tree.root.add_child(d)
	return d


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	DirAccess.make_dir_recursive_absolute(DIR)
	var prev := _read_state()
	if prev.get("running", false) and not prev.get("background", false):
		_keep_crash_report(prev)
	DirAccess.remove_absolute(LOG_PREV)
	_file = FileAccess.open(LOG, FileAccess.WRITE)
	write("Cinderhold %s on %s %s (%s), %s, %s renderer" % [
		get_node("/root/Updater").current_version(), OS.get_name(), OS.get_version(), OS.get_model_name(),
		RenderingServer.get_video_adapter_name(), RenderingServer.get_current_rendering_method()])
	write("memory: %s total, %s available, %d CPU threads" % [
		_mb(OS.get_memory_info().get("physical", -1)), _mb(OS.get_memory_info().get("available", -1)), OS.get_processor_count()])
	_sink = Sink.new()
	_sink.target = weakref(self)
	OS.add_logger(_sink)
	_state = {"running": true, "background": false, "version": get_node("/root/Updater").current_version(),
		"started": Time.get_unix_time_from_system(), "pid": OS.get_process_id()}
	_save_state()


func _exit_tree() -> void:
	_clean_exit()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			_clean_exit()
		NOTIFICATION_APPLICATION_PAUSED:
			# Phones kill background apps freely; that isn't a crash.
			_state.background = true
			write("app paused")
			_save_state()
		NOTIFICATION_APPLICATION_RESUMED:
			_state.background = false
			write("app resumed")
			_save_state()


func _process(dt: float) -> void:
	var scene := get_tree().current_scene
	var scene_name := String(scene.name) if scene else "-"
	if scene_name != _scene:
		_scene = scene_name
		write("scene " + scene_name)
	_beat_t -= dt
	if _beat_t <= 0.0:
		_beat_t = BEAT
		_heartbeat(scene)


func _heartbeat(scene: Node) -> void:
	var where := "in the menu" if _scene.to_lower().contains("menu") else "in " + _scene
	if scene and "round_num" in scene and "enemies" in scene:
		where = "in a match, round %d (%s), %d enemies" % [scene.round_num, scene.phase, scene.enemies.size()]
	write("beat %s | %d fps | memory %s used, %s free | video %s | %d pipeline compiles" % [
		where, Engine.get_frames_per_second(), rss(), _mb(OS.get_memory_info().get("available", -1)),
		_mb(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW) + Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE)])
	_state.beat = Time.get_unix_time_from_system()
	_state.where = where
	_save_state()


## Append a line to the session log (safe from any thread).
func write(line: String) -> void:
	_mutex.lock()
	if _file and line != "" and not _writing:
		_writing = true   # a failing write logs an error, which would land here again
		if line == _last_msg:
			_repeats += 1
		else:
			if _repeats > 0:
				_file.store_line("  (repeated %d more times)" % _repeats)
			_repeats = 0
			_last_msg = line
			_file.store_line("%s %s" % [Time.get_time_string_from_system(), line])
			_file.flush()
			_lines += 1
			if _lines >= ROTATE_LINES:
				_rotate()
		_writing = false
	_mutex.unlock()


func _rotate() -> void:
	_file.close()
	DirAccess.remove_absolute(LOG_PREV)
	DirAccess.rename_absolute(LOG, LOG_PREV)
	_file = FileAccess.open(LOG, FileAccess.WRITE)
	_lines = 0


func _clean_exit() -> void:
	if _state.get("running", false):
		_state.running = false
		write("clean exit")
		_save_state()
	if _sink:
		OS.remove_logger(_sink)
		_sink = null


func _read_state() -> Dictionary:
	var data = JSON.parse_string(FileAccess.get_file_as_string(STATE)) if FileAccess.file_exists(STATE) else null
	return data if data is Dictionary else {}


func _save_state() -> void:
	var f := FileAccess.open(STATE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_state))


## Turn the previous session's log into the crash report.
func _keep_crash_report(prev: Dictionary) -> void:
	var lines := PackedStringArray()
	for path in [LOG_PREV, LOG]:
		if FileAccess.file_exists(path):
			lines.append_array(FileAccess.get_file_as_string(path).split("\n", false))
	var head := lines.slice(0, 2)
	var tail := lines.slice(maxi(2, lines.size() - REPORT_LINES))
	crashed = true
	var exit := _android_exit_text(int(prev.get("pid", 0)))
	if exit_reason_code(exit) in [10, 11, 15, 16]:
		crashed = false   # closed or force-stopped by the player, or the app was updated
		return
	var reason := describe_exit(exit)
	var when := Time.get_datetime_string_from_unix_time(
		int(prev.get("beat", prev.get("started", 0))) + Time.get_time_zone_from_system().bias * 60, true)
	summary = "v%s, %s, around %s" % [prev.get("version", "?"), str(prev.get("where", "starting up")), when]
	var text := "Cinderhold crash report\nSession: %s\n" % summary
	if reason != "":
		text += "Android says: %s\n" % reason
		summary += ". Android says: " + reason
	text += "\n" + "\n".join(head) + "\n…\n" + "\n".join(tail) + "\n"
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f:
		f.store_string(text)


## The saved report text, or "" if there is none.
func report() -> String:
	return FileAccess.get_file_as_string(REPORT) if FileAccess.file_exists(REPORT) else ""


func dismiss() -> void:
	crashed = false


## Android 11+ records why each of an app's processes ended; fetch the record
## for the crashed session's process as text. Guarded so a failure here can
## never crash the game twice: the probe file stays behind and later launches
## skip it.
func _android_exit_text(pid: int) -> String:
	if pid <= 0 or not OS.has_feature("android") or not Engine.has_singleton("AndroidRuntime") or FileAccess.file_exists(PROBE):
		return ""
	FileAccess.open(PROBE, FileAccess.WRITE)
	var text := ""
	var ctx = Engine.get_singleton("AndroidRuntime").getApplicationContext()
	var am = ctx.getSystemService("activity") if ctx != null else null
	var list = am.getHistoricalProcessExitReasons(ctx.getPackageName(), pid, 1) if am != null else null
	if list != null:
		# The Java bridge can't hand back the list's elements (get() returns
		# a plain Object), but their text carries every field.
		text = str(list.toString())
	DirAccess.remove_absolute(PROBE)
	return text


## The ApplicationExitInfo reason code in `text`, or -1.
static func exit_reason_code(text: String) -> int:
	var m := RegEx.create_from_string(" reason=(\\d+) ").search(text)
	return int(m.get_string(1)) if m else -1


## One readable line from ApplicationExitInfo text, e.g. "... reason=5 (APP
## CRASH(NATIVE)) subreason=0 (UNKNOWN) status=11 importance=100 pss=0.00
## rss=0.00 description=crash state=empty ...".
static func describe_exit(text: String) -> String:
	var m := RegEx.create_from_string(" reason=(\\d+) .*? status=(-?\\d+) .*? rss=(\\S+) description=(.*?) state=").search(text)
	if m == null:
		return ""
	var reason := int(m.get_string(1))
	var status := int(m.get_string(2))
	var out: String = EXIT_REASONS.get(reason, "reason %d" % reason)
	if reason == 2 or reason == 5:   # status is the signal
		out += " (signal %d%s)" % [status, {6: ", SIGABRT", 7: ", SIGBUS", 9: ", SIGKILL", 11: ", SIGSEGV"}.get(status, "")]
	var desc := m.get_string(4)
	if desc != "" and desc != "null":
		out += ": " + desc
	var rss := m.get_string(3)
	if rss.to_float() > 0.0:
		out += ", %s in use" % rss
	return out


## Resident memory of this process (Linux and Android), or "?".
static func rss() -> String:
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if f == null:
		return "?"
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("VmRSS:"):
			return _mb(int(line.split(":")[1].strip_edges().split(" ")[0]) * 1024)
	return "?"


static func _mb(bytes) -> String:
	return "?" if bytes == null or float(bytes) < 0.0 else "%d MB" % roundi(float(bytes) / 1048576.0)
