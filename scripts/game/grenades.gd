extends Node3D
## Live grenades. Every peer simulates each throw from the same start
## (bouncing off the static world with ray casts on the fixed physics tick),
## so they fly and land alike everywhere; when the fuse burns down every
## peer shows the blast and the host deals the damage.

const M := preload("res://scripts/voxel/models.gd")

const FUSE := 2.2
const GRAVITY := 15.0
const RADIUS := 4.6            # blast radius, metres
const BOUNCE := 0.42
const SIZE := 0.05             # resting height of the grenade's centre

var game: Node
var _live := {}                # id -> {pos, vel, t, owner, node, spin, rest}


func spawn(id: int, owner_peer: int, origin: Vector3, vel: Vector3) -> void:
	if _live.has(id):
		return
	var mi := MeshInstance3D.new()
	mi.mesh = M.grenade()
	mi.position = origin
	add_child(mi)
	_live[id] = {"pos": origin, "vel": vel, "t": 0.0, "owner": owner_peer, "node": mi,
		"spin": Vector3(randf_range(-9, 9), randf_range(-4, 4), randf_range(-9, 9)), "rest": false}


func _physics_process(dt: float) -> void:
	if _live.is_empty():
		return
	var space := get_world_3d().direct_space_state
	for id in _live.keys():
		var g: Dictionary = _live[id]
		g.t += dt
		if not g.rest:
			_step(g, dt, space)
		var mi: MeshInstance3D = g.node
		mi.position = g.pos
		if not g.rest:
			mi.rotation += g.spin * dt
		if g.t >= FUSE:
			_live.erase(id)
			mi.queue_free()
			_explode(g.pos + Vector3.UP * 0.1, int(g.owner))


func _step(g: Dictionary, dt: float, space: PhysicsDirectSpaceState3D) -> void:
	var v: Vector3 = g.vel
	v.y -= GRAVITY * dt
	var from: Vector3 = g.pos
	var to := from + v * dt
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 1))
	if hit.is_empty():
		g.pos = to
		g.vel = v
		return
	var n: Vector3 = hit.normal
	var speed := v.length()
	v = v.bounce(n) * BOUNCE
	if n.y > 0.7:
		v.x *= 0.7                 # scrub speed on the ground
		v.z *= 0.7
		if absf(v.y) < 1.2:
			v.y = 0.0
			if Vector2(v.x, v.z).length() < 0.25:
				g.rest = true
	g.pos = hit.position + n * SIZE
	g.vel = v
	g.spin *= 0.6
	if speed > 2.0:
		Sfx.play_at("grenade_bounce", g.pos, -6.0 + minf(speed, 10.0) * 0.6, 0.15)


func _explode(pos: Vector3, owner_peer: int) -> void:
	Sfx.play_at("explode", pos, 6.0, 0.05)
	game.fx_root.blast(pos)
	# shake nearby cameras
	var me = game.local_player
	if me and is_instance_valid(me):
		var d: float = me.global_position.distance_to(pos)
		if d < 14.0:
			me.shake(clampf(1.0 - d / 14.0, 0.0, 1.0))
	if multiplayer.is_server():
		game.grenade_blast(pos, owner_peer, RADIUS)


func clear() -> void:
	for g in _live.values():
		g.node.queue_free()
	_live.clear()
