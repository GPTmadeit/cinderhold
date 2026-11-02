extends Node
## End-to-end update check: check GitHub (no key), download the patch if one
## is offered, and report.
func _ready() -> void:
	Settings.setup()
	Updater.setup()
	print("running version ", Updater.current_version())
	Updater.check()
	await get_tree().process_frame
	while Updater._busy:
		await get_tree().process_frame
	print("check: %s | %s" % [Updater.State.keys()[Updater.state], Updater.message])
	if Updater.state == Updater.State.AVAILABLE:
		Updater.download()
		await get_tree().process_frame
		while Updater._busy:
			await get_tree().process_frame
		print("download: %s | %s" % [Updater.State.keys()[Updater.state], Updater.message])
		print("patch.json: ", FileAccess.get_file_as_string("user://updates/patch.json"))
	get_tree().quit()
