extends Node
## Fires rays at the middle of each enemy's visible head (a sprinting Runner
## leans well forward) and checks they land on the head shape (shape 1).
## Prints "head hits=N/M"; fails on any miss.

const EnemyScript := preload("res://scripts/enemy/enemy.gd")

var enemies := {}
var local_player = null


func _ready() -> void:
	Settings.setup()
	var floor_body := StaticBody3D.new()
	add_child(floor_body)
	var hits := 0
	var total := 0
	var id := 1
	for kind in ["husk", "runner", "brute"]:
		for speed in [0.0, 2.0, 5.5]:
			var e: CharacterBody3D = EnemyScript.new()
			add_child(e)
			e.setup(self, id, kind, 0, Vector3(id * 4.0, 0, 0), 100.0, 1.0)
			id += 1
			e.set_physics_process(false)
			e._rise = 1.0
			e.move_speed = speed
			for i in 40:
				e._animate(1.0 / 60.0)
			await get_tree().physics_frame
			await get_tree().physics_frame
			var mi: MeshInstance3D = e._parts.head.get_child(0)
			var centre: Vector3 = mi.global_transform * mi.mesh.get_aabb().get_center()
			for dir in [Vector3.FORWARD, Vector3.LEFT, Vector3.BACK]:
				var from: Vector3 = centre - e.global_transform.basis * dir * 6.0
				var q := PhysicsRayQueryParameters3D.create(from, centre, 4)
				var r := get_viewport().world_3d.direct_space_state.intersect_ray(q)
				total += 1
				if not r.is_empty() and r.collider == e and int(r.shape) == 1:
					hits += 1
				else:
					print("miss: %s speed %.1f from %s -> %s" % [kind, speed, dir, "nothing" if r.is_empty() else "shape %d" % r.shape])
	print("head hits=%d/%d" % [hits, total])
	get_tree().quit(0 if hits == total else 1)
