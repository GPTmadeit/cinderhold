extends RefCounted
## Procedural poses for the jointed voxel characters (models.gd parts:
## torso, head, arm_*/fore_* and leg_*/shin_*, l and r).
##
## Every limb hangs down its own -Y axis from its joint and models face -Z,
## so a positive rotation.x swings an arm or a thigh forward and a negative
## one bends a knee (shin heel-up). The torso points up, so leaning it
## forward is a negative rotation.x. Arms hang from the torso, so their
## angles are relative to it.


## Ease `node.rotation` toward `target` (k = 0..1 per frame).
static func ease_rot(node: Node3D, target: Vector3, k: float) -> void:
	node.rotation = node.rotation.lerp(target, clampf(k, 0.0, 1.0))


## A walking or running stride. `phase` drives the cycle (radians), `swing`
## is the hip swing, `knee` how far the knee folds as the leg swings
## through, `base` a constant hip bend (crouching) and `k` the easing.
static func stride(p: Dictionary, phase: float, swing: float, knee: float, k: float, base := 0.0) -> void:
	var s := sin(phase)
	var c := cos(phase)
	ease_rot(p.leg_l, Vector3(base + s * swing, 0, 0), k)
	ease_rot(p.leg_r, Vector3(base - s * swing, 0, 0), k)
	# the leg moving forward is off the ground: fold its knee
	ease_rot(p.shin_l, Vector3(-knee * maxf(c, 0.0) - base * 1.5, 0, 0), k)
	ease_rot(p.shin_r, Vector3(-knee * maxf(-c, 0.0) - base * 1.5, 0, 0), k)


## Arms swinging opposite the legs (running, marching).
static func arm_swing(p: Dictionary, phase: float, swing: float, elbow: float, k: float, base := 0.0, spread := 0.08) -> void:
	var s := sin(phase)
	ease_rot(p.arm_l, Vector3(base - s * swing, 0, -spread), k)
	ease_rot(p.arm_r, Vector3(base + s * swing, 0, spread), k)
	ease_rot(p.fore_l, Vector3(elbow, 0, 0), k)
	ease_rot(p.fore_r, Vector3(elbow, 0, 0), k)


## Both arms reaching forward (the shambling grab), with a slow wobble.
static func reach(p: Dictionary, t: float, lift: float, elbow: float, k: float) -> void:
	ease_rot(p.arm_l, Vector3(lift + sin(t * 1.3) * 0.12, 0.1, -0.12), k)
	ease_rot(p.arm_r, Vector3(lift - 0.1 + sin(t * 1.3 + 1.7) * 0.12, -0.1, 0.12), k)
	ease_rot(p.fore_l, Vector3(elbow + sin(t * 2.1) * 0.15, 0, 0), k)
	ease_rot(p.fore_r, Vector3(elbow + sin(t * 2.1 + 1.0) * 0.15, 0, 0), k)


# =========================================================================
# Enemies
# =========================================================================

## st: {phase, t, speed, rise (0..1), attack (-1 or 0..1 through the
## swing), flinch (0..1)}. `model` is the rig root (moved for the rise).
static func enemy_pose(p: Dictionary, model: Node3D, kind: String, height: float, st: Dictionary, dt: float) -> void:
	var spd: float = st.speed
	var brute := kind == "brute"
	var running := kind == "runner" or spd > 3.4
	var k := clampf(dt * 12.0, 0.0, 1.0)
	var phase: float = st.phase
	var t: float = st.t
	var s := sin(phase)
	var rise: float = st.rise
	var flinch: float = st.flinch
	var bob := absf(cos(phase)) * (0.06 if brute else 0.035) * clampf(spd / 2.0, 0.0, 1.0)
	model.position.y = lerpf(-height, 0.0, ease(rise, 0.4)) + (bob if rise >= 1.0 else 0.0)
	var torso_x := 0.0
	var torso_z := 0.0
	var attack: float = st.attack
	if rise < 1.0:
		# clawing up out of the vent
		reach(p, t * 3.0, 2.6, 0.5, k)
		stride(p, 0.0, 0.0, 0.0, k, 0.3)
		torso_x = -0.35
	elif attack >= 0.0:
		# rear back with both arms up, then slam them down and lunge
		var up := 2.9 if brute else 2.6
		var shoulder := lerpf(1.0, up, ease(attack / 0.7, 0.6)) if attack < 0.7 else lerpf(up, 0.25, ease((attack - 0.7) / 0.3, 2.0))
		var elbow := lerpf(0.3, 0.9, minf(attack / 0.7, 1.0)) if attack < 0.7 else lerpf(0.9, 0.1, (attack - 0.7) / 0.3)
		ease_rot(p.arm_l, Vector3(shoulder, 0.15, -0.15), 0.5)
		ease_rot(p.arm_r, Vector3(shoulder, -0.15, 0.15), 0.5)
		ease_rot(p.fore_l, Vector3(elbow, 0, 0), 0.5)
		ease_rot(p.fore_r, Vector3(elbow, 0, 0), 0.5)
		stride(p, phase, 0.15, 0.3, k)
		torso_x = 0.15 if attack < 0.7 else -0.45
	else:
		var swing := clampf(spd / (3.5 if running else 2.0), 0.12, 1.0) if spd > 0.2 else 0.0
		if brute:
			stride(p, phase, 0.45 * swing, 0.7 * swing, k)
			arm_swing(p, phase, 0.35 * swing, 0.5, k, 0.12, 0.15)
			torso_x = -0.12
			torso_z = s * 0.07 * swing
		elif running:
			stride(p, phase, 0.8 * swing, 1.4 * swing, k)
			arm_swing(p, phase, 0.9 * swing, 1.3, k, 0.2)
			torso_x = -0.42 * maxf(swing, 0.3)
		else:
			# the shamble: stiff stride, arms reaching for whoever's nearest
			stride(p, phase, 0.5 * swing, 0.6 * swing, k)
			reach(p, t, 1.35, 0.25, k)
			torso_x = -0.12 - absf(s) * 0.05
			torso_z = sin(phase * 0.5) * 0.07
	torso_x += flinch * 0.5
	ease_rot(p.torso, Vector3(torso_x, 0, torso_z), k)
	ease_rot(p.head, Vector3(-torso_x * 0.6 - 0.1 + sin(t * 0.7) * 0.08 + flinch * 0.6,
		sin(t * 0.37) * 0.25, sin(t * 0.53) * 0.15), k)


# =========================================================================
# Survivors (how other players see you)
# =========================================================================

## st: {phase, speed, pitch, sprint, crouch, down, aim, reload, air, kick
## (0..1 recoil), melee (1 -> 0 through a swing), throw (1 -> 0)}.
## `body` is the rig root: it lowers for a crouch and lies back when downed.
static func survivor_pose(p: Dictionary, body: Node3D, st: Dictionary, dt: float) -> void:
	var k := clampf(dt * 14.0, 0.0, 1.0)
	var spd: float = st.speed
	var phase: float = st.phase
	var pitch: float = st.pitch
	var down: bool = st.down
	var sprint: bool = st.sprint and not down
	var crouch: bool = st.crouch and not down
	var moving := clampf(spd / 4.6, 0.0, 1.0)
	# whole body: lie back when downed, sink into a crouch
	var lie := 1.2 if down else 0.0
	body.rotation.x = lerpf(body.rotation.x, lie, clampf(dt * 6.0, 0.0, 1.0))
	body.position.y = lerpf(body.position.y, 0.32 if down else (-0.28 if crouch else 0.0), clampf(dt * 8.0, 0.0, 1.0))
	body.position.z = lerpf(body.position.z, 0.55 if down else 0.0, clampf(dt * 6.0, 0.0, 1.0))
	# legs
	if down:
		# legs out along the ground, one knee up
		ease_rot(p.leg_l, Vector3(PI * 0.5 - lie + 0.1, 0, -0.1), k)
		ease_rot(p.leg_r, Vector3(PI * 0.5 - lie + 0.5, 0, 0.1), k)
		ease_rot(p.shin_l, Vector3(-0.15, 0, 0), k)
		ease_rot(p.shin_r, Vector3(-0.9, 0, 0), k)
	elif st.air:
		ease_rot(p.leg_l, Vector3(0.8, 0, 0), k)
		ease_rot(p.leg_r, Vector3(0.25, 0, 0), k)
		ease_rot(p.shin_l, Vector3(-1.2, 0, 0), k)
		ease_rot(p.shin_r, Vector3(-0.6, 0, 0), k)
	elif crouch:
		stride(p, phase, 0.25 * moving, 0.35 * moving, k, 0.85)
	else:
		stride(p, phase, (0.75 if sprint else 0.45) * moving, (1.3 if sprint else 0.75) * moving, k)
	# torso and head
	var torso_x := clampf(pitch * 0.15, -0.2, 0.2) - (0.28 if sprint else 0.0) - (0.2 if crouch else 0.0)
	var twist := 0.0
	var melee: float = st.melee
	if melee > 0.0:
		twist = lerpf(-0.5, 0.45, ease(1.0 - melee, 0.5))
	ease_rot(p.torso, Vector3(torso_x, twist, 0), k)
	ease_rot(p.head, Vector3(clampf(pitch * 0.6 - torso_x, -0.6, 0.6), -twist * 0.7, 0), k)
	# arms: aim the gun where they look (angles relative to the torso)
	var aim := PI * 0.5 + pitch - torso_x - (lie if down else 0.0)
	var r_el := 0.25
	var r_sh := aim - r_el
	var l_el := 0.65
	var l_sh := aim - 0.5
	var l_yaw := -0.55
	if sprint and not st.aim:
		# gun across the chest, arms pumping a little
		r_sh = 0.5 + sin(phase) * 0.2
		r_el = 1.35
		l_sh = 0.65 - sin(phase) * 0.2
		l_el = 1.25
		l_yaw = -0.35
	if st.reload:
		var wob := sin(Time.get_ticks_msec() * 0.009) * 0.25
		r_sh = aim - 0.75
		l_sh = 0.45 + wob
		l_el = 1.7
		l_yaw = -0.25
	r_sh += float(st.kick) * 0.3
	if melee > 0.0:
		# a backhand slash across the body with the off hand
		var m := 1.0 - melee
		l_sh = lerpf(2.3, 0.6, ease(m, 0.4))
		l_el = lerpf(1.2, 0.15, m)
		l_yaw = lerpf(0.9, -1.1, ease(m, 0.4))
	var throw_t: float = st.throw
	if throw_t > 0.0:
		var m := 1.0 - throw_t
		l_sh = lerpf(3.0, 0.7, ease(m, 0.35)) if m > 0.3 else lerpf(1.0, 3.0, m / 0.3)
		l_el = lerpf(1.4, 0.2, m)
		l_yaw = 0.1
	ease_rot(p.arm_r, Vector3(r_sh, 0.12, 0.06), k)
	ease_rot(p.fore_r, Vector3(r_el, 0, 0), k)
	ease_rot(p.arm_l, Vector3(l_sh, l_yaw, -0.1), k)
	ease_rot(p.fore_l, Vector3(l_el, 0, 0), k)
