extends RefCounted
## The friends list, kept on this device only (user://friends.json). A
## friend is a friend code we trust, plus what we learned playing together:
## their name, the address and port they last hosted on, and their
## certificate, which lets the next join to them check it's really them.

const PATH := "user://friends.json"

static var _list: Array = []
static var _loaded := false
## Bumped on every change, so the friend service knows to resend the list.
static var revision := 0


static func all() -> Array:
	_load()
	return _list


static func find(code: String) -> Dictionary:
	_load()
	for f in _list:
		if f.code == code:
			return f
	return {}


static func is_friend(code: String) -> bool:
	return code != "" and not find(code).is_empty()


## Add or update a friend. Fields left empty keep what we already knew.
static func remember(code: String, name := "", cert := "", address := "", port := 0) -> void:
	if code.length() != 11:
		return
	_load()
	var f := find(code)
	var changed := f.is_empty()
	if changed:
		f = {"code": code, "name": "", "cert": "", "address": "", "port": 0, "added": int(Time.get_unix_time_from_system())}
		_list.append(f)
	if name != "" and f.name != name.substr(0, 16):
		f.name = name.substr(0, 16)
		changed = true
	if cert != "" and f.cert != cert:
		f.cert = cert
		changed = true
	if address != "" and (f.address != address or int(f.port) != port):
		f.address = address
		f.port = port
		changed = true
	if changed:   # only real changes count (the friend service resends the list on each)
		_save()


## Update a friend we just played with (no-op for strangers).
static func touch(code: String, name := "", cert := "", address := "", port := 0) -> void:
	if is_friend(code):
		remember(code, name, cert, address, port)


static func forget(code: String) -> void:
	_load()
	_list = _list.filter(func(f): return f.code != code)
	_save()


## Tidy a typed friend code ("7k2qd m9xra" -> "7K2QD-M9XRA"), or "".
static func normalize_code(text: String) -> String:
	var clean := ""
	for ch in text.to_upper():
		if ch == "O":
			ch = "0"
		elif ch == "I" or ch == "L":
			ch = "1"
		if "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(ch):
			clean += ch
	if clean.length() != 10:
		return ""
	return clean.substr(0, 5) + "-" + clean.substr(5)


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if data is Array:
		for f in data:
			if f is Dictionary and str(f.get("code", "")).length() == 11:
				_list.append(f)


static func _save() -> void:
	revision += 1
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_list, "\t"))
