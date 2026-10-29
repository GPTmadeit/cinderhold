extends RefCounted
## Every model in the game, painted voxel by voxel. Characters come back as
## jointed parts ({part: {mesh, joint, parent}}) with elbows and knees, so
## they can be animated in code (instance them with instance_rig()).
## Convention: +Y up, models face -Z.

const VB := preload("res://scripts/voxel/voxel_builder.gd")

## Fine voxels per authoring voxel: models are painted on the old grid and
## refined at twice the resolution.
const RES := 2

const CHAR_SCALE := 0.0625
const GUN_SCALE := 0.02
const PROP_SCALE := 0.0625

const EMBER := Color("ff7a1a")
const EMBER_HOT := Color("ffc14d")
const BONE := Color("d8cfb2")
const IRON := Color("4a4a50")
const IRON_DARK := Color("2c2c31")
const BRASS := Color("b08a3c")
const WOOD := Color("7a5232")
const WOOD_DARK := Color("4f331f")
const LEATHER := Color("3e2a1c")

static var _cache := {}
static var _lock := Mutex.new()


## Build once, then share. Safe to call from worker threads (the match
## loading screen builds models in parallel).
static func cached(key: String, maker: Callable):
	_lock.lock()
	var hit = _cache.get(key)
	_lock.unlock()
	if hit != null:
		return hit
	var made = maker.call()
	_lock.lock()
	if not _cache.has(key):
		_cache[key] = made
	made = _cache[key]
	_lock.unlock()
	return made


static func V(x: int, y: int, z: int) -> Vector3i:
	return Vector3i(x, y, z)


## Fine-grid coordinates (RES per authoring voxel), for detail.
static func F(x: int, y: int, z: int) -> Vector3i:
	return Vector3i(x, y, z)


## A jointed part: the mesh is built around `joint` (authoring grid, where
## it pivots) and hangs from `parent` ("" = the model root).
static func _part(b: VB, joint: Vector3, scale: float, parent := "") -> Dictionary:
	b.dynamic = true
	return {"mesh": b.build(scale, joint), "joint": joint * scale, "parent": parent}


## Instance a part set under `root`: one pivot per part at its joint, nested
## under its parent, holding the part's mesh. Returns {part: pivot};
## `on_mesh(MeshInstance3D)` is called for each mesh instance.
static func instance_rig(parts: Dictionary, root: Node3D, on_mesh := Callable()) -> Dictionary:
	var pivots := {}
	var pending: Array = parts.keys()
	while not pending.is_empty():
		for pname in pending.duplicate():
			var p: Dictionary = parts[pname]
			var parent: String = p.get("parent", "")
			if parent != "" and not pivots.has(parent):
				continue
			var pv := Node3D.new()
			pv.name = pname
			var mi := MeshInstance3D.new()
			mi.mesh = p.mesh
			pv.add_child(mi)
			if parent == "":
				pv.position = p.joint
				root.add_child(pv)
			else:
				pv.position = p.joint - parts[parent].joint
				pivots[parent].add_child(pv)
			pivots[pname] = pv
			if on_mesh.is_valid():
				on_mesh.call(mi)
			pending.erase(pname)
	return pivots


## Fingers hanging below a hand: `n` fine columns across [x0, x1] at the
## front of the hand, `len` fine voxels long, with claw tips.
static func _fingers(b: VB, fx0: int, fx1: int, fy: int, fz0: int, fz1: int, col: Color, tip: Color, len := 3) -> void:
	for fx in range(fx0, fx1 + 1, 2):
		b.fbox(F(fx, fy - len + 1, fz0), F(fx, fy, fz1), col, 0.06)
		b.fput(F(fx, fy - len, fz0), tip, 0.04)


# =========================================================================
# Husks: the ember-touched dead
# =========================================================================

const SHIRTS := [Color("5b4a3a"), Color("3f4b5a"), Color("6b3a32"), Color("4b5236"), Color("6a6152")]
const PANTS := [Color("3b3630"), Color("2f3540"), Color("453a2c"), Color("33302b")]


## kind: "husk" or "runner". variant picks clothing and wounds.
static func husk(kind: String, variant: int) -> Dictionary:
	return cached("%s_%d" % [kind, variant], func(): return _husk(kind, variant))


static func _husk(kind: String, variant: int) -> Dictionary:
	var runner := kind == "runner"
	var rng := RandomNumberGenerator.new()
	rng.seed = variant * 7919 + (1 if runner else 0)
	var skin := Color("6f7a62") if not runner else Color("7d6f63")
	var skin_dark := skin.darkened(0.35)
	var flesh := Color("5a2a24")
	var shirt: Color = SHIRTS[variant % SHIRTS.size()]
	var pants: Color = PANTS[variant % PANTS.size()]
	var eye := EMBER_HOT if runner else EMBER
	var parts := {}

	# --- head ---
	var h := VB.new(RES)
	h.rbox(V(-3, 24, -3), V(3, 30, 3), skin, 0.1)
	h.rbox(V(-3, 24, -4), V(3, 25, -4), skin_dark, 0.08)       # jaw juts out
	h.box(V(-3, 29, -4), V(3, 29, -4), skin_dark, 0.06)        # brow ridge
	h.carve(V(-2, 27, -3), V(-1, 28, -3))                      # eye sockets
	h.carve(V(1, 27, -3), V(2, 28, -3))
	h.box(V(-2, 27, -2), V(-1, 28, -2), Color("140c0a"), 0.0)
	h.box(V(1, 27, -2), V(2, 28, -2), Color("140c0a"), 0.0)
	for ex in [-3, 3]:                                         # ember pupils, deep in the sockets
		h.fbox(F(ex, 55, -5), F(ex + 1, 56, -5), eye, 0.0, true)
		if runner:
			h.fput(F(ex, 57, -5), EMBER_HOT, 0.0, true)
	h.box(V(-2, 25, -4), V(2, 25, -4), Color("2a1414"), 0.02)   # mouth
	for fx in range(-4, 6):                                    # ragged teeth
		if (fx + variant) % 3 != 0:
			h.fput(F(fx, 51, -8), BONE, 0.05)
		if (fx + variant) % 2 == 0:
			h.fput(F(fx, 50, -8), BONE.darkened(0.15), 0.05)
	h.fbox(F(0, 52, -7), F(1, 53, -7), skin_dark, 0.05)       # nose stub
	h.fput(F(0, 52, -8), Color("1a0e0c"), 0.0)                 # rotted nostril
	for side in [-1, 1]:                                       # torn ears
		var ex := -8 if side < 0 else 7
		h.fbox(F(ex, 54, 0), F(ex, 57, 2), skin_dark, 0.05)
		h.fput(F(ex, 57, 2), flesh, 0.05)
	for i in 3:                                                # cracks in the skin
		var cx := rng.randi_range(-5, 4)
		for k in 4:
			h.fpaint(F(cx + (k % 2), 58 - k, -6), F(cx + (k % 2), 58 - k, -6), skin_dark.darkened(0.3), 0.04)
	for i in 14:                                               # patchy hair
		var px := rng.randi_range(-6, 7)
		var pz := rng.randi_range(-4, 7)
		h.fbox(F(px, 61, pz), F(px, 62 + rng.randi_range(0, 1), pz), Color("1e1a17"), 0.05)
	h.paint(V(-3, 28, 3), V(-1, 30, 3), Color("3a1a14"), 0.05)  # scalp wound
	h.fbox(F(-4, 58, 7), F(-3, 59, 7), EMBER, 0.0, true)
	parts.head = _part(h, Vector3(0.5, 24, 0.5), CHAR_SCALE, "torso")

	# --- torso ---
	var t := VB.new(RES)
	t.rbox(V(-4, 13, -2), V(4, 23, 2), shirt, 0.07)
	t.box(V(-3, 22, -3), V(3, 23, -3), shirt.darkened(0.15), 0.05)  # collar hunch
	t.rbox(V(-2, 23, -2), V(2, 23, 1), skin, 0.08)               # neck
	t.box(V(-4, 13, -2), V(4, 14, 2), LEATHER, 0.06)              # belt
	t.fbox(F(-2, 26, -6), F(1, 29, -6), BRASS, 0.08)              # buckle frame
	t.fbox(F(-1, 27, -6), F(0, 28, -6), LEATHER.darkened(0.2), 0.0)
	# torn shirt: open wound and exposed ribs on the chest
	var rx := rng.randi_range(-3, 0)
	t.paint(V(rx, 16, -2), V(rx + 3, 21, -2), flesh, 0.06)
	for fy in [34, 37, 40, 43]:
		t.fpaint(F(rx * 2 + 1, fy, -4), F(rx * 2 + 6, fy, -4), BONE, 0.06)
	t.fput(F(rx * 2 + 3, 36, -4), EMBER, 0.0, true)
	t.fput(F(rx * 2 + 5, 41, -4), EMBER, 0.0, true)
	for fy in range(32, 46):                                       # torn edge around the wound
		if rng.randf() < 0.5:
			t.fpaint(F(rx * 2 - 1, fy, -4), F(rx * 2 - 1, fy, -4), shirt.darkened(0.3), 0.04)
	# ember veins crawling across the back
	var vx := rng.randi_range(-6, 4)
	for fy in range(30, 45):
		vx = clampi(vx + rng.randi_range(-1, 1), -7, 8)
		t.fpaint(F(vx, fy, 5), F(vx, fy, 5), EMBER if fy % 3 else Color("a8461a"), 0.0, fy % 3 != 0)
	# ragged hem and holes
	for fx in range(-8, 10):
		if rng.randf() < 0.4:
			t.fcarve(F(fx, 26, -4), F(fx, 27 + rng.randi_range(0, 2), -4))
		if rng.randf() < 0.3:
			t.fpaint(F(fx, 30, 5), F(fx, 31, 5), skin, 0.08)
	if variant % 2 == 0:
		t.box(V(-4, 18, 3), V(4, 22, 3), shirt.darkened(0.25), 0.06)  # tattered back flap
		t.carve(V(-1, 18, 3), V(1, 19, 3))
		for fx in range(-8, 10, 3):
			t.fcarve(F(fx, 36, 6), F(fx + 1, 36, 7))
	parts.torso = _part(t, Vector3(0.5, 13, 0.5), CHAR_SCALE)

	# --- arms: upper arm from the shoulder, forearm from the elbow ---
	for side in [-1, 1]:
		var a := VB.new(RES)
		var x0 := 5 if side > 0 else -8
		var x1 := 8 if side > 0 else -5
		a.rbox(V(x0, 16, -2), V(x1, 23, 1), skin, 0.1)
		a.rbox(V(x0, 11, -2), V(x1, 15, 1), skin, 0.1)
		var sleeve_end := 17 if (variant + side) % 2 == 0 else 20
		a.box(V(x0, sleeve_end, -2), V(x1, 23, 1), shirt, 0.07)
		for fx in range(x0 * 2, x1 * 2 + 2):                       # frayed cuff
			if rng.randf() < 0.5:
				a.fpaint(F(fx, sleeve_end * 2, -4), F(fx, sleeve_end * 2, 3), shirt.darkened(0.3), 0.04)
		a.rbox(V(x0, 10, -2), V(x1, 11, 1), skin_dark, 0.08)        # hand
		_fingers(a, x0 * 2, x1 * 2 + 1, 19, -4, -3, skin_dark, BONE, 3 if runner else 2)
		a.paint(V(x0, 14, -2), V(x1, 15, -2), flesh, 0.05)          # gash
		a.fpaint(F(x0 * 2 + 2, 29, -4), F(x0 * 2 + 5, 29, -4), BONE, 0.04)
		if (variant + side) % 3 == 0:
			a.fput(F(x0 * 2 + 3, 30, -4), EMBER, 0.0, true)
		var fore := a.split_below(16 * RES)
		var jx := (x0 + x1 + 1) / 2.0
		var s := "r" if side > 0 else "l"
		parts["arm_" + s] = _part(a, Vector3(jx, 22, 0.0), CHAR_SCALE, "torso")
		parts["fore_" + s] = _part(fore, Vector3(jx, 16, 0.0), CHAR_SCALE, "arm_" + s)

	# --- legs: thigh from the hip, shin from the knee ---
	for side in [-1, 1]:
		var l := VB.new(RES)
		var x0 := 1 if side > 0 else -4
		var x1 := 4 if side > 0 else -1
		l.rbox(V(x0, 6, -2), V(x1, 12, 1), pants, 0.07)
		l.rbox(V(x0, 0, -2), V(x1, 5, 1), pants, 0.07)
		if (variant + side) % 2 == 0:
			l.rbox(V(x0, 0, -3), V(x1, 2, 1), Color("2a221c"), 0.06)  # boot
			l.box(V(x0, 3, -2), V(x1, 3, 1), Color("201a15"), 0.04)
			l.fbox(F(x0 * 2, 0, -6), F(x1 * 2 + 1, 0, 3), Color("15110e"), 0.02)   # sole
			for fy in [2, 4]:
				l.fpaint(F(x0 * 2 + 2, fy, -6), F(x1 * 2 - 1, fy, -6), BONE.darkened(0.4), 0.0)  # laces
		else:
			l.rbox(V(x0, 0, -3), V(x1, 2, 1), skin_dark, 0.08)        # bare foot
			l.box(V(x0, 3, -2), V(x1, 5, 1), skin, 0.08)
			for fx in range(x0 * 2, x1 * 2 + 2, 2):
				l.fbox(F(fx, 0, -7), F(fx, 1, -7), skin_dark.darkened(0.1), 0.05)  # toes
		l.paint(V(x0, 7, -2), V(x1 - 1, 9, -2), skin, 0.08)           # torn knee
		l.fpaint(F(x0 * 2, 13, -4), F(x1 * 2 - 1, 13, -4), pants.darkened(0.35), 0.04)
		var shin := l.split_below(6 * RES)
		var jx := (x0 + x1 + 1) / 2.0
		var s := "r" if side > 0 else "l"
		parts["leg_" + s] = _part(l, Vector3(jx, 12, 0.0), CHAR_SCALE)
		parts["shin_" + s] = _part(shin, Vector3(jx, 6, 0.0), CHAR_SCALE, "leg_" + s)
	return parts


# =========================================================================
# Brute: a hulking ash-giant in salvaged armour
# =========================================================================

static func brute() -> Dictionary:
	return cached("brute", _brute)


static func _brute() -> Dictionary:
	var s := 0.075
	var skin := Color("5e5a54")
	var plate := Color("6a5a50")
	var rust := Color("7a4a2a")
	var crack := Color("ff8a2a")
	var rng := RandomNumberGenerator.new()
	rng.seed = 6661
	var parts := {}

	var h := VB.new(RES)
	h.rbox(V(-4, 28, -4), V(4, 35, 4), skin, 0.1)
	h.rbox(V(-5, 31, -5), V(5, 36, 5), plate, 0.1)              # iron helm
	h.carve(V(-3, 31, -5), V(3, 32, -5))                        # visor slit
	h.box(V(-3, 31, -4), V(3, 32, -4), Color("100a08"), 0.0)
	h.fbox(F(-5, 63, -9), F(-4, 64, -9), EMBER_HOT, 0.0, true)  # eyes behind the slit
	h.fbox(F(4, 63, -9), F(5, 64, -9), EMBER_HOT, 0.0, true)
	for fx in range(-9, 11, 4):                                 # rivets
		h.fput(F(fx, 69, -11), IRON_DARK, 0.0)
		h.fput(F(fx, 72, -11), IRON_DARK, 0.0)
	h.paint(V(-5, 35, -5), V(5, 36, 5), rust, 0.15)
	for i in 20:                                                # rust blooms
		var p := F(rng.randi_range(-10, 11), rng.randi_range(62, 73), -11)
		h.fpaint(p, p + F(1, 0, 0), rust.darkened(0.2), 0.1)
	for side in [-1, 1]:                                        # horns, tapering
		h.box(V(6 * side, 34, 0), V(6 * side, 35, 0), BONE, 0.05)
		h.box(V(7 * side, 35, 0), V(7 * side, 37, 0), BONE, 0.05)
		var tx: int = 14 * side + (0 if side > 0 else 1)
		h.fbox(F(tx, 76, -1), F(tx, 79, 0), BONE.darkened(0.2), 0.05)
		h.fput(F(tx, 80, -1), BONE.darkened(0.35), 0.05)
	h.box(V(-3, 28, -5), V(3, 29, -5), Color("2a1414"), 0.0)       # maw
	for fx in range(-6, 8, 2):
		h.fbox(F(fx, 57, -10), F(fx, 59, -10), BONE, 0.05)        # fangs
	parts.head = _part(h, Vector3(0.5, 28, 0.5), s, "torso")

	var t := VB.new(RES)
	t.rbox(V(-7, 14, -4), V(7, 27, 3), skin, 0.1)
	t.rbox(V(-6, 18, -5), V(6, 26, -5), plate, 0.12)               # breastplate
	t.paint(V(-6, 18, -5), V(-3, 21, -5), rust, 0.12)
	for y in [19, 24]:
		for x in [-5, 5]:
			t.put(V(x, y, -6), IRON_DARK, 0.0)
	t.box(V(-1, 21, -6), V(1, 23, -6), EMBER, 0.0, true)           # furnace heart
	t.put(V(0, 22, -7), EMBER_HOT, 0.0, true)
	t.fbox(F(-3, 41, -14), F(4, 41, -14), IRON_DARK, 0.0)          # grate bars over it
	t.fbox(F(-3, 45, -14), F(4, 45, -14), IRON_DARK, 0.0)
	t.rbox(V(-7, 14, -4), V(7, 15, 3), LEATHER, 0.06)
	for x in range(-7, 8, 2):                                     # chain belt
		t.fbox(F(x * 2, 32, -10), F(x * 2 + 1, 33, -10), IRON, 0.05)
		t.fput(F(x * 2 + 1, 31, -10), IRON_DARK, 0.0)
	for y in range(16, 27, 2):                                    # spine embers
		t.put(V(0, y, 4), EMBER, 0.0, true)
		t.put(V(-1, y + 1, 4), skin.darkened(0.3), 0.05)
		t.put(V(1, y + 1, 4), skin.darkened(0.3), 0.05)
	for i in 5:                                                   # glowing cracks in the hide
		var cx := rng.randi_range(-12, 12)
		var cy := rng.randi_range(30, 52)
		for k in 5:
			cx += rng.randi_range(-1, 1)
			t.fpaint(F(cx, cy + k, 7), F(cx, cy + k, 7), crack, 0.0, true)
	parts.torso = _part(t, Vector3(0.5, 14, 0.5), s)

	for side in [-1, 1]:
		var a := VB.new(RES)
		var x0 := 8 if side > 0 else -13
		var x1 := 13 if side > 0 else -8
		a.rbox(V(x0, 17, -3), V(x1, 27, 2), skin, 0.1)
		a.rbox(V(x0, 10, -3), V(x1, 16, 2), skin, 0.1)
		a.rbox(V(x0 - 1, 23, -4), V(x1 + 1, 29, 3), plate, 0.12)     # pauldron
		a.paint(V(x0 - 1, 28, -4), V(x1 + 1, 29, 3), rust, 0.12)
		for z in [-3, 0, 2]:                                        # spikes
			a.put(V(x0 + 2, 30, z), IRON_DARK, 0.0)
			a.fput(F(x0 * 2 + 4, 62, z * 2), IRON, 0.0)
		a.rbox(V(x0 - 1, 6, -4), V(x1 + 1, 11, 3), Color("4a4540"), 0.1)  # huge fist
		for fx in range(x0 * 2 - 1, x1 * 2 + 3, 3):                  # knuckles
			a.fbox(F(fx, 18, -9), F(fx + 1, 20, -9), Color("3a3530"), 0.08)
		a.rbox(V(x0, 12, -3), V(x1, 13, 2), IRON, 0.08)              # shackle
		a.put(V(x0 + 2, 11, -4), IRON_DARK, 0.0)
		for k in 4:                                                 # broken chain
			a.fbox(F(x0 * 2 + 4, 22 - k * 3, -8), F(x0 * 2 + 5, 23 - k * 3, -8), IRON_DARK, 0.0)
		var fore := a.split_below(17 * RES)
		var jx := (x0 + x1 + 1) / 2.0
		var sd := "r" if side > 0 else "l"
		parts["arm_" + sd] = _part(a, Vector3(jx, 26, 0.0), s, "torso")
		parts["fore_" + sd] = _part(fore, Vector3(jx, 17, 0.0), s, "arm_" + sd)

	for side in [-1, 1]:
		var l := VB.new(RES)
		var x0 := 1 if side > 0 else -6
		var x1 := 6 if side > 0 else -1
		l.rbox(V(x0, 7, -3), V(x1, 14, 2), Color("3a352f"), 0.08)
		l.rbox(V(x0, 0, -3), V(x1, 6, 2), Color("3a352f"), 0.08)
		l.rbox(V(x0, 0, -4), V(x1, 3, 2), IRON_DARK, 0.08)            # iron boots
		l.box(V(x0, 6, -4), V(x1, 9, -4), plate, 0.1)               # knee guard
		l.fbox(F(x0 * 2 + 2, 14, -9), F(x1 * 2 - 1, 15, -9), rust, 0.1)
		for fx in range(x0 * 2, x1 * 2 + 2, 3):
			l.fput(F(fx, 2, -9), IRON, 0.0)                         # boot studs
		var shin := l.split_below(7 * RES)
		var jx := (x0 + x1 + 1) / 2.0
		var sd := "r" if side > 0 else "l"
		parts["leg_" + sd] = _part(l, Vector3(jx, 14, 0.0), s)
		parts["shin_" + sd] = _part(shin, Vector3(jx, 7, 0.0), s, "leg_" + sd)
	return parts


# =========================================================================
# Survivors (other players)
# =========================================================================

static func survivor(color_idx: int) -> Dictionary:
	return cached("survivor_%d" % color_idx, func(): return _survivor(color_idx))


static func _survivor(color_idx: int) -> Dictionary:
	var accent: Color = [Color("e8803a"), Color("4aa3df"), Color("7bc950"), Color("c95fd1")][color_idx % 4]
	var cloth := Color("4d5040")
	var vest := Color("3b3d33")
	var helmet := Color("4a4d3c")
	var skin: Color = [Color("c99a78"), Color("8d5d3e"), Color("e0b896"), Color("6b4430")][color_idx % 4]
	var parts := {}

	var h := VB.new(RES)
	h.rbox(V(-3, 24, -3), V(3, 30, 3), skin, 0.06)
	h.rbox(V(-4, 29, -4), V(4, 31, 4), helmet, 0.07)              # helmet
	h.rbox(V(-3, 32, -3), V(3, 32, 3), helmet, 0.07)
	h.box(V(-4, 29, -5), V(4, 29, -5), Color("3a3d2e"), 0.05)      # brim
	h.paint(V(-1, 30, -4), V(1, 32, 4), accent, 0.04)              # stripe
	h.fbox(F(-9, 60, -2), F(-9, 61, 2), Color("2a2b22"), 0.0)       # chin-strap buckles
	h.fbox(F(8, 60, -2), F(8, 61, 2), Color("2a2b22"), 0.0)
	h.box(V(-3, 27, -4), V(3, 28, -4), LEATHER, 0.03)               # goggles
	for gx in [-5, 2]:                                             # lenses in their frames
		h.fbox(F(gx, 55, -9), F(gx + 2, 56, -9), Color("8fd4e0"), 0.0, true)
		h.fput(F(gx, 56, -9), Color("c8f0f8"), 0.0, true)
	h.fbox(F(-1, 54, -9), F(0, 55, -9), Color("2a2620"), 0.0)       # bridge
	h.box(V(-3, 24, -4), V(3, 25, -4), accent.darkened(0.2), 0.06)  # scarf over mouth
	for fx in range(-6, 8, 3):                                     # scarf folds
		h.fpaint(F(fx, 48, -8), F(fx, 51, -8), accent.darkened(0.35), 0.04)
	h.box(V(-4, 27, -1), V(-4, 28, 1), helmet, 0.05)
	h.box(V(4, 27, -1), V(4, 28, 1), helmet, 0.05)
	parts.head = _part(h, Vector3(0.5, 24, 0.5), CHAR_SCALE, "torso")

	var t := VB.new(RES)
	t.rbox(V(-4, 13, -2), V(4, 23, 2), cloth, 0.06)
	t.rbox(V(-4, 15, -3), V(4, 22, -3), vest, 0.06)                 # plate carrier
	for fy in range(31, 45, 4):                                    # stitching
		t.fpaint(F(-8, fy, -6), F(9, fy, -6), vest.darkened(0.25), 0.02)
	for x in [-3, 0, 3]:                                           # mag pouches with flaps
		t.box(V(x - 1, 15, -4), V(x, 18, -4), Color("454738"), 0.05)
		t.fbox(F(x * 2 - 2, 36, -9), F(x * 2 + 1, 37, -9), Color("3a3c2f"), 0.04)
		t.fput(F(x * 2, 35, -9), BRASS, 0.0)
	t.box(V(-4, 22, -2), V(4, 23, 1), accent, 0.05)                 # scarf
	t.box(V(-3, 21, -3), V(-2, 21, -3), accent, 0.05)
	t.fbox(F(6, 42, -7), F(6, 47, -7), Color("2a2b22"), 0.0)        # radio and antenna
	t.fbox(F(5, 40, -7), F(7, 42, -8), Color("32342a"), 0.02)
	t.rbox(V(-3, 14, 3), V(3, 22, 5), Color("5a4a34"), 0.07)        # pack
	t.box(V(-3, 22, 3), V(3, 22, 5), Color("6b5a40"), 0.05)
	t.rbox(V(-3, 23, 3), V(3, 24, 5), Color("6a5a3c"), 0.08)        # bedroll on top
	for fx in [-4, 3]:
		t.fbox(F(fx, 46, 6), F(fx, 49, 11), LEATHER, 0.02)          # bedroll straps
	t.box(V(-2, 15, 6), V(2, 17, 6), Color("3a3020"), 0.05)
	t.fbox(F(3, 41, 12), F(6, 44, 13), IRON_DARK, 0.0)              # lantern cage
	t.fbox(F(4, 42, 13), F(5, 43, 13), EMBER, 0.0, true)
	for fx in [-6, 5]:                                             # shoulder straps
		t.fbox(F(fx, 38, -5), F(fx + 1, 47, -5), LEATHER, 0.03)
	t.box(V(-4, 13, -2), V(4, 14, 2), LEATHER, 0.05)
	t.fbox(F(-1, 26, -5), F(1, 28, -5), BRASS, 0.05)
	parts.torso = _part(t, Vector3(0.5, 13, 0.5), CHAR_SCALE)

	for side in [-1, 1]:
		var a := VB.new(RES)
		var x0 := 5 if side > 0 else -8
		var x1 := 8 if side > 0 else -5
		a.rbox(V(x0, 16, -2), V(x1, 23, 1), cloth, 0.06)
		a.rbox(V(x0, 12, -2), V(x1, 15, 1), cloth, 0.06)
		a.rbox(V(x0, 19, -2), V(x1, 23, 1), vest, 0.05)              # shoulder pad
		a.box(V(x0, 15, -2), V(x1, 15, 1), accent, 0.04)            # armband
		a.rbox(V(x0, 10, -2), V(x1, 12, 1), Color("2e2a24"), 0.05)   # gloves
		_fingers(a, x0 * 2, x1 * 2 + 1, 19, -4, -3, Color("2a2620"), Color("2a2620"), 2)
		a.fpaint(F(x0 * 2, 25, -4), F(x1 * 2 + 1, 25, 3), Color("23201b"), 0.02)  # glove cuff
		var fore := a.split_below(16 * RES)
		var jx := (x0 + x1 + 1) / 2.0
		var sd := "r" if side > 0 else "l"
		parts["arm_" + sd] = _part(a, Vector3(jx, 22, 0.0), CHAR_SCALE, "torso")
		parts["fore_" + sd] = _part(fore, Vector3(jx, 16, 0.0), CHAR_SCALE, "arm_" + sd)

	for side in [-1, 1]:
		var l := VB.new(RES)
		var x0 := 1 if side > 0 else -4
		var x1 := 4 if side > 0 else -1
		l.rbox(V(x0, 6, -2), V(x1, 12, 1), Color("42443a"), 0.06)
		l.rbox(V(x0, 0, -2), V(x1, 5, 1), Color("42443a"), 0.06)
		l.rbox(V(x0, 0, -3), V(x1, 3, 1), Color("2a221c"), 0.05)       # boots
		l.fbox(F(x0 * 2, 0, -6), F(x1 * 2 + 1, 0, 3), Color("15110e"), 0.02)
		for fy in [3, 5]:
			l.fpaint(F(x0 * 2 + 2, fy, -6), F(x1 * 2 - 1, fy, -6), Color("6a5a40"), 0.0)
		l.box(V(x0, 7, -3), V(x1, 8, -3), Color("2e2f27"), 0.04)    # knee pad
		if side > 0:
			l.rbox(V(x1, 8, -1), V(x1 + 1, 10, 0), Color("454738"), 0.05)  # thigh pouch
		var shin := l.split_below(6 * RES)
		var jx := (x0 + x1 + 1) / 2.0
		var sd := "r" if side > 0 else "l"
		parts["leg_" + sd] = _part(l, Vector3(jx, 12, 0.0), CHAR_SCALE)
		parts["shin_" + sd] = _part(shin, Vector3(jx, 6, 0.0), CHAR_SCALE, "leg_" + sd)
	return parts


# =========================================================================
# Weapons. Barrel points -Z; origin is the grip.
# =========================================================================

static func gun(id: String, upgraded := false) -> ArrayMesh:
	return cached("gun_%s_%s" % [id, upgraded], func(): return _gun(id, upgraded))


static var _sights := {}


## Where to look through `id`'s sights, in the gun mesh's own space (metres):
## {kind: "iron" | "dot" | "scope", point: the reticle / front post tip,
## size: the optic window's width}. Aiming puts `point` on the screen centre,
## which is exactly where shots go.
static func gun_sight(id: String) -> Dictionary:
	gun(id)
	_lock.lock()
	var s: Dictionary = _sights.get(id, {"kind": "iron", "point": Vector3(0, 0.13, -0.2), "size": 0.0})
	_lock.unlock()
	return s


## A red-dot sight on the fine grid: a rail, a hollow housing round a window
## centred on the gun's centre line (fine x = 1), and the emitter. Its front
## face is at fine z `fz0`; returns the window centre in mesh space (metres).
static func _red_dot(g: VB, fz0: int, fz1: int, fy: int, body: Color) -> Vector3:
	g.fbox(F(-1, fy, fz0 - 1), F(2, fy + 1, fz1 + 1), IRON_DARK, 0.02)        # rail
	for fz in range(fz0 - 1, fz1 + 2, 2):
		g.fput(F(-1, fy + 1, fz), Color("1c1c20"), 0.0)                       # rail teeth
	var y0 := fy + 2
	var y1 := fy + 11
	g.fbox(F(-3, y0, fz0), F(-2, y1, fz1), body, 0.03)                        # walls
	g.fbox(F(3, y0, fz0), F(4, y1, fz1), body, 0.03)
	g.fbox(F(-3, y0, fz0), F(4, y0 + 1, fz1), body, 0.03)
	g.fbox(F(-3, y1 - 1, fz0 - 1), F(4, y1, fz1), body, 0.03)                  # hood, overhanging
	g.fbox(F(4, y0 + 3, fz1 - 3), F(5, y0 + 5, fz1), Color("2a2a2e"), 0.0)    # brightness knob
	g.fput(F(5, y0 + 4, fz1 - 2), EMBER_HOT, 0.0, true)
	var cy := (y0 + 2 + y1 - 1) / 2.0
	return Vector3(0.0, cy * GUN_SCALE / RES, (fz0 + 1 - 1) * GUN_SCALE / RES)


static func _set_sight(id: String, kind: String, point: Vector3, size := 0.0) -> void:
	_lock.lock()
	_sights[id] = {"kind": kind, "point": point, "size": size}
	_lock.unlock()


static func _gun(id: String, upgraded: bool) -> ArrayMesh:
	var g := VB.new(RES)
	var metal := Color("3d3f45") if not upgraded else Color("2b2226")
	var dark := Color("26272b") if not upgraded else Color("1c1517")
	var wood := WOOD if not upgraded else Color("5a2a22")
	var accent := Color("c9b07a") if not upgraded else EMBER
	var optic := Color("2c2e33")
	match id:
		"tinder":
			g.rbox(V(-1, 3, -12), V(1, 5, 1), metal, 0.04)            # slide
			for fz in range(-4, 3, 2):
				g.fpaint(F(-2, 7, fz), F(3, 11, fz), dark, 0.0)      # rear serrations
			g.fbox(F(3, 8, -10), F(3, 10, -4), Color("15161a"), 0.0)  # ejection port
			g.box(V(-1, 1, -10), V(1, 2, 0), dark, 0.04)            # frame
			g.rbox(V(-1, -6, -1), V(1, 1, 2), wood, 0.06)           # grip
			for fy in range(-11, 1, 2):                              # checkering
				for fz in range(-1, 5, 2):
					g.fpaint(F(-2, fy, fz), F(-2, fy, fz), wood.darkened(0.3), 0.0)
					g.fpaint(F(3, fy, fz), F(3, fy, fz), wood.darkened(0.3), 0.0)
			g.box(V(-1, -7, -1), V(1, -7, 2), dark, 0.0)
			g.box(V(0, -1, -4), V(0, 0, -4), dark, 0.0)              # trigger guard
			g.box(V(0, -1, -4), V(0, -1, -1), dark, 0.0)
			g.put(V(0, 0, -2), accent, 0.0)                         # trigger
			g.fcarve(F(0, 8, -24), F(1, 9, -24))                     # muzzle
			g.fput(F(-2, 7, -12), accent, 0.0)
			g.fput(F(3, 7, -12), accent, 0.0)
			# iron sights: a notch at the back, a post at the front with a glowing dot
			g.fbox(F(-2, 12, 0), F(-1, 14, 1), dark, 0.0)
			g.fbox(F(2, 12, 0), F(3, 14, 1), dark, 0.0)
			g.fbox(F(0, 12, -22), F(1, 14, -21), dark, 0.0)
			g.fput(F(0, 14, -21), accent if not upgraded else EMBER_HOT, 0.0, true)
			_set_sight(id, "iron", Vector3(0.0, 0.15, -0.21))
		"kestrel":
			g.rbox(V(-1, 1, -16), V(1, 5, 3), metal, 0.04)           # receiver
			g.box(V(-1, 2, -26), V(1, 4, -16), dark, 0.03)           # shroud
			for z in range(-25, -16, 2):
				g.paint(V(-1, 3, z), V(1, 3, z), Color("111214"), 0.0)
			g.box(V(0, 3, -28), V(0, 3, -26), dark, 0.0)
			g.fcarve(F(0, 6, -56), F(1, 7, -56))                     # muzzle bore
			g.rbox(V(-1, -9, -11), V(1, 0, -8), dark, 0.03)          # magazine
			for fy in range(-17, -1, 3):
				g.fpaint(F(-2, fy, -22), F(3, fy, -15), Color("1a1b1e"), 0.0)  # mag ribs
			g.paint(V(-1, -9, -11), V(1, -9, -8), accent, 0.0)
			g.rbox(V(-1, -6, -2), V(1, 0, 1), wood, 0.06)            # grip
			g.box(V(0, 4, 3), V(0, 4, 14), dark, 0.0)                # wire stock
			g.box(V(0, -1, 3), V(0, -1, 14), dark, 0.0)
			g.box(V(-1, -2, 14), V(1, 5, 15), dark, 0.0)
			g.box(V(-2, 2, -6), V(-2, 3, -4), accent, 0.0)           # charging handle
			g.fbox(F(3, 6, -14), F(3, 8, -6), Color("15161a"), 0.0)   # ejection port
			_set_sight(id, "dot", _red_dot(g, -20, -11, 12, optic), 0.04)
		"warden":
			g.rbox(V(-1, 1, -20), V(1, 5, 4), metal, 0.04)
			g.rbox(V(-1, 0, -34), V(1, 3, -20), wood, 0.06)          # handguard
			for fz in range(-66, -40, 4):
				g.fpaint(F(-2, 2, fz), F(3, 2, fz + 1), wood.darkened(0.25), 0.0)   # grip grooves
			g.box(V(0, 4, -42), V(0, 4, -20), dark, 0.0)             # barrel
			g.box(V(-1, 3, -43), V(1, 5, -42), dark, 0.0)            # muzzle brake
			g.fcarve(F(-2, 8, -85), F(-2, 9, -84))                   # brake ports
			g.fcarve(F(3, 8, -85), F(3, 9, -84))
			for i in 10:                                             # curved mag
				g.box(V(-1, -1 - i, -12 + i / 3), V(1, -1 - i, -8 + i / 3), dark, 0.03)
			g.rbox(V(-1, -6, 0), V(1, 0, 3), wood, 0.06)
			g.rbox(V(-1, -3, 4), V(1, 4, 18), wood, 0.06)             # stock
			g.box(V(-1, -4, 18), V(1, 5, 19), dark, 0.0)
			g.paint(V(-1, 0, -30), V(1, 0, -24), accent, 0.0)
			g.box(V(-2, 3, -6), V(-2, 4, -4), accent, 0.0)           # bolt handle
			_set_sight(id, "dot", _red_dot(g, -18, -8, 12, optic), 0.04)
		"breacher":
			g.rbox(V(-1, 3, -40), V(1, 5, -2), metal, 0.04)           # barrel
			g.fcarve(F(0, 8, -80), F(1, 9, -80))                     # bore
			g.box(V(-1, 1, -36), V(1, 2, -2), dark, 0.03)             # mag tube
			g.rbox(V(-2, 0, -28), V(2, 2, -18), wood, 0.07)           # pump
			for z in range(-27, -18, 2):
				g.paint(V(-2, 1, z), V(2, 1, z), WOOD_DARK, 0.0)
			g.rbox(V(-1, 0, -2), V(1, 6, 4), metal, 0.04)             # receiver
			g.rbox(V(-1, -6, 2), V(1, 1, 5), wood, 0.06)
			g.rbox(V(-1, -4, 5), V(1, 4, 20), wood, 0.06)
			g.box(V(-1, -5, 20), V(1, 5, 21), Color("1a1a1a"), 0.0)   # recoil pad
			for z in [-3, 1]:
				g.put(V(-2, 3, z), Color("b03020"), 0.0)              # shells on side
				g.put(V(-2, 2, z), BRASS, 0.0)
			_set_sight(id, "dot", _red_dot(g, -4, 6, 14, optic), 0.04)
		"maul":
			g.rbox(V(-2, 0, -18), V(2, 7, 6), metal, 0.04)
			g.box(V(-1, 3, -48), V(1, 5, -18), dark, 0.03)            # barrel
			g.rbox(V(-2, 2, -30), V(2, 6, -18), Color("2f3034"), 0.03) # cooling jacket
			for z in range(-29, -18, 2):
				g.carve(V(-2, 4, z), V(-2, 4, z))
				g.carve(V(2, 4, z), V(2, 4, z))
			g.rbox(V(-4, -9, -12), V(3, -1, -4), Color("4b4a38"), 0.06)  # ammo box
			g.paint(V(-4, -5, -12), V(3, -5, -12), accent, 0.0)
			for fz in range(-23, -8, 3):                               # belt links into the feed
				g.fbox(F(-6, -1, fz), F(-6, 1, fz + 1), BRASS, 0.04)
			g.rbox(V(-1, -6, 2), V(1, -1, 5), wood, 0.06)
			g.rbox(V(-1, -3, 6), V(1, 5, 20), metal, 0.04)
			g.box(V(-3, -1, -44), V(-3, 2, -44), dark, 0.0)            # bipod
			g.box(V(3, -1, -44), V(3, 2, -44), dark, 0.0)
			_set_sight(id, "dot", _red_dot(g, -22, -12, 16, optic), 0.04)
		"longshot":
			g.rbox(V(-1, 1, -18), V(1, 5, 4), metal, 0.04)
			g.box(V(0, 3, -56), V(0, 4, -18), dark, 0.0)
			g.box(V(-1, 2, -58), V(1, 5, -56), dark, 0.0)
			g.rbox(V(-1, 0, -30), V(1, 3, -18), wood, 0.06)
			g.rbox(V(-2, 7, -20), V(2, 10, 0), Color("22252a"), 0.02)  # scope
			g.rbox(V(-3, 6, -22), V(3, 11, -20), Color("22252a"), 0.02)
			g.box(V(-1, 8, -22), V(1, 9, -22), Color("7ac4ff"), 0.0, true)  # lens
			g.fbox(F(-1, 21, -24), F(2, 21, -10), Color("17191c"), 0.0)     # turret
			g.fbox(F(0, 22, -18), F(1, 23, -16), Color("2a2d33"), 0.0)
			g.box(V(-1, 6, -14), V(1, 6, -12), dark, 0.0)
			g.box(V(-1, 6, -6), V(1, 6, -4), dark, 0.0)
			g.box(V(2, 4, -2), V(4, 4, -2), metal, 0.0)                # bolt handle
			g.box(V(4, 3, -2), V(4, 4, -1), accent, 0.0)
			g.rbox(V(-1, -6, 2), V(1, 0, 5), wood, 0.06)
			g.rbox(V(-1, -4, 5), V(1, 5, 22), wood, 0.06)
			g.box(V(-1, 5, 8), V(1, 6, 16), wood.lightened(0.1), 0.05)  # cheek rest
			_set_sight(id, "scope", Vector3(0.0, 0.18, -0.42))
		"cinderbolt":
			g.rbox(V(-2, 0, -14), V(2, 6, 6), Color("5a3a24"), 0.06)    # body
			g.box(V(-1, 1, -30), V(1, 5, -14), BRASS, 0.08)            # emitter
			for z in range(-29, -14, 3):                               # coils
				g.box(V(-3, 0, z), V(3, 6, z), Color("c87f3a"), 0.05)
				g.paint(V(-3, 3, z), V(3, 3, z), EMBER_HOT, 0.0, true)
			g.box(V(-1, 2, -8), V(1, 4, -2), Color("ffb347"), 0.0, true)  # core
			g.box(V(-2, 1, -9), V(-2, 5, -1), Color("8fd4e0"), 0.0)       # glass
			g.box(V(2, 1, -9), V(2, 5, -1), Color("8fd4e0"), 0.0)
			g.put(V(0, 3, -32), Color("ffe08a"), 0.0, true)               # crystal tip
			g.box(V(-1, 2, -31), V(1, 4, -31), Color("ff8a2a"), 0.0, true)
			g.rbox(V(-1, -6, 0), V(1, 0, 3), LEATHER, 0.05)
			g.box(V(-1, 7, -10), V(1, 7, 2), BRASS, 0.08)
			_set_sight(id, "dot", _red_dot(g, -12, -3, 15, BRASS.darkened(0.3)), 0.04)
	if upgraded and id != "cinderbolt":
		var b := g.bounds()
		var z0 := int(b.position.z) + 2
		var z1 := int(b.end.z) - 3
		var stripe_y := int(b.position.y + b.size.y * 0.35)
		g.paint(V(-2, stripe_y, z0), V(2, stripe_y, z1), EMBER, 0.0, true)
	return g.build(GUN_SCALE, Vector3(0.5, 0, 0.5), 3.5 if upgraded else 2.5)


## First-person gloved hands and sleeves holding a gun (two parts).
static func arms() -> Dictionary:
	return cached("fp_arms", func():
		var parts := {}
		for side in [-1, 1]:
			var b := VB.new(RES)
			b.rbox(V(-1, -1, 0), V(1, 1, 16), Color("4d5040"), 0.06)   # sleeve
			for fz in range(4, 32, 6):
				b.fpaint(F(-2, -2, fz), F(3, 3, fz), Color("454839"), 0.03)  # folds
			b.rbox(V(-2, -2, 0), V(2, 1, 2), Color("3b3d33"), 0.04)    # cuff
			b.rbox(V(-1, -2, -4), V(1, 1, -1), Color("2e2a24"), 0.05)  # glove
			for fx in range(-2, 4, 2):                                 # fingers wrapped round the grip
				b.fbox(F(fx, -3, -12), F(fx, 1, -9), Color("2a2620"), 0.05)
				b.fput(F(fx, 1, -9), Color("3a342c"), 0.0)             # knuckles
			b.fbox(F(3, -1, -9), F(3, 1, -6), Color("2a2620"), 0.05)  # thumb
			b.fpaint(F(-2, 2, -6), F(3, 2, -3), Color("3a342c"), 0.02)  # glove seam
			b.paint(V(-1, 1, 7), V(1, 1, 9), Color("e8803a"), 0.04)   # armband
			parts["r" if side > 0 else "l"] = b.build(0.02, Vector3(0.5, 0, 0.5))
		return parts)


## The cinder grenade: a ridged iron egg with a glowing band, lever and pin.
## About 7 cm across, centred on its middle.
static func grenade() -> ArrayMesh:
	return cached("grenade", func():
		var b := VB.new(RES)
		for x in range(-4, 5):
			for y in range(-5, 5):
				for z in range(-4, 5):
					var d := Vector3(x, y * 0.85, z).length()
					if d <= 3.9:
						# pineapple ridges: a darker groove every few voxels
						var groove := (x + 9) % 3 == 0 or (y + 9) % 3 == 0
						b.fput(F(x, y, z), IRON_DARK if groove else Color("3e3f36"), 0.08)
		for x in range(-4, 5):                               # the ember band round its middle
			for z in range(-4, 5):
				var d := Vector2(x, z).length()
				if d > 2.9 and d <= 4.1:
					b.fput(F(x, 0, z), EMBER, 0.0, true)
		b.fbox(F(-1, 4, -1), F(1, 6, 1), IRON, 0.04)          # fuse cap
		b.fbox(F(2, 1, -1), F(2, 6, 0), BRASS, 0.05)          # lever
		b.fbox(F(-2, 7, 0), F(-1, 7, 0), BRASS.lightened(0.2), 0.0)  # pin ring
		b.fput(F(-3, 6, 0), BRASS.lightened(0.2), 0.0)
		b.fput(F(-3, 5, 0), BRASS.lightened(0.2), 0.0)
		return b.build(GUN_SCALE, Vector3(0.25, 0.25, 0.25), 3.0))


## The survivor's knife, blade along -Z, origin in the grip.
static func knife() -> ArrayMesh:
	return cached("knife", func():
		var b := VB.new(RES)
		var steel := Color("8a8c94")
		b.fbox(F(-1, -1, 0), F(1, 1, 10), LEATHER, 0.06)      # grip
		for z in range(1, 10, 3):
			b.fpaint(F(-1, -1, z), F(1, 1, z), LEATHER.darkened(0.3), 0.02)  # binding
		b.fbox(F(-1, -1, 11), F(1, 1, 12), BRASS, 0.05)       # pommel
		b.fbox(F(-1, -3, -1), F(1, 3, -1), BRASS, 0.05)       # guard
		for z in range(-22, -1):                             # blade tapering to a point
			var t := float(-z - 2) / 20.0
			var top := 2 if t < 0.7 else int(round(lerpf(2.0, -1.0, (t - 0.7) / 0.3)))
			b.fbox(F(0, -2, z), F(0, top, z), steel, 0.05)
			b.fput(F(0, -2, z), steel.lightened(0.35), 0.0)  # honed edge
			if t < 0.75:
				b.fput(F(0, 1, z), EMBER, 0.0, true)          # a cinder line in the fuller
		return b.build(GUN_SCALE, Vector3(0.25, 0.25, 0.25), 3.0))


# =========================================================================
# Props and machines (PROP_SCALE, origin at base centre)
# =========================================================================

static func crate() -> ArrayMesh:
	return cached("crate", func():
		var b := VB.new(RES)
		b.box(V(-7, 0, -7), V(7, 13, 7), WOOD, 0.1)
		for y in [3, 6, 9]:
			b.paint(V(-7, y, -7), V(7, y, 7), WOOD_DARK, 0.06)
		for e in [[-7, -7], [-7, 7], [7, -7], [7, 7]]:
			b.box(V(e[0], 0, e[1]), V(e[0], 13, e[1]), WOOD_DARK, 0.05)
			b.box(V(e[0], 0, e[1]), V(e[0], 1, e[1]), IRON, 0.04)
			b.box(V(e[0], 12, e[1]), V(e[0], 13, e[1]), IRON, 0.04)
		b.box(V(-7, 13, -7), V(7, 13, 7), WOOD.darkened(0.1), 0.1)
		for i in range(-6, 7):                                        # diagonal brace
			b.put(V(i, 6 + i * 6 / 7, -8), WOOD_DARK, 0.05)
			b.put(V(i, 6 - i * 6 / 7, 8), WOOD_DARK, 0.05)
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5)))


static func barrel() -> ArrayMesh:
	return cached("barrel", func():
		var b := VB.new(RES)
		for y in 15:
			var r := 5.6 + sin(float(y) / 14.0 * PI) * 0.9
			for x in range(-7, 8):
				for z in range(-7, 8):
					if Vector2(x, z).length() <= r:
						var c := Color("6a4a2c") if y not in [2, 12] else IRON
						b.put(V(x, y, z), c, 0.09)
		b.paint(V(-3, 14, -3), V(3, 14, 3), Color("3a2a1a"), 0.05)
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5)))


static func brazier() -> ArrayMesh:
	return cached("brazier", func():
		var b := VB.new(RES)
		for leg in [[-4, -4], [4, -4], [0, 5]]:
			for y in 9:
				b.put(V(leg[0] * (9 - y) / 9 + leg[0] / 2, y, leg[1] * (9 - y) / 9 + leg[1] / 2), IRON_DARK, 0.04)
		for y in range(9, 14):
			var r := 3.0 + (y - 9) * 0.9
			for x in range(-8, 9):
				for z in range(-8, 9):
					var d := Vector2(x, z).length()
					if d <= r and (d > r - 1.3 or y == 9):
						b.put(V(x, y, z), IRON, 0.08)
		for x in range(-6, 7):
			for z in range(-6, 7):
				var d := Vector2(x, z).length()
				if d <= 6.0:
					var hot := hash(V(x, 0, z)) % 3 == 0
					b.put(V(x, 13, z), EMBER_HOT if hot else EMBER, 0.12, true)
					if d < 3.5 and hash(V(z, 1, x)) % 2 == 0:
						b.put(V(x, 14, z), Color("3a2a22"), 0.1)
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5), 3.0))


static func lantern_post() -> ArrayMesh:
	return cached("lantern", func():
		var b := VB.new(RES)
		b.box(V(-1, 0, -1), V(1, 38, 1), WOOD_DARK, 0.08)
		b.box(V(-2, 0, -2), V(2, 2, 2), Color("4a4448"), 0.08)
		b.box(V(0, 36, -1), V(6, 37, 0), WOOD_DARK, 0.06)             # arm
		b.box(V(5, 30, -2), V(8, 34, 1), IRON_DARK, 0.04)            # lantern cage
		b.box(V(6, 31, -1), V(7, 33, 0), EMBER_HOT, 0.0, true)
		b.box(V(5, 35, -2), V(8, 35, 1), IRON, 0.04)
		b.put(V(6, 36, -1), IRON, 0.0)
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5), 3.5))


## Perk vending cabinet ("tonic"): body colour + glowing sign.
static func tonic_machine(color: Color) -> ArrayMesh:
	return cached("tonic_%s" % color.to_html(), func():
		var b := VB.new(RES)
		var body := color.darkened(0.45)
		b.box(V(-7, 0, -5), V(7, 30, 5), body, 0.08)
		b.box(V(-8, 0, -6), V(8, 1, 6), IRON_DARK, 0.04)              # plinth
		b.box(V(-8, 29, -6), V(8, 31, 6), IRON_DARK, 0.04)
		b.box(V(-6, 31, -4), V(6, 35, -3), color, 0.0, true)         # sign
		b.box(V(-7, 31, -3), V(7, 36, -2), IRON, 0.04)
		b.carve(V(-5, 8, -5), V(5, 24, -5))                           # glass front
		b.box(V(-5, 8, -4), V(5, 24, -4), Color("1a1418"), 0.02)
		for row in [9, 14, 19]:
			b.box(V(-5, row, -5), V(5, row, -5), IRON, 0.03)          # shelves
			for x in [-4, -1, 2]:
				b.box(V(x, row + 1, -5), V(x + 1, row + 3, -5), color.lightened(0.2), 0.04, true)
				b.put(V(x, row + 4, -5), Color("e8e0c8"), 0.0)        # cork
		b.box(V(-6, 2, -6), V(6, 5, -6), IRON, 0.04)                 # dispenser
		b.box(V(-3, 3, -6), V(3, 4, -6), Color("100c0c"), 0.0)
		b.box(V(-7, 25, -6), V(7, 27, -6), BRASS, 0.08)              # nameplate
		for y in range(2, 28, 5):
			b.put(V(-8, y, -6), BRASS, 0.04)                         # rivets
			b.put(V(8, y, -6), BRASS, 0.04)
		b.box(V(-6, 6, 6), V(6, 20, 6), IRON_DARK, 0.04)             # back pipes
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5), 2.2))


static func cache_chest() -> Dictionary:
	return cached("cache", func():
		var base := VB.new(RES)
		var wood := Color("3a2a3a")
		var rune := Color("b07cff")
		base.box(V(-10, 0, -5), V(10, 8, 5), wood, 0.08)
		for x in [-10, -4, 3, 10]:
			base.box(V(x, 0, -6), V(x, 8, 6), IRON, 0.05)
		for x in range(-8, 9, 3):
			base.put(V(x, 4, -6), rune, 0.0, true)
		base.put(V(-1, 5, -6), rune.lightened(0.3), 0.0, true)
		base.put(V(1, 3, -6), rune.lightened(0.3), 0.0, true)
		base.box(V(-11, 0, -7), V(11, 0, 7), Color("2a2026"), 0.05)
		var lid := VB.new(RES)
		lid.box(V(-10, 0, -5), V(10, 2, 5), wood, 0.08)
		lid.box(V(-9, 3, -4), V(9, 3, 4), wood.lightened(0.05), 0.08)
		for x in [-10, -4, 3, 10]:
			lid.box(V(x, 0, -6), V(x, 3, 6), IRON, 0.05)
		lid.box(V(-1, -2, -6), V(1, 1, -6), BRASS, 0.05)             # clasp
		for x in range(-7, 8, 7):
			lid.put(V(x, 4, 0), rune, 0.0, true)
		return {"base": base.build(PROP_SCALE, Vector3(0.5, 0, 0.5), 3.0),
			"lid": lid.build(PROP_SCALE, Vector3(0.5, 0, 5.5), 3.0), "hinge": Vector3(0, 8, 5) * PROP_SCALE})


static func forge() -> ArrayMesh:
	return cached("forge", func():
		var b := VB.new(RES)
		var stone := Color("5a5258")
		b.box(V(-12, 0, -6), V(12, 22, 8), stone, 0.12)
		for y in range(0, 22, 3):                                      # masonry rows
			b.paint(V(-12, y, -6), V(12, y, 8), stone.darkened(0.25), 0.05)
		b.carve(V(-6, 4, -6), V(6, 12, -2))                            # furnace mouth
		b.box(V(-6, 4, -2), V(6, 12, -2), EMBER, 0.15, true)
		b.box(V(-5, 4, -4), V(5, 5, -3), EMBER_HOT, 0.1, true)
		b.box(V(-7, 13, -7), V(7, 14, -7), IRON, 0.05)                 # lintel
		b.box(V(-4, 22, -2), V(4, 34, 4), stone.darkened(0.1), 0.12)  # chimney
		b.box(V(-3, 34, -1), V(3, 34, 3), Color("1a1414"), 0.0)
		# anvil
		b.box(V(-3, 0, -14), V(3, 2, -10), IRON_DARK, 0.04)
		b.box(V(-2, 3, -13), V(2, 5, -11), IRON_DARK, 0.04)
		b.box(V(-6, 6, -14), V(5, 8, -10), IRON, 0.05)
		b.box(V(6, 7, -13), V(8, 8, -11), IRON, 0.05)
		b.box(V(-5, 9, -13), V(1, 9, -12), Color("8a3a1a"), 0.0, true)  # hot blade
		b.box(V(9, 0, -12), V(12, 10, -9), Color("4a3a2a"), 0.08)        # quench bucket
		b.box(V(10, 10, -11), V(11, 10, -10), Color("3a5a6a"), 0.02)
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5), 3.0))


static func vent() -> ArrayMesh:
	return cached("vent", func():
		var b := VB.new(RES)
		var rng := RandomNumberGenerator.new()
		rng.seed = 4242
		for i in 70:
			var a := rng.randf() * TAU
			var r := pow(rng.randf(), 0.6) * 9.0
			var p := V(int(cos(a) * r), 0, int(sin(a) * r))
			var hot := r < 4.0 and rng.randf() < 0.7
			b.put(p, EMBER if hot else Color("2a2224"), 0.15, hot)
		for i in 10:
			var a := rng.randf() * TAU
			b.put(V(int(cos(a) * 8), 1, int(sin(a) * 8)), Color("3a3236"), 0.1)
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5), 2.0))


static func powerup(kind: String) -> ArrayMesh:
	return cached("pu_" + kind, func():
		var b := VB.new(RES)
		var gold := Color("ffcf4d")
		match kind:
			"resupply":
				b.box(V(-5, -3, -3), V(5, 3, 3), Color("4b5a34"), 0.05)
				b.box(V(-5, 3, -3), V(5, 4, 3), Color("3a4628"), 0.05)
				b.box(V(-1, 4, -1), V(1, 5, 1), IRON, 0.0)
				for x in [-3, 0, 3]:
					b.box(V(x, 5, -2), V(x, 8, -2), BRASS, 0.0, true)
					b.put(V(x, 9, -2), Color("b0502a"), 0.0, true)
			"double":
				for x in range(-6, 7):
					for y in range(-6, 7):
						if Vector2(x, y).length() <= 6.2:
							b.put(V(x, y, 0), gold, 0.05, true)
							b.put(V(x, y, 1), gold.darkened(0.2), 0.05)
				var two := [[-1, 3], [0, 3], [1, 3], [1, 2], [1, 1], [0, 0], [-1, -1], [-1, -2], [-1, -3], [0, -3], [1, -3]]
				for p in two:
					b.put(V(p[0] + 1, p[1], -1), Color("6a3a0a"), 0.0)
				b.put(V(-3, 0, -1), Color("6a3a0a"), 0.0)
				b.put(V(-2, -1, -1), Color("6a3a0a"), 0.0)
				b.put(V(-3, -2, -1), Color("6a3a0a"), 0.0)
				b.put(V(-2, 1, -1), Color("6a3a0a"), 0.0)
			"deadeye":
				b.box(V(-5, -2, -4), V(5, 6, 4), BONE, 0.06, true)
				b.box(V(-3, -6, -4), V(3, -3, 3), BONE, 0.06, true)
				b.box(V(-4, 1, -5), V(-1, 3, -5), Color("1a0a0a"), 0.0)
				b.box(V(1, 1, -5), V(4, 3, -5), Color("1a0a0a"), 0.0)
				b.put(V(-2, 2, -6), Color("ff3a2a"), 0.0, true)
				b.put(V(2, 2, -6), Color("ff3a2a"), 0.0, true)
				for x in [-2, 0, 2]:
					b.put(V(x, -5, -5), Color("1a0a0a"), 0.0)
			"purge":
				b.sphere(Vector3(0, 0, 0), 5.5, Color("2a2a30"), 0.05)
				b.box(V(-1, 5, -1), V(1, 7, 1), IRON, 0.0)
				b.put(V(0, 8, 0), EMBER_HOT, 0.0, true)
				b.put(V(1, 9, 0), EMBER, 0.0, true)
				b.paint(V(-6, -1, -6), V(6, 1, 6), Color("b03020"), 0.0, true)
		return b.build(0.04, Vector3(0.5, 0, 0.5), 2.0))


## Door slab sized in metres; planks with iron bands and a chalked price.
static func door(width_m: float, height_m: float) -> ArrayMesh:
	return cached("door_%s_%s" % [width_m, height_m], func():
		var b := VB.new(RES)
		var w := int(width_m * 8)
		var h := int(height_m * 8)
		b.box(V(0, 0, -1), V(w - 1, h - 1, 1), WOOD, 0.12)
		for x in range(0, w, 3):
			b.paint(V(x, 0, -1), V(x, h - 1, 1), WOOD_DARK, 0.06)
		for y in [3, h / 2, h - 4]:
			b.paint(V(0, y, -1), V(w - 1, y + 1, 1), IRON, 0.05)
			for x in range(1, w, 4):
				b.put(V(x, y, -2), IRON_DARK, 0.0)
				b.put(V(x, y, 2), IRON_DARK, 0.0)
		for i in range(0, mini(w, h)):                               # chalk X barricade mark
			b.put(V(i * (w - 1) / maxi(mini(w, h) - 1, 1), h / 2 + 4 + i / 3, -2), Color("d8d0c0"), 0.03)
		return b.build(0.125, Vector3(float(w) / 2.0, 0, 0.5)))


static func plaque() -> ArrayMesh:
	return cached("plaque", func():
		var b := VB.new(RES)
		b.box(V(-9, 0, 0), V(9, 9, 0), Color("3a2a1c"), 0.1)
		b.box(V(-10, -1, 1), V(10, 10, 1), WOOD_DARK, 0.08)
		for p in [[-9, 0], [9, 0], [-9, 9], [9, 9]]:
			b.put(V(p[0], p[1], -1), BRASS, 0.0)
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5)))


static func bunk() -> ArrayMesh:
	return cached("bunk", func():
		var b := VB.new(RES)
		for p in [[-7, -15], [7, -15], [-7, 15], [7, 15]]:
			b.box(V(p[0], 0, p[1]), V(p[0], 22, p[1]), WOOD_DARK, 0.06)
		for y in [4, 15]:
			b.box(V(-7, y, -15), V(7, y + 1, 15), WOOD, 0.08)            # bed frames
			b.box(V(-6, y + 2, -14), V(6, y + 3, 14), Color("6a6a58"), 0.08)  # mattress
			b.box(V(-6, y + 4, -14), V(6, y + 4, 2), Color("5a3a32"), 0.1)    # blanket
			b.box(V(-5, y + 4, 9), V(5, y + 5, 13), Color("b0a890"), 0.06)    # pillow
		b.box(V(-7, 22, -15), V(7, 22, 15), WOOD_DARK, 0.06)
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5)))


static func table() -> ArrayMesh:
	return cached("table", func():
		var b := VB.new(RES)
		b.box(V(-15, 11, -7), V(15, 12, 7), WOOD, 0.1)
		for x in range(-15, 16, 4):
			b.paint(V(x, 12, -7), V(x, 12, 7), WOOD_DARK, 0.05)
		for p in [[-13, -5], [13, -5], [-13, 5], [13, 5]]:
			b.box(V(p[0], 0, p[1]), V(p[0] + 1, 10, p[1] + 1), WOOD_DARK, 0.06)
		b.box(V(-6, 13, -2), V(-4, 15, 0), Color("7a7a80"), 0.05)        # tin mug
		b.box(V(2, 13, -3), V(7, 13, 2), Color("a89870"), 0.08)          # map
		b.put(V(4, 14, 0), Color("b02020"), 0.0)
		b.box(V(9, 13, 1), V(10, 16, 2), Color("d8d0b0"), 0.03)          # candle
		b.put(V(9, 17, 1), EMBER_HOT, 0.0, true)
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5)))


static func well() -> ArrayMesh:
	return cached("well", func():
		var b := VB.new(RES)
		var stone := Color("6b6468")
		for x in range(-14, 15):
			for z in range(-14, 15):
				var d := Vector2(x, z).length()
				if d <= 14.5 and d >= 10.5:
					b.box(V(x, 0, z), V(x, 13, z), stone, 0.12)
				elif d < 10.5:
					b.put(V(x, 4, z), Color("1a2a34"), 0.04)              # water
		for y in [4, 9]:
			for x in range(-14, 15):
				for z in range(-14, 15):
					var d := Vector2(x, z).length()
					if d <= 14.5 and d >= 10.5:
						b.put(V(x, y, z), stone.darkened(0.25), 0.05)
		for s in [-1, 1]:                                              # winch posts
			b.box(V(13 * s, 14, -1), V(13 * s, 30, 1), WOOD_DARK, 0.06)
		b.box(V(-13, 28, 0), V(13, 28, 0), WOOD, 0.06)
		b.box(V(-12, 30, -10), V(12, 31, 10), WOOD.darkened(0.2), 0.1)    # roof
		b.box(V(-10, 32, -7), V(10, 33, 7), WOOD.darkened(0.25), 0.1)
		b.box(V(0, 18, 0), V(0, 27, 0), Color("8a7a5a"), 0.0)             # rope
		b.box(V(-2, 15, -2), V(2, 18, 2), Color("5a4028"), 0.08)          # bucket
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5)))


static func dead_tree(seed_v: int) -> ArrayMesh:
	return cached("tree_%d" % seed_v, func():
		var b := VB.new(RES)
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_v
		var bark := Color("3a2e28")
		for y in 40:
			var r := 2.6 - y * 0.04
			var cx := sin(y * 0.15 + seed_v) * 1.5
			for x in range(-4, 5):
				for z in range(-4, 5):
					if Vector2(x - cx, z).length() <= r:
						b.put(V(x, y, z), bark, 0.1)
		for i in 6:                                                   # branches
			var p := Vector3(0, rng.randi_range(20, 38), 0)
			var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(0.3, 0.9), rng.randf_range(-1, 1)).normalized()
			for step in rng.randi_range(8, 16):
				p += dir
				dir = (dir + Vector3(rng.randf_range(-0.3, 0.3), 0.05, rng.randf_range(-0.3, 0.3))).normalized()
				b.put(Vector3i(p.round()), bark.lightened(0.05), 0.1)
		for x in range(-5, 6):                                        # roots
			for z in range(-5, 6):
				if Vector2(x, z).length() < 5 and rng.randf() < 0.4:
					b.put(V(x, 0, z), bark.darkened(0.2), 0.1)
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5)))


static func gravestone(seed_v: int) -> ArrayMesh:
	return cached("grave_%d" % seed_v, func():
		var b := VB.new(RES)
		var stone := Color("6a6670")
		b.box(V(-5, 0, -2), V(5, 11, 1), stone, 0.12)
		for x in range(-4, 5):
			var top := 11 + int(round(sqrt(maxf(0.0, 16.0 - x * x)) * 0.7))
			b.box(V(x, 12, -2), V(x, top, 1), stone, 0.12)
		b.box(V(-1, 6, -3), V(1, 13, -3), stone.darkened(0.35), 0.0)      # carved mark
		b.box(V(-3, 10, -3), V(3, 11, -3), stone.darkened(0.35), 0.0)
		b.paint(V(-5, 0, -2), V(5, 3, 1), Color("3a4a30"), 0.1)            # moss
		b.box(V(-6, 0, -9), V(6, 1, -3), Color("3a3028"), 0.12)             # grave mound
		if seed_v % 2 == 0:
			b.box(V(-2, 2, -7), V(-1, 3, -6), EMBER, 0.0, true)               # candle stub
		return b.build(PROP_SCALE, Vector3(0.5, 0, 0.5)))


## Distant ruined watchtower for the skyline outside the walls (0.5 m voxels).
static func ruin(seed_v: int) -> ArrayMesh:
	return cached("ruin_%d" % seed_v, func():
		var b := VB.new()   # far off on the skyline: the coarse grid is plenty
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_v
		var hgt := rng.randi_range(10, 26)
		var r := rng.randi_range(3, 5)
		var stone := Color("2a2630")
		for y in hgt:
			var broken := y > hgt - 6
			for x in range(-r, r + 1):
				for z in range(-r, r + 1):
					var edge := absi(x) == r or absi(z) == r
					if edge and (not broken or rng.randf() < 0.55):
						b.put(V(x, y, z), stone, 0.06)
		b.put(V(0, hgt / 2, -r), EMBER, 0.0, true)                     # a lit window
		b.put(V(0, hgt / 2 + 1, -r), EMBER_HOT, 0.0, true)
		return b.build(0.5, Vector3(0.5, 0, 0.5), 4.0))
