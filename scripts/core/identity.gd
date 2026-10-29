extends RefCounted
## This install's identity: an RSA key and a self-signed certificate made
## once and kept in user://identity. The certificate encrypts the games we
## host (DTLS), friends pin it so nobody can pose as us, and the key signs
## the host's challenge when we join. The friend code is a short hash of
## the public key, so it can't be claimed without the key.

const DIR := "user://identity"
const KEY_PATH := DIR + "/key.pem"
const CERT_PATH := DIR + "/cert.crt"
const CODE_ALPHABET := "0123456789ABCDEFGHJKMNPQRSTVWXYZ"   # Crockford base32: no I, L, O, U

static var _key: CryptoKey
static var _cert: X509Certificate
static var _code := ""
static var _task := -1
static var _lock := Mutex.new()


## Load the identity, or make it on a worker thread (RSA key generation can
## take a moment on a phone). Call early; ready() says when it's done.
static func prepare() -> void:
	if _key != null or _task != -1:
		return
	if FileAccess.file_exists(KEY_PATH) and FileAccess.file_exists(CERT_PATH):
		var k := CryptoKey.new()
		var c := X509Certificate.new()
		if k.load(KEY_PATH) == OK and c.load(CERT_PATH) == OK:
			_store(k, c)
			return
	_task = WorkerThreadPool.add_task(_generate, false, "Cinderhold: identity key")


## Block until the identity exists (dev command-line hosting on a first run;
## the menus wait for ready() instead).
static func wait_ready() -> void:
	prepare()
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


static func ready() -> bool:
	if _task != -1 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_lock.lock()
	var ok := _key != null
	_lock.unlock()
	return ok


static func _generate() -> void:
	var crypto := Crypto.new()
	var k := crypto.generate_rsa(2048)
	var code := code_for(k.save_to_string(true))
	var c := crypto.generate_self_signed_certificate(k, "CN=cinderhold-%s,O=Cinderhold" % code.replace("-", "").to_lower(),
		"20250101000000", "20991231235959")
	DirAccess.make_dir_recursive_absolute(DIR)
	k.save(KEY_PATH)
	c.save(CERT_PATH)
	_store(k, c)


static func _store(k: CryptoKey, c: X509Certificate) -> void:
	_lock.lock()
	_key = k
	_cert = c
	_code = code_for(k.save_to_string(true))
	_lock.unlock()


static func key() -> CryptoKey:
	return _key


static func cert() -> X509Certificate:
	return _cert


static func cert_pem() -> String:
	return _cert.save_to_string() if _cert else ""


static func public_pem() -> String:
	return _key.save_to_string(true) if _key else ""


## Our friend code, e.g. "7K2QD-M9XRA".
static func code() -> String:
	return _code


## The friend code for a public key (PEM): 50 bits of its SHA-256.
static func code_for(public_pem_text: String) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(public_pem_text.strip_edges().to_utf8_buffer())
	var d := h.finish()
	var bits := 0
	for i in 7:
		bits = (bits << 8) | d[i]
	var out := ""
	for i in 10:
		out += CODE_ALPHABET[(bits >> (51 - 5 * i)) & 31]
	return out.substr(0, 5) + "-" + out.substr(5)


## The DTLS host name a certificate was issued for, from its code.
static func host_name_for(code_text: String) -> String:
	return "cinderhold-" + code_text.replace("-", "").to_lower()


## Sign `data` with our key (proves the friend code is ours).
static func sign(data: PackedByteArray) -> PackedByteArray:
	return Crypto.new().sign(HashingContext.HASH_SHA256, _sha256(data), _key)


## Check a signature made by the holder of `public_pem_text`.
static func verify(data: PackedByteArray, signature: PackedByteArray, public_pem_text: String) -> bool:
	var k := CryptoKey.new()
	if k.load_from_string(public_pem_text, true) != OK:
		return false
	return Crypto.new().verify(HashingContext.HASH_SHA256, _sha256(data), signature, k)


static func _sha256(data: PackedByteArray) -> PackedByteArray:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(data)
	return h.finish()
