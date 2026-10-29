extends CharacterBody3D
## A Husk, Runner or Brute. The host runs the AI and physics; every other
## peer interpolates snapshots. All peers animate the jointed voxel model.
## Collision shape 0 is the body, shape 1 is the head (for headshots).

const Prof := preload("res://scripts/core/prof.gd")
const M := preload("res://scripts/voxel/models.gd")

const STATS := {
	"husk": {"speeds": [1.5, 3.1, 5.0], "damage": 45.0, "reach": 1.35, "windup": 0.55, "radius": 0.33, "height": 1.85},
	"runner": {"speeds": [5.6], "damage": 35.0, "reach": 1.3, "windup": 0.4, "radius": 0.3, "height": 1.8},
	"brute": {"speeds": [2.2], "damage": 90.0, "reach": 2.0, "windup": 0.9, "radius": 0.55, "height": 2.7},
}

enum Anim { MOVE, ATTACK, RISE, IDLE }

var game: Node
var enemy_id := 0
var kind := "husk"
var hp := 100.0
var tier := 0
var anim := Anim.RISE
var move_speed := 0.0
var dying := false

var _stats: Dictionary
var _speed := 1.5
var _model: Node3D
var _parts := {}
var _meshes: Array[MeshInstance3D] = []
var _phase := 0.0
var _rise := 0.0
var _attack_t := -1.0
var _cooldown := 0.0
var _flash := 0.0
var _groan_t := 0.0
var _stuck_t := 0.0
var _last_pos := Vector3.ZERO
var _target: Node
var _enraged := false
var _snaps: Array = []        # [time, pos, yaw, anim, speed]
var _rng := RandomNumberGenerator.new()


func setup(g: Node, id: int, k: String, variant: int, pos: Vector3, health: float, speed_tier: int) -> void:
	game = g
	enemy_id = id
	kind = k
	add_to_group("enemies")
	hp = health
	tier = speed_tier
	_rng.seed = id * 977
	_stats = STATS[k]
	var speeds: Array = _stats.speeds
	_speed = speeds[mini(tier, speeds.size() - 1)] * _rng.randf_range(0.92, 1.08)
	global_position = pos
	rotation.y = _rng.randf() * TAU
	collision_layer = 4
	collision_mask = 1
	floor_snap_length = 0.3
	safe_margin = 0.02

	var body := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = _stats.radius
	cap.height = _stats.height * 0.8
	body.shape = cap
	body.position.y = cap.height * 0.5
	add_child(body)
	var head := CollisionShape3D.new()
	var hb := BoxShape3D.new()
	var hs := 0.5 if k == "brute" else 0.42
	hb.size = Vector3(hs, hs, hs)
	head.shape = hb
	head.position = Vector3(0, _stats.height - hs * 0.55, -0.03)
	add_child(head)

	_model = Node3D.new()
	add_child(_model)
	var parts: Dictionary = M.brute() if k == "brute" else M.husk(k, variant)
	for pname in parts:
		var pivot := Node3D.new()
		pivot.position = parts[pname].joint
		var mi := MeshInstance3D.new()
		mi.mesh = parts[pname].mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Settings.quality() >= 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pivot.add_child(mi)
		_model.add_child(pivot)
		_parts[pname] = pivot
		_meshes.append(mi)
	_model.position.y = -_stats.height
	_groan_t = _rng.randf_range(1.0, 5.0)
	_last_pos = pos
	if k == "brute":
		Sfx.play_at("brute_roar", pos, 6.0)


# =========================================================================
# Host AI
# =========================================================================

func _physics_process(dt: float) -> void:
	var _pt := Time.get_ticks_usec()
	_tick(dt)
	if Prof.on:
		Prof.add("enemies", _pt)


func _tick(dt: float) -> void:
	if dying:
		return
	_animate(dt)
	if _flash > 0.0 or _flash_sent > 0.0:
		_flash = maxf(_flash - dt * 6.0, 0.0)
		_flash_sent = _flash
		for m in _meshes:
			m.set_instance_shader_parameter("flash", _flash)
	_groan_t -= dt
	if _groan_t <= 0.0:
		_groan_t = _rng.randf_range(3.0, 7.0)
		Sfx.play_at("groan%d" % _rng.randi_range(0, 3), global_position + Vector3.UP * 1.5, -6.0 if kind != "brute" else 0.0, 0.15 if kind == "husk" else 0.3)
	if not multiplayer.is_server():
		_interpolate()
		return
	if _rise < 1.0:
		_rise = minf(_rise + dt / 1.1, 1.0)
		anim = Anim.RISE
		return
	# Decide where to go a few times a second (staggered across enemies);
	# steer, attack and move every tick.
	_think_t -= dt
	if _think_t <= 0.0:
		_think_t = THINK_INTERVAL * _rng.randf_range(0.8, 1.2)
		_think()
	_act(dt)


const THINK_INTERVAL := 0.12

var _goal := Vector3.ZERO
var _chase_direct := false
var _think_t := 0.0
var _push := Vector3.ZERO
var _path_dist := INF
var _flash_sent := 0.0


## Pick a target and the next point to walk toward. This is the expensive
## part (pathing, raycasts, crowd separation), so it runs at ~8 Hz.
func _think() -> void:
	var t: Dictionary = game.choose_target(global_position)
	if t.is_empty():
		_target = null
		_path_dist = INF
		return
	_target = t.player
	_path_dist = t.dist
	var tp: Vector3 = _target.global_position
	var flat := Vector2(tp.x - global_position.x, tp.z - global_position.z)
	_chase_direct = flat.length() < 3.5 and _clear_line(tp)
	if _chase_direct:
		_goal = tp
	else:
		_goal = game.arena.flow_step(t.field, global_position)
		# look one more step ahead so paths round corners smoothly
		var ahead: Vector3 = game.arena.flow_step(t.field, _goal)
		if _clear_line(ahead):
			_goal = _goal.lerp(ahead, 0.6)
	_push = _separation()


func _act(dt: float) -> void:
	var desired := Vector3.ZERO
	var speed := _speed * (1.6 if _enraged else 1.0)
	if _target == null or not is_instance_valid(_target):
		_target = null
		anim = Anim.IDLE
	else:
		var tp: Vector3 = _target.global_position
		var to := tp - global_position
		to.y = 0.0
		var dist := to.length()
		if _attack_t >= 0.0:
			_attack_t += dt
			anim = Anim.ATTACK
			desired = to.normalized() * 0.4
			if _attack_t >= _stats.windup:
				_attack_t = -1.0
				_cooldown = 0.9
				if dist <= _stats.reach + 0.6 and _target.targetable():
					game.damage_player(_target, _stats.damage, global_position)
		elif dist <= _stats.reach and _cooldown <= 0.0:
			_attack_t = 0.0
			Sfx.play_at("husk_attack", global_position + Vector3.UP * 1.5, -2.0)
		else:
			anim = Anim.MOVE
			if _chase_direct:
				_goal = tp    # close in on where the player is now
			var dir := _goal - global_position
			dir.y = 0.0
			if dist < _stats.reach * 0.8:
				dir = Vector3.ZERO
			desired = dir.normalized() * speed + _push * 1.4
	_cooldown -= dt

	var hv := Vector3(velocity.x, 0, velocity.z).lerp(desired, clampf(dt * 8.0, 0.0, 1.0))
	velocity = hv
	_grid_move(dt)
	move_speed = Vector2(velocity.x, velocity.z).length()
	if move_speed > 0.2 or (_target and anim == Anim.ATTACK):
		var face: Vector3 = (_target.global_position - global_position) if (_target and (anim == Anim.ATTACK or global_position.distance_to(_target.global_position) < 3.0)) else velocity
		face.y = 0.0
		if face.length() > 0.01:
			rotation.y = lerp_angle(rotation.y, atan2(-face.x, -face.z), clampf(dt * 8.0, 0.0, 1.0))

	# Unstick: an enemy that hasn't moved in a while somewhere far from
	# everyone is quietly returned to a vent.
	_stuck_t += dt
	if _stuck_t > 5.0:
		if global_position.distance_to(_last_pos) < 0.8 and _path_dist > 6.0:
			var vents: Array = game.arena.active_vents()
			if not vents.is_empty():
				global_position = vents[_rng.randi() % vents.size()].pos
				_rise = 0.0
		_stuck_t = 0.0
		_last_pos = global_position


## Enemies only ever stand on flat floor, and the arena's walkability grid
## already knows every wall, prop and closed door, so they move against the
## grid (circle vs cells, one axis at a time) instead of through the physics
## engine. Their collision shapes stay for bullets and the player.
func _grid_move(dt: float) -> void:
	var arena = game.arena
	var r: float = _stats.radius
	var p := global_position
	var stuck_in_wall: bool = not arena.circle_free(Vector2(p.x, p.z), r)
	var nx := p.x + velocity.x * dt
	if stuck_in_wall or arena.circle_free(Vector2(nx, p.z), r):
		p.x = nx
	else:
		velocity.x = 0.0
	var nz := p.z + velocity.z * dt
	if stuck_in_wall or arena.circle_free(Vector2(p.x, nz), r):
		p.z = nz
	else:
		velocity.z = 0.0
	p.y = 0.0
	global_position = p


func _clear_line(to: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.6, to + Vector3.UP * 0.6, 1)
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _separation() -> Vector3:
	var push := Vector3.ZERO
	var r: float = _stats.radius * 2.4
	for e in game.enemies.values():
		if e == self or e.dying:
			continue
		var d: Vector3 = global_position - e.global_position
		d.y = 0.0
		var l := d.length()
		if l < r and l > 0.001:
			push += d / l * (r - l) / r
	return push


func on_hurt(_attacker: int) -> void:
	if kind == "brute" and not _enraged and hp < 0.5 * _max_hp_guess():
		_enraged = true
		Sfx.play_at("brute_roar", global_position, 6.0, 0.1)


func _max_hp_guess() -> float:
	return game.round_health(game.round_num) * 4.5 + 1200.0


# =========================================================================
# Client interpolation
# =========================================================================

const INTERP_DELAY := 0.1


func push_snapshot(t: float, pos: Vector3, yaw: float, a: int, spd: float) -> void:
	_snaps.append([t, pos, yaw, a, spd])
	if _snaps.size() > 8:
		_snaps.pop_front()


func _interpolate() -> void:
	if _snaps.is_empty():
		_rise = minf(_rise + get_physics_process_delta_time() / 1.1, 1.0)
		return
	var render_t := Time.get_ticks_msec() / 1000.0 - INTERP_DELAY
	var a: Array = _snaps[0]
	var b: Array = _snaps[_snaps.size() - 1]
	for i in range(_snaps.size() - 1):
		if _snaps[i][0] <= render_t and _snaps[i + 1][0] >= render_t:
			a = _snaps[i]
			b = _snaps[i + 1]
			break
	var span: float = b[0] - a[0]
	var k := clampf((render_t - a[0]) / span, 0.0, 1.0) if span > 0.0001 else 1.0
	global_position = (a[1] as Vector3).lerp(b[1], k)
	rotation.y = lerp_angle(a[2], b[2], k)
	anim = b[3]
	move_speed = lerpf(a[4], b[4], k)
	if anim == Anim.RISE:
		_rise = minf(_rise + get_physics_process_delta_time() / 1.1, 1.0)
	else:
		_rise = 1.0
	if anim == Anim.ATTACK and _attack_t < 0.0:
		_attack_t = 0.0
	elif anim == Anim.ATTACK:
		_attack_t += get_physics_process_delta_time()
	else:
		_attack_t = -1.0


# =========================================================================
# Animation (all peers)
# =========================================================================

func _animate(dt: float) -> void:
	_model.position.y = lerpf(-_stats.height, 0.0, ease(_rise, 0.4))
	var spd := move_speed
	var runner := kind == "runner" or spd > 4.0
	_phase += dt * (2.0 + spd * 1.9)
	var swing := clampf(spd / 3.0, 0.15, 1.0) * (0.9 if runner else 0.55)
	var s := sin(_phase)
	var legs := [_parts.get("leg_l"), _parts.get("leg_r")]
	legs[0].rotation.x = s * swing
	legs[1].rotation.x = -s * swing
	var torso: Node3D = _parts.torso
	var head: Node3D = _parts.head
	var lean := 0.12 + (0.35 if runner else 0.05)
	torso.rotation.x = -lean + absf(s) * 0.05
	torso.position.y = _parts_base_y("torso") + absf(s) * 0.03
	head.rotation.z = sin(_phase * 0.37) * 0.15
	head.rotation.x = -0.15 + sin(_phase * 0.5) * 0.1
	var al: Node3D = _parts.arm_l
	var ar: Node3D = _parts.arm_r
	if _attack_t >= 0.0:
		var w: float = clampf(_attack_t / _stats.windup, 0.0, 1.0)
		var raise := -2.7 * ease(w, 0.5) if w < 0.85 else lerpf(-2.7, -0.7, (w - 0.85) / 0.15)
		al.rotation.x = raise
		ar.rotation.x = raise
	elif kind == "brute":
		al.rotation.x = -s * 0.5 - 0.2
		ar.rotation.x = s * 0.5 - 0.2
	elif runner:
		al.rotation.x = s * 1.1 + 0.3
		ar.rotation.x = -s * 1.1 + 0.3
	else:
		# the classic shambling reach
		al.rotation.x = -1.35 + sin(_phase * 0.8) * 0.12
		ar.rotation.x = -1.25 + sin(_phase * 0.8 + 1.3) * 0.12
	al.rotation.z = 0.08
	ar.rotation.z = -0.08


var _base_y := {}


func _parts_base_y(pname: String) -> float:
	if not _base_y.has(pname):
		_base_y[pname] = (_parts[pname] as Node3D).position.y
	return _base_y[pname]


# =========================================================================
# Hits and death
# =========================================================================

## Instant local feedback for the shooter, before the host confirms.
func local_hit(point: Vector3, head: bool) -> void:
	_flash = 1.0
	_flash_sent = 1.0
	Sfx.play_at("flesh", point, -2.0)
	_burst(point, head)


func _burst(point: Vector3, big: bool) -> void:
	game.fx_root.burst(point, big)


func die(headshot: bool) -> void:
	if dying:
		return
	dying = true
	collision_layer = 0
	for c in get_children():
		if c is CollisionShape3D:
			c.set_deferred("disabled", true)
	Sfx.play_at("husk_die", global_position + Vector3.UP, -1.0)
	if headshot:
		_burst(global_position + Vector3.UP * (_stats.height - 0.2), true)
		_parts.head.visible = false
	var tw := create_tween()
	var dir := -1.0 if _rng.randf() < 0.5 else 1.0
	tw.set_parallel(true)
	tw.tween_property(_model, "rotation:x", PI * 0.5 * dir * 0.98, 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(_model, "position:y", 0.15, 0.55)
	tw.tween_property(_parts.arm_l, "rotation:x", -2.6, 0.4)
	tw.tween_property(_parts.arm_r, "rotation:x", -2.2, 0.45)
	tw.chain().tween_method(_set_dissolve, 0.0, 1.0, 1.2).set_delay(0.5)
	tw.chain().tween_callback(queue_free)


func _set_dissolve(v: float) -> void:
	for m in _meshes:
		m.set_instance_shader_parameter("dissolve", v)
