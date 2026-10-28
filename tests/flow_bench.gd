extends Node
## Times enemy flow-field generation, which runs when a player changes cell.
func _ready() -> void:
	Settings.setup()
	var a = preload("res://scripts/world/arena.gd").new()
	add_child(a)
	a.build()
	for d in a.doors.keys():
		a.open_door(d, false)       # whole map reachable: the worst case
	var cells := []
	for y in a.H:
		for x in a.W:
			if a.is_walkable(Vector2i(x, y)):
				cells.append(Vector2i(x, y))
	var worst := 0.0
	var total := 0.0
	var n := int(OS.get_environment("FLOW_N")) if OS.get_environment("FLOW_N") != "" else 30
	for i in n:
		var t := Time.get_ticks_usec()
		var c: Vector2i = cells[(i * 37) % cells.size()]
		if OS.get_environment("FLOW_VERBOSE") != "":
			printerr("  start %s" % c)
		a.flow_field(c)
		var ms := (Time.get_ticks_usec() - t) / 1000.0
		if OS.get_environment("FLOW_VERBOSE") != "":
			printerr("  cell %s: %.2f ms" % [c, ms])
		total += ms
		worst = maxf(worst, ms)
	print("flow_field over %d walkable cells: avg %.2f ms, worst %.2f ms" % [cells.size(), total / n, worst])
	# Every reachable cell must have a neighbour that is closer, or enemies stall.
	var bad := 0
	for i in mini(n, 60):
		var tgt: Vector2i = cells[(i * 37) % cells.size()]
		var f: PackedInt32Array = a.flow_field(tgt)
		for c in cells:
			var v: int = f[c.y * a.W + c.x]
			if c == tgt or v >= a.UNREACHED:
				continue
			var step: Vector3 = a.flow_step(f, a.cell_center(c))
			if f[a.cell_of(step).y * a.W + a.cell_of(step).x] >= v:
				bad += 1
	print("descent check: %d cells without a closer neighbour" % bad)
	get_tree().quit()
