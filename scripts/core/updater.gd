extends Node
## Self-update from GitHub releases without reinstalling.
##
## Each release carries `manifest.json` ({version, engine, pck, sha256}) and a
## content patch `.pck`. When the release was built with the same engine as
## this install, the patch is downloaded to user://updates and mounted by
## boot.gd on the next launch. A release that needs a newer engine is offered
## as a full download instead. The repository is private, so requests carry a
## read-only GitHub token the player pastes in Settings → Updates.

signal state_changed

const V := preload("res://scripts/core/version.gd")
const DIR := "user://updates"
const API := "https://api.github.com/repos/%s/releases/latest"

enum State { IDLE, CHECKING, UP_TO_DATE, AVAILABLE, DOWNLOADING, READY, FULL_REQUIRED, NEEDS_TOKEN, ERROR }

var state := State.IDLE
var message := ""
var latest_version := ""
var release_url := ""
var progress := 0.0

var _manifest := {}
var _assets := {}
var _http: HTTPRequest
var _busy := false


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_http = HTTPRequest.new()
	_http.max_redirects = 0
	_http.use_threads = true
	add_child(_http)
	if bool(Settings.get_v("updates", "auto_check")) and token() != "":
		check.call_deferred()


func current_version() -> String:
	return V.VERSION


func token() -> String:
	return str(Settings.get_v("updates", "token")).strip_edges()


func _process(_dt: float) -> void:
	if state == State.DOWNLOADING and _http.get_body_size() > 0:
		progress = float(_http.get_downloaded_bytes()) / float(_http.get_body_size())


func check() -> void:
	if _busy:
		return
	if token() == "":
		_set_state(State.NEEDS_TOKEN, "Add a GitHub token in Settings → Updates to check this private repo.")
		return
	_busy = true
	_set_state(State.CHECKING, "Checking GitHub for updates…")
	await _check()
	_busy = false


func _check() -> void:
	var res := await _http_get(API % V.REPO, true)
	if res.code == 401 or res.code == 403:
		_set_state(State.ERROR, "GitHub rejected the token (HTTP %d). Check that it can read %s." % [res.code, V.REPO])
		return
	if res.code == 404:
		# A private repo answers 404 both for "no releases" and "can't see it".
		var repo := await _http_get("https://api.github.com/repos/%s" % V.REPO, true)
		if repo.code == 200:
			_set_state(State.UP_TO_DATE, "No releases published yet.")
		else:
			_set_state(State.ERROR, "This token can't see %s. Give it \"Contents: read\" access to that repository." % V.REPO)
		return
	if res.code != 200:
		_set_state(State.ERROR, "Update check failed (%s)." % _why(res))
		return
	var rel = JSON.parse_string(res.body.get_string_from_utf8())
	if not rel is Dictionary:
		_set_state(State.ERROR, "GitHub sent an unreadable reply.")
		return
	latest_version = str(rel.get("tag_name", "")).trim_prefix("v")
	release_url = str(rel.get("html_url", ""))
	_assets.clear()
	for a in rel.get("assets", []):
		_assets[str(a.name)] = str(a.url)
	if not newer(latest_version, current_version()):
		_set_state(State.UP_TO_DATE, "You're on the latest version (v%s)." % current_version())
		return
	if not _assets.has("manifest.json"):
		_set_state(State.FULL_REQUIRED, "v%s is out, but it has no patch. Download it from GitHub." % latest_version)
		return
	var m := await _download(_assets["manifest.json"])
	if m.code != 200:
		_set_state(State.ERROR, "Couldn't fetch the update manifest (%s)." % _why(m))
		return
	var manifest = JSON.parse_string(m.body.get_string_from_utf8())
	if not manifest is Dictionary or not manifest.has("pck"):
		_set_state(State.ERROR, "The update manifest is malformed.")
		return
	_manifest = manifest
	if str(manifest.get("engine", "")) != V.ENGINE:
		_set_state(State.FULL_REQUIRED, "v%s needs a full reinstall (engine %s)." % [latest_version, manifest.get("engine", "?")])
		return
	_set_state(State.AVAILABLE, "Update v%s is available." % latest_version)


func download() -> void:
	if state != State.AVAILABLE or _busy:
		return
	_busy = true
	progress = 0.0
	_set_state(State.DOWNLOADING, "Downloading v%s…" % latest_version)
	var file := str(_manifest.pck)
	if not _assets.has(file):
		_busy = false
		_set_state(State.ERROR, "The release is missing %s." % file)
		return
	var res := await _download(_assets[file])
	_busy = false
	if res.code != 200:
		_set_state(State.ERROR, "Download failed (%s)." % _why(res))
		return
	var sum := _sha256(res.body)
	if sum != str(_manifest.get("sha256", "")).to_lower():
		_set_state(State.ERROR, "Download was corrupted (checksum mismatch). Try again.")
		return
	var path := DIR.path_join(file)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_set_state(State.ERROR, "Couldn't save the update (%s)." % error_string(FileAccess.get_open_error()))
		return
	f.store_buffer(res.body)
	f.close()
	var info := {"version": latest_version, "engine": V.ENGINE, "file": file}
	var pf := FileAccess.open(DIR.path_join("patch.json"), FileAccess.WRITE)
	pf.store_string(JSON.stringify(info))
	pf.close()
	_prune(file)
	_set_state(State.READY, "v%s is installed. Restart to play it." % latest_version)


func can_restart() -> bool:
	return not OS.has_feature("mobile") and not OS.has_feature("web")


func restart() -> void:
	if can_restart():
		OS.set_restart_on_exit(true, OS.get_cmdline_args())
	get_tree().quit()


func open_release_page() -> void:
	OS.shell_open(release_url if release_url != "" else "https://github.com/%s/releases" % V.REPO)


## Drop a downloaded patch so the built-in version runs again.
func revert_patch() -> void:
	DirAccess.remove_absolute(DIR.path_join("patch.json"))
	_set_state(State.IDLE, "Patch removed. Restart to go back to the installed version.")


func _prune(keep: String) -> void:
	var d := DirAccess.open(DIR)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".pck") and f != keep:
			d.remove(f)


func _set_state(s: State, msg: String) -> void:
	state = s
	message = msg
	state_changed.emit()


# --- HTTP --------------------------------------------------------------------

func _headers(auth: bool, binary: bool) -> PackedStringArray:
	var h := PackedStringArray(["User-Agent: Cinderhold/" + current_version(),
		"Accept: " + ("application/octet-stream" if binary else "application/vnd.github+json"),
		"X-GitHub-Api-Version: 2022-11-28"])
	if auth and token() != "":
		h.append("Authorization: Bearer " + token())
	return h


func _http_get(url: String, auth: bool, binary := false) -> Dictionary:
	var err := _http.request(url, _headers(auth, binary))
	if err != OK:
		return {"code": 0, "result": err, "body": PackedByteArray(), "headers": PackedStringArray()}
	var r: Array = await _http.request_completed
	return {"result": r[0], "code": r[1], "headers": r[2], "body": r[3]}


## Asset downloads redirect to a signed storage URL that must be fetched
## without the GitHub token, so redirects are followed by hand.
func _download(asset_api_url: String) -> Dictionary:
	var res := await _http_get(asset_api_url, true, true)
	var hops := 0
	while res.code in [301, 302, 303, 307, 308] and hops < 5:
		var loc := ""
		for h in res.headers:
			if h.to_lower().begins_with("location:"):
				loc = h.substr(9).strip_edges()
		if loc == "":
			break
		res = await _http_get(loc, false, true)
		hops += 1
	return res


func _why(res: Dictionary) -> String:
	if res.code == 0:
		return "no connection"
	return "HTTP %d" % res.code


static func _sha256(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func newer(a: String, b: String) -> bool:
	var pa := a.trim_prefix("v").split(".")
	var pb := b.trim_prefix("v").split(".")
	for i in 3:
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return x > y
	return false
