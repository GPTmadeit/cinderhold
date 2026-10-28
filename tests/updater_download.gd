extends Node
## Exercises Updater._download (API asset URL -> redirect -> storage) against
## a small public asset, and the full check() flow against this repo.
func _ready() -> void:
	Settings.setup()
	Updater.setup()
	var res: Dictionary = await Updater._download("https://api.github.com/repos/godotengine/godot/releases/assets/519695144")
	var text: String = res.body.get_string_from_utf8()
	print("download code=%d bytes=%d starts_ok=%s" % [res.code, res.body.size(), text.length() > 100 and text.contains("Godot_v4.7.2")])
	for tok in ["", "github_pat_bogus", OS.get_environment("TEST_GH_TOKEN")]:
		Settings.data.updates.token = tok        # not saved
		Updater.check()
		await get_tree().process_frame
		while Updater._busy:
			await get_tree().process_frame
		print("check token=%s state=%s message=%s" % ["real" if tok.length() > 20 else ("bogus" if tok != "" else "none"),
			Updater.State.keys()[Updater.state], Updater.message])
	get_tree().quit()
