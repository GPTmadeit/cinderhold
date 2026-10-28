## Tiny section timer for dev perf runs. Sections cost nothing unless
## `--prof` is passed.
static var on := "--prof" in OS.get_cmdline_user_args()
static var totals := {}


static func add(key: String, since_usec: int) -> void:
	totals[key] = totals.get(key, 0) + (Time.get_ticks_usec() - since_usec)


static func take() -> Dictionary:
	var t := totals
	totals = {}
	return t
