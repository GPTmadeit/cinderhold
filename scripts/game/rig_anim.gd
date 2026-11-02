extends RefCounted
## Procedural animation for the jointed characters (models.gd parts: torso,
## head, arm_*/fore_* and leg_*/shin_*, l and r).
##
## Every limb hangs down its own -Y axis from its joint and models face -Z,
## so a positive rotation.x swings an arm or a thigh forward and a negative
## one bends a knee (shin heel-up). The torso points up, so leaning it
## forward is a negative rotation.x. Arms hang from the torso, so their
## angles are relative to it.
##
## Joints don't snap to their poses: each is a damped spring pulled toward
## the pose (its angular velocity lives in the node's metadata), so limbs
## carry momentum, overshoot a little and settle, heavier parts lag lighter
## ones, and a hit can simply kick a joint's velocity (kick()).

const AV := &"_av"


## Spring `node.rotation` toward `target`. `freq` is the stiffness in Hz,
## `damp` the damping ratio (1 = no overshoot). Implicit integration, so
## it stays stable at any frame rate.
static func spring(node: Node3D, target: Vector3, freq: float, damp: float, dt: float) -> void:
	if dt <= 0.0:
		return
	var w := TAU * freq
	var v: Vector3 = node.get_meta(AV, Vector3.ZERO)
	var x := node.rotation
	v = (v + (target - x) * (w * w * dt)) / (1.0 + 2.0 * damp * w * dt + w * w * dt * dt)
	node.rotation = x + v * dt
	node.set_meta(AV, v)


## Add angular velocity to a joint (radians per second): hits, twitches.
static func kick(node: Node3D, impulse: Vector3) -> void:
	node.set_meta(AV, node.get_meta(AV, Vector3.ZERO) + impulse)


## Kept for callers that still ease directly.
static func ease_rot(node: Node3D, target: Vector3, k: float) -> void:
	node.rotation = node.rotation.lerp(target, clampf(k, 0.0, 1.0))


## Spring stiffness by part: the torso is heavy, hands and heads quick.
static func _hz(part: String, base: float) -> float:
	match part:
		"torso": return base * 0.7
		"head": return base * 1.1
		"fore_l", "fore_r": return base * 1.25
		"shin_l", "shin_r": return base * 1.4
	return base


## Drive every part toward its pose target. `pose`: part -> Vector3.
static func apply(p: Dictionary, pose: Dictionary, base_hz: float, damp: float, dt: float) -> void:
	for part: String in pose:
		if p.has(part):
			spring(p[part], pose[part], _hz(part, base_hz), damp, dt)


## Legs through one stride. `phase` drives the cycle; `swing` is the hip
## swing, `knee` how far the swinging leg folds, `base` a constant hip bend
## (crouch), `limp` (0..1) drags the left leg, `wide` splays the stance.
static func gait(pose: Dictionary, phase: float, swing: float, knee: float, base := 0.0, limp := 0.0, wide := 0.0) -> void:
	var s := sin(phase)
	var c := cos(phase)
	var drag := 1.0 - limp * 0.6
	pose.leg_l = Vector3(base + s * swing * drag, 0, -wide)
	pose.leg_r = Vector3(base - s * swing, 0, wide)
	# the swinging leg folds most mid-swing; the planted one keeps a soft knee
	var fold_l := pow(maxf(c, 0.0), 1.3) * knee * (1.0 - limp * 0.75)
	var fold_r := pow(maxf(-c, 0.0), 1.3) * knee
	pose.shin_l = Vector3(-fold_l - 0.08 * swing - base * 1.5, 0, 0)
	pose.shin_r = Vector3(-fold_r - 0.08 * swing - base * 1.5, 0, 0)


## Arms swinging against the legs.
static func arms_swing(pose: Dictionary, phase: float, swing: float, elbow: float, base := 0.0, spread := 0.08) -> void:
	var s := sin(phase)
	pose.arm_l = Vector3(base - s * swing, 0, -spread)
	pose.arm_r = Vector3(base + s * swing, 0, spread)
	# elbows bend more on the forward swing
	pose.fore_l = Vector3(elbow + maxf(-s, 0.0) * elbow * 0.5, 0, 0)
	pose.fore_r = Vector3(elbow + maxf(s, 0.0) * elbow * 0.5, 0, 0)


## Both arms reaching forward with a slow, uneven wobble (the shamble).
static func reach(pose: Dictionary, t: float, lift: float, elbow: float, seed := 0.0) -> void:
	pose.arm_l = Vector3(lift + sin(t * 1.3 + seed) * 0.14, 0.12, -0.14)
	pose.arm_r = Vector3(lift - 0.12 + sin(t * 1.1 + 1.7 + seed) * 0.16, -0.1, 0.12)
	pose.fore_l = Vector3(elbow + sin(t * 2.1 + seed) * 0.18, 0, 0)
	pose.fore_r = Vector3(elbow + sin(t * 1.9 + 1.0 + seed) * 0.2, 0, 0)


## Smooth 0..1 noise, for idle drift.
static func _wob(t: float, seed: float) -> float:
	return sin(t * 1.13 + seed) * 0.5 + sin(t * 2.37 + seed * 2.1) * 0.3 + sin(t * 0.61 + seed * 3.7) * 0.2


# =========================================================================
# Enemies
# =========================================================================

## st: {phase, t, speed, rise (0..1), attack (-1 or 0..1 through the
## swing), flinch (0..1)}; optional: style (attack style 0-2), seed (per
## enemy, for limps and wobble), turn (yaw rate, rad/s), accel (m/s²).
## `model` is the rig root (moved for the rise, the bob and the hip sway).
static func enemy_pose(p: Dictionary, model: Node3D, kind: String, height: float, st: Dictionary, dt: float) -> void:
	var spd: float = st.speed
	var brute := kind == "brute"
	var runner := kind == "runner"
	var running := runner or spd > 3.4
	var phase: float = st.phase
	var t: float = st.t
	var seed: float = st.get("seed", 0.0)
	var s := sin(phase)
	var rise: float = st.rise
	var flinch: float = st.flinch
	var turn: float = clampf(st.get("turn", 0.0), -4.0, 4.0)
	var attack: float = st.attack
	var moving := clampf(spd / (3.5 if running else 1.8), 0.0, 1.0)
	var pose := {}
	var torso := Vector3.ZERO
	var head := Vector3.ZERO
	var bob := 0.0
	var sway := 0.0
	var hz := 5.0 if brute else (7.5 if runner else 5.5)
	var damp := 0.55 if not brute else 0.7
	if rise < 1.0:
		# clawing up out of the ground: alternate hands haul, the body heaves up
		var claw := t * 4.0
		pose.arm_l = Vector3(2.4 + sin(claw) * 0.5, 0.1, -0.25)
		pose.arm_r = Vector3(2.4 + sin(claw + PI) * 0.5, -0.1, 0.25)
		pose.fore_l = Vector3(0.6 + maxf(sin(claw), 0.0) * 0.9, 0, 0)
		pose.fore_r = Vector3(0.6 + maxf(sin(claw + PI), 0.0) * 0.9, 0, 0)
		gait(pose, 0.0, 0.0, 0.0, lerpf(1.1, 0.2, rise))
		torso = Vector3(lerpf(-0.9, -0.2, rise), sin(claw) * 0.15, sin(claw * 0.5) * 0.1)
		head = Vector3(0.5 - rise * 0.4, sin(t * 7.0) * 0.12, 0)
		model.position.y = lerpf(-height, 0.0, ease(rise, 0.45))
	else:
		if attack >= 0.0:
			_attack_pose(pose, attack, int(st.get("style", 0)), brute)
			torso = pose.get("_torso", Vector3.ZERO)
			head = pose.get("_head", Vector3.ZERO)
			pose.erase("_torso")
			pose.erase("_head")
			gait(pose, phase, 0.12, 0.25, 0.18 if attack < 0.6 else 0.05, 0.0, 0.08)
			hz *= 1.4
			damp = 0.45
		elif brute:
			# heavy and wide: the whole body rolls over each planted foot
			gait(pose, phase, 0.42 * moving, 0.75 * moving, 0.06, 0.0, 0.12)
			arms_swing(pose, phase - 0.4, 0.35 * moving, 0.45, 0.15, 0.2)
			torso = Vector3(-0.14 - 0.05 * moving, -s * 0.12 * moving, s * 0.11 * moving)
			head = Vector3(0.05, s * 0.08, -s * 0.06)
			bob = (1.0 - absf(s)) * 0.09 * moving
			sway = s * 0.06 * moving
		elif running:
			# a bounding, forward-thrown sprint
			gait(pose, phase, 0.85 * moving, 1.6 * moving, 0.12)
			arms_swing(pose, phase, 0.95 * moving, 1.35, 0.25, 0.1)
			torso = Vector3(-0.5 * maxf(moving, 0.35), -s * 0.22 * moving, 0)
			head = Vector3(0.3, s * 0.1, 0)
			bob = (1.0 - absf(s)) * 0.07 * moving
		else:
			# the shamble: one dragging leg, swaying hips, arms out for whoever's nearest
			var limp := 0.5 + 0.5 * sin(seed * 3.1)
			gait(pose, phase, 0.5 * moving, 0.65 * moving, 0.05, limp)
			reach(pose, t, 1.3 + sin(seed) * 0.15, 0.28, seed)
			torso = Vector3(-0.14 - absf(s) * 0.06, -s * 0.14 * moving, sin(phase * 0.5) * 0.09 + limp * 0.06)
			head = Vector3(0.0, _wob(t * 0.5, seed) * 0.35, _wob(t * 0.4, seed + 5.0) * 0.25 + 0.12 * sin(seed * 7.0))
			bob = (1.0 - absf(s)) * 0.04 * moving
			sway = s * 0.035 * moving
		# lean into turns, a slow breath when standing
		torso.z += turn * (0.05 if brute else 0.08)
		torso.x += sin(t * 1.6 + seed) * 0.025 * (1.0 - moving)
		model.position.y = lerpf(model.position.y, bob, clampf(dt * 20.0, 0.0, 1.0))
	model.position.x = lerpf(model.position.x, sway, clampf(dt * 10.0, 0.0, 1.0))
	torso.x += flinch * 0.45
	pose.torso = torso
	# the head keeps looking ahead: it counters the torso's lean and twist
	pose.head = Vector3(-torso.x * 0.55 - 0.08 + head.x + flinch * 0.5, -torso.y * 0.6 + head.y, head.z)
	apply(p, pose, hz, damp, dt)


## Three attacks. 0: both arms rear back and slam down; 1: a wide one-armed
## swipe with the whole body turning into it; 2: a lunge, grabbing and
## biting. Anticipation, a fast strike, and a heavy follow-through.
static func _attack_pose(pose: Dictionary, a: float, style: int, brute: bool) -> void:
	var wind := ease(clampf(a / 0.62, 0.0, 1.0), 0.5)          # 0..1 through the wind-up
	var hit := ease(clampf((a - 0.62) / 0.16, 0.0, 1.0), 2.4)   # the strike, fast
	var rec := clampf((a - 0.78) / 0.22, 0.0, 1.0)               # follow-through
	match style % 3:
		0:
			var up := 2.95 if brute else 2.7
			var sh := lerpf(lerpf(1.0, up, wind), 0.15, hit) + rec * 0.35
			var el := lerpf(lerpf(0.3, 1.1, wind), 0.05, hit)
			pose.arm_l = Vector3(sh, 0.18, -0.2)
			pose.arm_r = Vector3(sh, -0.18, 0.2)
			pose.fore_l = Vector3(el, 0, 0)
			pose.fore_r = Vector3(el, 0, 0)
			pose._torso = Vector3(lerpf(0.22 * wind, -0.6, hit) + rec * 0.2, 0, 0)
			pose._head = Vector3(lerpf(-0.3 * wind, 0.4, hit), 0, 0)
		1:
			var out := lerpf(lerpf(0.6, 1.6, wind), 1.2, hit)
			pose.arm_r = Vector3(out, lerpf(lerpf(0.0, 1.1, wind), -1.2, hit), lerpf(0.3, 1.2, wind) * (1.0 - hit) + 0.2)
			pose.fore_r = Vector3(lerpf(0.9, 0.15, hit), 0, 0)
			pose.arm_l = Vector3(0.9 + hit * 0.4, 0.2, -0.3)
			pose.fore_l = Vector3(1.2, 0, 0)
			pose._torso = Vector3(-0.2 - hit * 0.15, lerpf(lerpf(0.0, 0.7, wind), -0.8, hit) + rec * 0.3, 0.1 * wind)
			pose._head = Vector3(0.1, lerpf(-0.4 * wind, 0.5, hit), 0)
		_:
			var reach_k := lerpf(-0.4 * wind, 1.0, hit)
			pose.arm_l = Vector3(lerpf(0.8, 1.75, maxf(reach_k, 0.0)), 0.25, -0.15)
			pose.arm_r = Vector3(lerpf(0.8, 1.7, maxf(reach_k, 0.0)), -0.25, 0.15)
			pose.fore_l = Vector3(lerpf(1.4, 0.1, maxf(reach_k, 0.0)) + rec * 0.8, 0, 0)
			pose.fore_r = Vector3(lerpf(1.4, 0.1, maxf(reach_k, 0.0)) + rec * 0.8, 0, 0)
			pose._torso = Vector3(lerpf(0.25 * wind, -0.75, hit) + rec * 0.3, 0, 0)
			pose._head = Vector3(lerpf(-0.35 * wind, 0.6, hit), 0, 0)


# =========================================================================
# Survivors (how other players see you)
# =========================================================================

## st: {phase, speed, pitch, sprint, crouch, down, aim, reload, air, kick
## (0..1 recoil), melee (1 -> 0 through a swing), throw (1 -> 0)};
## optional: side (sideways speed, m/s, + = right), turn (rad/s), slide.
## `body` is the rig root: it lowers for a crouch and lies back when downed.
static func survivor_pose(p: Dictionary, body: Node3D, st: Dictionary, dt: float) -> void:
	var spd: float = st.speed
	var phase: float = st.phase
	var pitch: float = st.pitch
	var down: bool = st.down
	var slide: bool = st.get("slide", false) and not down
	var sprint: bool = st.sprint and not down and not slide
	var crouch: bool = st.crouch and not down and not slide
	var side: float = clampf(st.get("side", 0.0), -6.0, 6.0)
	var turn: float = clampf(st.get("turn", 0.0), -6.0, 6.0)
	var moving := clampf(spd / 4.6, 0.0, 1.0)
	var s := sin(phase)
	var pose := {}
	# whole body: lie back when downed, sink into a crouch, lean back in a slide
	var lie := 1.2 if down else (0.0 if not slide else 0.0)
	var k := clampf(dt * 8.0, 0.0, 1.0)
	body.rotation.x = lerpf(body.rotation.x, lie, clampf(dt * 6.0, 0.0, 1.0))
	body.rotation.z = lerpf(body.rotation.z, -side * 0.025 if not down else 0.0, k)
	var bob := (1.0 - absf(s)) * (0.06 if sprint else 0.03) * moving if not st.air and not down and not slide else 0.0
	var low := 0.32 if down else (-0.28 if crouch else (-0.45 if slide else 0.0))
	body.position.y = lerpf(body.position.y, low + bob, clampf(dt * 12.0, 0.0, 1.0))
	body.position.z = lerpf(body.position.z, 0.55 if down else 0.0, clampf(dt * 6.0, 0.0, 1.0))
	# legs
	if down:
		pose.leg_l = Vector3(PI * 0.5 - lie + 0.1, 0, -0.1)
		pose.leg_r = Vector3(PI * 0.5 - lie + 0.5, 0, 0.1)
		pose.shin_l = Vector3(-0.15, 0, 0)
		pose.shin_r = Vector3(-0.9, 0, 0)
	elif slide:
		# lead leg out straight, the other folded under
		pose.leg_l = Vector3(1.35, 0, -0.1)
		pose.shin_l = Vector3(-0.1, 0, 0)
		pose.leg_r = Vector3(0.3, 0, 0.15)
		pose.shin_r = Vector3(-2.0, 0, 0)
	elif st.air:
		pose.leg_l = Vector3(0.85, 0, -0.05)
		pose.leg_r = Vector3(0.2, 0, 0.05)
		pose.shin_l = Vector3(-1.3, 0, 0)
		pose.shin_r = Vector3(-0.5, 0, 0)
	elif crouch:
		gait(pose, phase, 0.28 * moving, 0.4 * moving, 0.85)
	else:
		gait(pose, phase, (0.8 if sprint else 0.48) * moving, (1.45 if sprint else 0.8) * moving, 0.0, 0.0, 0.04)
		# strafing: the legs splay toward the step
		pose.leg_l.z -= side * 0.04
		pose.leg_r.z -= side * 0.04
	# torso and head
	var torso_x := clampf(pitch * 0.15, -0.2, 0.2) - (0.32 if sprint else 0.0) - (0.2 if crouch else 0.0) + (0.55 if slide else 0.0)
	var twist := -s * (0.18 if sprint else 0.08) * moving
	var melee: float = st.melee
	if melee > 0.0:
		twist = lerpf(-0.6, 0.55, ease(1.0 - melee, 0.5))
	var roll := turn * 0.04 + side * 0.03
	pose.torso = Vector3(torso_x, twist, roll)
	pose.head = Vector3(clampf(pitch * 0.6 - torso_x, -0.7, 0.7), -twist * 0.8, -roll * 0.6)
	# arms: aim the gun where they look (angles relative to the torso)
	var aim := PI * 0.5 + pitch - torso_x - (lie if down else 0.0)
	var r_el := 0.25
	var r_sh := aim - r_el
	var l_el := 0.65
	var l_sh := aim - 0.5
	var l_yaw := -0.55
	if sprint and not st.aim:
		# gun across the chest, arms pumping with the stride
		r_sh = 0.5 + s * 0.25
		r_el = 1.35
		l_sh = 0.65 - s * 0.25
		l_el = 1.25
		l_yaw = -0.35
	if slide:
		l_sh = 1.1
		l_el = 0.3
		l_yaw = 0.9      # off hand out for balance
	if st.reload:
		var wob := sin(Time.get_ticks_msec() * 0.009) * 0.3
		r_sh = aim - 0.8
		l_sh = 0.45 + wob
		l_el = 1.75
		l_yaw = -0.25
	r_sh += float(st.kick) * 0.35
	if melee > 0.0:
		var m := 1.0 - melee
		l_sh = lerpf(2.4, 0.5, ease(m, 0.4))
		l_el = lerpf(1.3, 0.1, m)
		l_yaw = lerpf(1.0, -1.2, ease(m, 0.4))
	var throw_t: float = st.throw
	if throw_t > 0.0:
		var m := 1.0 - throw_t
		l_sh = lerpf(3.0, 0.6, ease(m, 0.35)) if m > 0.3 else lerpf(1.0, 3.1, m / 0.3)
		l_el = lerpf(1.5, 0.15, m)
		l_yaw = 0.1
	pose.arm_r = Vector3(r_sh, 0.12, 0.06)
	pose.fore_r = Vector3(r_el, 0, 0)
	pose.arm_l = Vector3(l_sh, l_yaw, -0.1)
	pose.fore_l = Vector3(l_el, 0, 0)
	apply(p, pose, 7.0, 0.75, dt)
