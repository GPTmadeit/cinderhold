extends Node3D
## Small physical debris: spent cases, stone chips knocked off walls, bits of
## a burst head. Every peer spawns its own (it's only for the eyes), from a
## fixed ring of rigid bodies made once per match, so shooting never creates
## or frees nodes. The oldest piece is recycled when the ring runs out.

const COUNT := 48
const KINDS := {
	"brass": [Color("b8913a"), 0.25, 0.55],     # colour, roughness, metallic
	"stone": [Color("5e5654"), 0.9, 0.0],
	"wood": [Color("6a4a2e"), 0.85, 0.0],
	"flesh": [Color("5a2a22"), 0.6, 0.0],
	"ember": [Color("ff7a1a"), 0.6, 0.0],
}

var _bodies: Array[RigidBody3D] = []
var _shapes: Array[BoxShape3D] = []
var _meshes: Array[MeshInstance3D] = []
var _life := PackedFloat32Array()
var _size := PackedVector3Array()
var _next := 0
var _mats := {}
var _box := BoxMesh.new()


func _ready() -> void:
	_box.size = Vector3.ONE
	for k in KINDS:
		var m := StandardMaterial3D.new()
		m.albedo_color = KINDS[k][0]
		m.roughness = KINDS[k][1]
		m.metallic = KINDS[k][2]
		if k == "ember":
			m.emission_enabled = true
			m.emission = KINDS[k][0]
			m.emission_energy_multiplier = 3.0
		_mats[k] = m
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.35
	pm.friction = 0.7
	for i in COUNT:
		var rb := RigidBody3D.new()
		rb.top_level = true
		rb.collision_layer = 0
		rb.collision_mask = 1 | 128     # the world and the dead
		rb.physics_material_override = pm
		rb.continuous_cd = true
		rb.angular_damp = 0.6
		rb.freeze = true
		rb.visible = false
		rb.process_mode = Node.PROCESS_MODE_DISABLED
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		cs.shape = shape
		rb.add_child(cs)
		var mi := MeshInstance3D.new()
		mi.mesh = _box
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		rb.add_child(mi)
		add_child(rb)
		_bodies.append(rb)
		_shapes.append(shape)
		_meshes.append(mi)
	_life.resize(COUNT)
	_size.resize(COUNT)


## One piece of `kind` at `pos`, `size` metres, thrown with `vel`.
func spawn(kind: String, pos: Vector3, vel: Vector3, size: Vector3, life := 3.0) -> void:
	if not is_inside_tree():
		return
	var i := _next
	_next = (_next + 1) % COUNT
	var rb := _bodies[i]
	rb.process_mode = Node.PROCESS_MODE_INHERIT
	rb.visible = true
	_shapes[i].size = size
	_meshes[i].scale = size
	_meshes[i].material_override = _mats.get(kind, _mats.stone)
	_size[i] = size
	rb.mass = maxf(size.x * size.y * size.z * 2500.0, 0.005)
	rb.global_transform = Transform3D(Basis.from_euler(Vector3(randf() * TAU, randf() * TAU, randf() * TAU)), pos)
	rb.freeze = false
	rb.linear_velocity = vel
	rb.angular_velocity = Vector3(randf_range(-20, 20), randf_range(-20, 20), randf_range(-20, 20))
	rb.sleeping = false
	_life[i] = life


## A spray of `n` chips flying off a surface.
func chips(kind: String, pos: Vector3, normal: Vector3, n: int, speed := 2.5, scale := 1.0) -> void:
	if Settings.quality() == 0:
		n = mini(n, 1)
	for k in n:
		var dir := (normal + Vector3(randf_range(-0.8, 0.8), randf_range(-0.2, 1.0), randf_range(-0.8, 0.8))).normalized()
		var s := randf_range(0.02, 0.05) * scale
		spawn(kind, pos + normal * 0.04, dir * speed * randf_range(0.5, 1.3), Vector3(s, s * randf_range(0.5, 1.0), s * randf_range(0.6, 1.2)),
			randf_range(1.5, 3.0))


func _physics_process(dt: float) -> void:
	for i in COUNT:
		if _life[i] <= 0.0:
			continue
		_life[i] -= dt
		var t := _life[i]
		if t < 0.4:
			_meshes[i].scale = _size[i] * maxf(t / 0.4, 0.01)    # shrink away
		if t <= 0.0:
			var rb := _bodies[i]
			rb.freeze = true
			rb.visible = false
			rb.process_mode = Node.PROCESS_MODE_DISABLED


func clear() -> void:
	for i in COUNT:
		_life[i] = 0.01
