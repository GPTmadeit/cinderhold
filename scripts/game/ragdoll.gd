extends RefCounted
## Ragdolls for the dead. The jointed voxel rig an enemy is animated with is
## handed to the physics engine (Jolt) as it stands: each part becomes a
## rigid box around its mesh, hung from its parent by a cone-twist joint at
## the part's pivot, and the killing blow's push is applied to the bodies it
## hit hardest. Purely visual, so every peer runs its own.

const MAX_LIVE := [3, 5, 8, 10]     # per quality preset: older ragdolls freeze in place
const SETTLE := 2.8                  # seconds of simulation before a body is frozen
const LAYER := 128                   # physics layer 8: ragdoll parts only

## [bodies, frozen-at msec]
static var _live: Array = []

## Swing and twist limits (degrees) by part name prefix.
const LIMITS := {
	"head": [40.0, 30.0],
	"arm": [80.0, 40.0],
	"fore": [70.0, 10.0],
	"thigh": [65.0, 15.0],
	"shin": [70.0, 5.0],
}


## Turn `parts` (pivot nodes from models.instance_rig, under `owner`) into
## a ragdoll. `vel` is the body's own velocity, `push` the hit's impulse
## direction × strength (m/s), `heavy` scales the masses (brutes).
## Returns the bodies (the meshes have moved onto them).
static func make(owner: Node3D, parts: Dictionary, vel: Vector3, push: Vector3, heavy := 1.0) -> Array[RigidBody3D]:
	var bodies := {}
	var out: Array[RigidBody3D] = []
	var pm := PhysicsMaterial.new()
	pm.friction = 0.9
	pm.bounce = 0.05
	for pname: String in parts:
		var pv: Node3D = parts[pname]
		if not pv.visible or pv.get_child_count() == 0 or not (pv.get_child(0) is MeshInstance3D):
			continue
		var mi: MeshInstance3D = pv.get_child(0)
		var aabb: AABB = mi.mesh.get_aabb()
		if aabb.size.length() < 0.01:
			continue
		var rb := RigidBody3D.new()
		rb.name = "RD_" + pname
		rb.top_level = true
		rb.collision_layer = LAYER     # corpses pile up; bullets and the living pass through
		rb.collision_mask = 1 | LAYER
		rb.physics_material_override = pm
		rb.linear_damp = 0.15
		rb.angular_damp = 1.6
		var vol := aabb.size.x * aabb.size.y * aabb.size.z
		rb.mass = clampf(vol * 900.0, 0.8, 30.0) * heavy
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		# a little inside the painted shape, so limbs settle on their surfaces
		box.size = (aabb.size * 0.88).max(Vector3.ONE * 0.05)
		cs.shape = box
		cs.position = aabb.get_center()
		rb.add_child(cs)
		owner.add_child(rb)
		rb.global_transform = pv.global_transform
		mi.reparent(rb, true)
		bodies[pname] = rb
		out.append(rb)
	# joints: each part hangs from the nearest ancestor that became a body
	for pname: String in bodies:
		var pv: Node3D = parts[pname]
		var par := pv.get_parent()
		while par != null and not bodies.has(String(par.name)) and parts.has(String(par.name)):
			par = par.get_parent()
		if par == null or not bodies.has(String(par.name)):
			continue
		var j := ConeTwistJoint3D.new()
		j.top_level = true
		owner.add_child(j)
		j.global_transform = Transform3D(pv.global_basis.orthonormalized(), pv.global_position)
		var lim: Array = [55.0, 25.0]
		for k in LIMITS:
			if pname.begins_with(k):
				lim = LIMITS[k]
		j.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, deg_to_rad(lim[0]))
		j.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, deg_to_rad(lim[1]))
		j.node_a = j.get_path_to(bodies[String(par.name)])
		j.node_b = j.get_path_to(bodies[pname])
	# the blow lands hardest on the torso and head; the rest follow through the joints
	for pname: String in bodies:
		var rb: RigidBody3D = bodies[pname]
		var k := 1.0 if pname == "torso" or pname == "head" else 0.55
		rb.linear_velocity = vel + push * k + Vector3.UP * randf_range(0.2, 1.0) * push.length() * 0.15
		rb.angular_velocity = Vector3(randf_range(-2, 2), randf_range(-2, 2), randf_range(-2, 2))
	_live.append([out, Time.get_ticks_msec()])
	var cap: int = MAX_LIVE[Settings.quality()]
	while _live.size() > cap:
		_freeze(_live.pop_front()[0])
	return out


## Stop simulating a ragdoll (it stays where it lies).
static func _freeze(bodies: Array) -> void:
	for rb in bodies:
		if is_instance_valid(rb):
			rb.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			rb.freeze = true


## Freeze ragdolls that have had their time; call now and then.
static func settle() -> void:
	var now := Time.get_ticks_msec()
	for i in range(_live.size() - 1, -1, -1):
		if now - int(_live[i][1]) > SETTLE * 1000.0:
			_freeze(_live[i][0])
			_live.remove_at(i)


static func forget(bodies: Array) -> void:
	for i in range(_live.size() - 1, -1, -1):
		if _live[i][0] == bodies:
			_live.remove_at(i)
