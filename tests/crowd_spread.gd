extends Node
## Runs real Husks (the enemy script, host AI) down Times Square toward a
## standing target and counts how many grid columns they use crossing the
## north arm, to check a crowd fans out instead of walking single file.
## Prints "crowd columns=N"; fails under 4.

const EnemyScript := preload("res://scripts/enemy/enemy.gd")

var arena: Node3D
var enemies := {}
var local_player = null
var round_num := 1
var _field: PackedInt32Array
var _target: Node3D


class Target extends Node3D:
	func targetable() -> bool:
		return true


func choose_target(_pos: Vector3) -> Dictionary:
	return {"player": _target, "field": _field, "dist": arena.field_distance(_field, _pos)}


func damage_player(_p, _d, _from) -> void:
	pass


func round_health(_r: int) -> float:
	return 100.0


func _ready() -> void:
	Settings.setup()
	arena = preload("res://scripts/world/arena.gd").new()
	add_child(arena)
	await arena.build(false, Callable(), 0, "times_square")
	for d in arena.doors.keys():
		arena.open_door(d, false)
	_target = Target.new()
	add_child(_target)
	_target.global_position = Vector3(17.5, 0, 44.5)
	_field = arena.flow_field(arena.cell_of(_target.global_position))
	# a wave pouring out of Duffy Square, two rows deep
	var id := 1
	for row in [9, 11]:
		for x in range(9, 20):
			var e: CharacterBody3D = EnemyScript.new()
			add_child(e)
			e.setup(self, id, "husk", id % 5, Vector3(x + 0.5, 0, row + 0.5), 100.0, 1.6)
			enemies[id] = e
			id += 1
	var cols := {}
	var seen := {}
	Engine.time_scale = 4.0
	for i in 400:
		await get_tree().physics_frame
		for e in enemies.values():
			var c: Vector2i = arena.cell_of(e.global_position)
			if c.y == 26 and not seen.has(e.enemy_id):
				seen[e.enemy_id] = true
				cols[c.x] = int(cols.get(c.x, 0)) + 1
	Engine.time_scale = 1.0
	print("crowd crossed=%d columns=%d %s" % [seen.size(), cols.size(), cols])
	get_tree().quit(0 if cols.size() >= 4 and seen.size() >= 15 else 1)
