extends Node3D
## The Cinderhold outpost: builds the voxel map from the layout below, owns
## the walkability grid, enemy flow fields, doors, zones and interactables.
##
## One map cell is 1 m. Legend:
##   #  wall           ,  barracks planks   ;  hall tiles   .  cobble   :  earth
##   A-D door cells    S  player spawn
##   k bunk  t table  o barrel  c crate  w well  T dead tree  g grave  b brazier  l lantern
##
## The ash vents enemies climb out of are placed at random each match (see
## _place_vents), from a seed the host shares so every player sees the same.

signal door_opened(letter: String)

const VB := preload("res://scripts/voxel/voxel_builder.gd")
const M := preload("res://scripts/voxel/models.gd")

const LAYOUT := [
	"########################################",
	"#,kk,,kk,,,,kk,,kk,#;;;;;;;;;b;;;;;;;;;#",
	"#,,,,,,,,,,,,,,,,,,#;;;;;;;;;;;;;;;;;;;#",
	"#,,,,,,,,,,,,,,,,,,#;;;;;;;;;;;;;;;;;;;#",
	"#,,,,,,,,b,,,,,,,,,#;;;#;;;#;;;;#;;;#;;#",
	"#,,,,,,,,,,,,,,,,,,C;;;;;;;;;;;;;;;;;;;#",
	"#,,,,,,,,,,,,,,,,,,C;;;;;;;;;;;;;;;;;;;#",
	"#,,,,tt,,,,tt,,,,,,#;;;;;;;;;;;;;;;;;;;#",
	"#,,,,,,,,,,,,,,,,,,#;;;;;;;;;;;;;;;;;;;#",
	"#,,,,,,,,,,,,,,,,,,#;;;#;;;#;;;;#;;;#;;#",
	"#,,,,,,,,,,,,,,cc,,#;;;;;;;;;;;;;;;;;;;#",
	"#,o,,,,,,,,,,,,,c,,#;c;;;;;;;;;;;;;;;o;#",
	"#,,,,,,,,,,,,,,,,,,#;;;;;;;;;;;;;;;;;;;#",
	"########AA####################DD########",
	"#......................#:::::::::::::b:#",
	"#.l.........o..........#:::::::::::::::#",
	"#................cc....#::::::::::T::::#",
	"#.................c....#:::T:::::::::::#",
	"#......................#:::::::::::::::#",
	"#.....ww...SS..........#::::::::gg:::::#",
	"#.....ww...SS..........B:l:::::::::::::#",
	"#......................B::::g::::::::::#",
	"#............b.........#:::::::::::g:::#",
	"#......................#::::::T::::::::#",
	"#......................#:::::::::::::::#",
	"#......................#:::::::::::::::#",
	"#..co...............l..#::T:::::::::T::#",
	"#......................#:::::::::::::::#",
	"#......................#:::::::::::::::#",
	"########################################",
]

const DOORS := {
	"A": {"cost": 750, "name": "Barracks Gate"},
	"B": {"cost": 750, "name": "Garden Gate"},
	"C": {"cost": 1000, "name": "Great Hall Door"},
	"D": {"cost": 1000, "name": "Hall Cellar Door"},
}

## Interactables: kind, key, cell, facing (direction the front looks).
const PLACEMENTS := [
	{"kind": "wallbuy", "key": "kestrel", "cell": Vector2i(4, 13), "face": Vector3.BACK},
	{"kind": "wallbuy", "key": "tinder", "cell": Vector2i(15, 13), "face": Vector3.BACK},
	{"kind": "wallbuy", "key": "warden", "cell": Vector2i(14, 13), "face": Vector3.FORWARD},
	{"kind": "wallbuy", "key": "breacher", "cell": Vector2i(25, 13), "face": Vector3.FORWARD},
	{"kind": "tonic", "key": "ironhide", "cell": Vector2i(9, 1), "face": Vector3.BACK},
	{"kind": "tonic", "key": "quickhands", "cell": Vector2i(38, 6), "face": Vector3.LEFT},
	{"kind": "tonic", "key": "fleetfoot", "cell": Vector2i(38, 17), "face": Vector3.LEFT},
	{"kind": "tonic", "key": "secondwind", "cell": Vector2i(24, 27), "face": Vector3.RIGHT},
	{"kind": "forge", "key": "forge", "cell": Vector2i(33, 1), "face": Vector3.BACK},
	{"kind": "cache", "key": "cache", "cell": Vector2i(30, 28), "face": Vector3.FORWARD},
]

const TerrainScript := preload("res://scripts/world/terrain.gd")
const WALKABLE := ",;.:S"
## Vents per zone each match (half the old fixed ten).
const VENT_QUOTA := {"court": 2, "barracks": 1, "hall": 1, "garden": 1}

var W := 0
var H := 0
var walk := PackedByteArray()     # 1 = enemies and players can stand here
var doors := {}                   # letter -> {cost, name, cells, open, node}
var vents: Array = []             # [{cell, pos}]
var player_spawns: Array[Vector3] = []
var interactables: Array = []
var active_cells := PackedByteArray()
var _lights: Array = []
var _time := 0.0
var _rng := RandomNumberGenerator.new()
var _world_body: StaticBody3D
var menu_mode := false


## Build the whole outpost. Pass `report(fraction, stage)` to build across
## several frames behind a loading screen (await it); without one it runs
## straight through, which tests rely on.
func build(for_menu := false, report := Callable(), vent_seed := 0) -> void:
	_report = report
	_slice_t = Time.get_ticks_msec()
	menu_mode = for_menu
	_rng.seed = 90210
	_vent_seed = vent_seed
	H = LAYOUT.size()
	W = LAYOUT[0].length()
	walk.resize(W * H)
	for y in H:
		for x in W:
			walk[y * W + x] = 1 if WALKABLE.contains(_ch(x, y)) else 0
	_world_body = StaticBody3D.new()
	_world_body.name = "WorldBody"
	_world_body.collision_layer = 1
	_world_body.collision_mask = 0
	add_child(_world_body)
	var off := OS.get_environment("CINDER_DISABLE").split(",")   # dev bisecting
	await _step(0.02, "Lighting the braziers…")
	# props build on worker threads while the terrain does
	var props_task := _start_prop_builds()
	if not "env" in off:
		_build_environment()
	if not "terrain" in off:
		await _build_terrain()
	await _step(0.7, "Furnishing the outpost…")
	await _finish_tasks(props_task, 0.7, 0.86, "Furnishing the outpost…")
	await _build_props()
	_place_vents()
	await _step(0.9, "Hanging the doors…")
	_build_doors()
	_build_interactables()
	await _step(0.96, "Stirring the ash…")
	if not "atmosphere" in off:
		_build_atmosphere()
	for n in get_children():
		if ("lights" in off and n is Light3D) or ("particles" in off and n is GPUParticles3D) \
				or ("labels" in off and n is Label3D):
			n.queue_free()
	_recompute_active()
	await _step(1.0)
	_report = Callable()


var _report := Callable()
var _slice_t := 0
var _vent_seed := 0


## Report progress and, when building asynchronously, hand the frame back once
## a slice of work has taken ~25 ms so the loading screen keeps animating.
func _step(f: float, stage := "") -> void:
	if not _report.is_valid():
		return
	_report.call(f, stage)
	if Time.get_ticks_msec() - _slice_t > 25:
		await get_tree().process_frame
		_slice_t = Time.get_ticks_msec()


func _ch(x: int, y: int) -> String:
	if x < 0 or y < 0 or x >= W or y >= H:
		return "#"
	return LAYOUT[y][x]


## The floor style a cell sits on (props and vents stand on their zone's floor).
func _floor_ch(x: int, y: int) -> String:
	var c := _ch(x, y)
	if ",;.:".contains(c):
		return c
	if y < 13:
		return "," if x < 19 else ";"
	if y > 13:
		return "." if x < 23 else ":"
	return ";"


## What a footstep at `p` sounds like: "wood", "stone" or "dirt".
func surface_at(p: Vector3) -> String:
	var c := cell_of(p)
	var ch := _floor_ch(c.x, c.y)
	if ch == ",":
		return "wood"
	if ch == ":" or (ch == ";" and c.y >= 6 and c.y <= 7 and c.x >= 20):
		return "dirt"     # garden earth, and the hall's carpet runner is just as soft
	return "stone"


func cell_center(c: Vector2i) -> Vector3:
	return Vector3(c.x + 0.5, 0.0, c.y + 0.5)


func cell_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x), floori(p.z))


func is_walkable(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < W and c.y < H and walk[c.y * W + c.x] == 1


func is_active(c: Vector2i) -> bool:
	return is_walkable(c) and active_cells[c.y * W + c.x] == 1


func bounds() -> AABB:
	return AABB(Vector3.ZERO, Vector3(W, 4, H))


# =========================================================================
# Terrain: floors and walls as chunked voxel meshes + merged colliders
# =========================================================================

## Meshes built once per session: the menu's backdrop and every match share
## them (the terrain never changes; vents and props are placed separately).
static var _terrain_meshes: Array[ArrayMesh] = []


func _build_terrain() -> void:
	if _terrain_meshes.is_empty():
		var t = TerrainScript.new()
		var doors := "".join(DOORS.keys())
		# Columns first (one task), then every chunk in parallel.
		await _run_tasks(func(_i): t.setup(LAYOUT, _floor_ch, doors), 1, 0.05, 0.15, "Laying the stones…")
		var n: int = t.chunk_count()
		var results := []
		results.resize(n)
		await _run_tasks(func(i): results[i] = t.mesh_chunk(i), n, 0.15, 0.65, "Raising the walls…")
		for i in n:
			_terrain_meshes.append(VB.arrays_to_mesh(results[i], TerrainScript.VS, Vector3.ZERO, 2.5, false))
	for i in _terrain_meshes.size():
		var mi := MeshInstance3D.new()
		mi.mesh = _terrain_meshes[i]
		mi.name = "Chunk_%d" % i
		add_child(mi)
	_build_colliders()


## Run job(i) for i in [0, count) on the worker pool, keeping the loading
## screen alive (progress from f0 to f1) while they finish.
func _run_tasks(job: Callable, count: int, f0: float, f1: float, stage: String) -> void:
	await _finish_tasks(WorkerThreadPool.add_group_task(job, count, -1, true, "Cinderhold: " + stage), f0, f1, stage)


func _finish_tasks(task: int, f0: float, f1: float, stage: String) -> void:
	while not WorkerThreadPool.is_group_task_completed(task):
		if _report.is_valid():
			_report.call(f0 + (f1 - f0) * 0.5, stage)
			await get_tree().process_frame
		else:
			OS.delay_msec(1)
	WorkerThreadPool.wait_for_group_task_completion(task)
	_slice_t = Time.get_ticks_msec()


func _add_box(center: Vector3, size: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	cs.position = center
	_world_body.add_child(cs)


func _build_colliders() -> void:
	# floor slab and an invisible lid so nobody leaves the outpost
	_add_box(Vector3(W / 2.0, -0.5, H / 2.0), Vector3(W, 1.0, H))
	_add_box(Vector3(W / 2.0, 7.5, H / 2.0), Vector3(W, 1.0, H))
	for y in H:
		var x := 0
		while x < W:
			if _ch(x, y) == "#":
				var x0 := x
				while x < W and _ch(x, y) == "#":
					x += 1
				_add_box(Vector3((x0 + x) / 2.0, 3.5, y + 0.5), Vector3(x - x0, 7.0, 1.0))
			else:
				x += 1


# =========================================================================
# Props
# =========================================================================

func _place_mesh(mesh: Mesh, pos: Vector3, yaw := 0.0, scale_v := 1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation.y = yaw
	mi.scale = Vector3.ONE * scale_v
	add_child(mi)
	return mi


## Every prop model this map uses, built in parallel on worker threads
## (models.gd caches them, so placing them later just reuses the meshes).
## Returns the group task, or -1 when there's nothing to build.
func _start_prop_builds() -> int:
	var jobs: Array[Callable] = [M.crate, M.barrel, M.brazier, M.lantern_post, M.well, M.bunk, M.table,
		M.vent, M.forge, M.cache_chest, M.plaque, func(): M.door(2.0, 3.0)]
	for k in ["ironhide", "quickhands", "fleetfoot", "secondwind"]:
		var color: Color = preload("res://scripts/game/perks.gd").PERKS[k].color
		jobs.append(func(): M.tonic_machine(color))
	for y in H:
		for x in W:
			match _ch(x, y):
				"T":
					var sd := x * 31 + y
					jobs.append(func(): M.dead_tree(sd))
				"g":
					var sd := x + y * 3
					jobs.append(func(): M.gravestone(sd))
	for i in 14:
		jobs.append(func(): M.ruin(i))
	return WorkerThreadPool.add_group_task(func(i): jobs[i].call(), jobs.size(), -1, true, "Cinderhold: props")


func _build_props() -> void:
	var done := {}
	for y in H:
		await _step(0.86 + 0.03 * y / H)
		for x in W:
			var ch := _ch(x, y)
			var c := Vector3(x + 0.5, 0, y + 0.5)
			var jitter := (_rng.randf() - 0.5) * 0.3
			match ch:
				"k":
					if not done.has(Vector2i(x - 1, y)):
						done[Vector2i(x, y)] = true
						_place_mesh(M.bunk(), Vector3(x + 1.0, 0, y + 1.0), PI * 0.5)
						_add_box(Vector3(x + 1.0, 0.7, y + 0.5), Vector3(2.0, 1.4, 1.0))
				"t":
					if not done.has(Vector2i(x - 1, y)):
						done[Vector2i(x, y)] = true
						_place_mesh(M.table(), Vector3(x + 1.0, 0, y + 0.5))
						_add_box(Vector3(x + 1.0, 0.4, y + 0.5), Vector3(2.0, 0.8, 0.9))
				"o":
					_place_mesh(M.barrel(), c, jitter * 6.0)
					_add_box(c + Vector3(0, 0.47, 0), Vector3(0.85, 0.94, 0.85))
				"c":
					_place_mesh(M.crate(), c, jitter)
					_add_box(c + Vector3(0, 0.44, 0), Vector3(0.95, 0.88, 0.95))
					if absi(hash(Vector2i(x, y))) % 3 == 0:
						_place_mesh(M.crate(), c + Vector3(0, 0.875, 0), jitter * 3.0, 0.8)
						_add_box(c + Vector3(0, 1.15, 0), Vector3(0.8, 0.7, 0.8))
				"w":
					if _ch(x - 1, y) != "w" and _ch(x, y - 1) != "w":
						_place_mesh(M.well(), Vector3(x + 1.0, 0, y + 1.0))
						_add_box(Vector3(x + 1.0, 0.5, y + 1.0), Vector3(1.9, 1.0, 1.9))
				"T":
					_place_mesh(M.dead_tree(x * 31 + y), c, _rng.randf() * TAU)
					_add_box(c + Vector3(0, 1.5, 0), Vector3(0.4, 3.0, 0.4))
				"g":
					_place_mesh(M.gravestone(x + y * 3), c, PI + jitter)
					_add_box(c + Vector3(0, 0.45, 0), Vector3(0.7, 0.9, 0.3))
				"b":
					_place_mesh(M.brazier(), c)
					_add_box(c + Vector3(0, 0.5, 0), Vector3(0.7, 1.0, 0.7))
					_add_fire(c + Vector3(0, 0.95, 0), 1.0)
					_add_light(c + Vector3(0, 1.6, 0), Color("ff8a3a"), 9.0, 2.4)
				"l":
					_place_mesh(M.lantern_post(), c, jitter * 4.0)
					_add_box(c + Vector3(0, 1.2, 0), Vector3(0.25, 2.4, 0.25))
					var arm := Vector3(0.42, 2.0, -0.05).rotated(Vector3.UP, jitter * 4.0)
					_add_light(c + arm, Color("ffb066"), 7.0, 1.6)
				"S":
					player_spawns.append(c)
	# skyline: ruined towers and an ash plain beyond the walls
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color("1c1719")
	gm.roughness = 1.0
	ground.material_override = gm
	ground.position = Vector3(W / 2.0, -0.02, H / 2.0)
	add_child(ground)
	for i in 14:
		var a := float(i) / 14.0 * TAU + _rng.randf() * 0.3
		var r := _rng.randf_range(38.0, 70.0)
		var p := Vector3(W / 2.0 + cos(a) * r, 0, H / 2.0 + sin(a) * r)
		_place_mesh(M.ruin(i), p, _rng.randf() * TAU)


## Pick this match's ash vents: VENT_QUOTA cells per zone, on open floor,
## clear of props, doors and the players' spawn, and spread apart. The same
## seed gives the same vents on every peer.
func _place_vents() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _vent_seed
	var blocked := {}
	for it in PLACEMENTS:
		blocked[it.cell] = true
		blocked[it.cell + Vector2i(roundi(it.face.x), roundi(it.face.z))] = true
	var picked: Array[Vector2i] = []
	for zone in VENT_QUOTA:
		var cands: Array[Vector2i] = []
		for y in range(1, H - 1):
			for x in range(1, W - 1):
				var c := Vector2i(x, y)
				if _zone_of(c) != zone or not ",;.:".contains(_ch(x, y)) or blocked.has(c):
					continue
				var open := true
				for d in NEIGH:
					var ch := _ch(x + d.x, y + d.y)
					if DOORS.has(ch) or not (",;.:S#".contains(ch)):
						open = false   # keep doorways and props clear
						break
				if not open:
					continue
				var far := true
				for s in player_spawns:
					if Vector2(s.x, s.z).distance_to(Vector2(x + 0.5, y + 0.5)) < 7.0:
						far = false
				if far:
					cands.append(c)
		for k in VENT_QUOTA[zone]:
			var best := Vector2i(-1, -1)
			var best_d := -1.0
			# best of a few random tries: as far from the other vents as we can
			for t in 12:
				if cands.is_empty():
					break
				var c: Vector2i = cands[rng.randi() % cands.size()]
				var d := 99.0
				for p in picked:
					d = minf(d, Vector2(c).distance_to(Vector2(p)))
				if d > best_d:
					best_d = d
					best = c
			if best.x < 0:
				continue
			picked.append(best)
			cands.erase(best)
	if Settings.bot_driving():
		print("VENTS seed %d: %s" % [_vent_seed, picked])
	for c in picked:
		var pos := cell_center(c)
		vents.append({"cell": c, "pos": pos})
		_place_mesh(M.vent(), pos + Vector3(0, 0.005, 0), rng.randf() * TAU)
		_add_embers_vent(pos)


func _zone_of(c: Vector2i) -> String:
	if c.y < 13:
		return "barracks" if c.x < 19 else "hall"
	return "court" if c.x < 23 else "garden"


func _add_light(pos: Vector3, color: Color, rng_m: float, energy: float, shadows := true) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = color
	l.omni_range = rng_m
	l.light_energy = energy
	l.omni_attenuation = 1.4
	l.shadow_enabled = shadows and Settings.quality() >= 3
	l.light_volumetric_fog_energy = 1.5
	l.distance_fade_enabled = true
	l.distance_fade_begin = 24.0
	l.distance_fade_length = 6.0
	add_child(l)
	_lights.append({"light": l, "base": energy, "seed": _rng.randf() * 100.0})
	return l


static func _soft_dot() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	t.width = 32
	t.height = 32
	return t


static var _particle_mat: StandardMaterial3D


static func particle_material() -> StandardMaterial3D:
	if _particle_mat == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = _soft_dot()
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		_particle_mat = m
	return _particle_mat


static func fire_gradient() -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 0.7, 1.0])
	g.colors = PackedColorArray([Color(1.0, 0.9, 0.5, 0.0), Color(1.0, 0.65, 0.2, 0.9), Color(0.9, 0.25, 0.05, 0.5), Color(0.2, 0.05, 0.02, 0.0)])
	return g


func _add_fire(pos: Vector3, size: float) -> void:
	var p := GPUParticles3D.new()
	p.position = pos
	p.amount = 40 if Settings.quality() >= 1 else 18
	p.lifetime = 0.7
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.22 * size
	pm.direction = Vector3.UP
	pm.spread = 12.0
	pm.initial_velocity_min = 0.9
	pm.initial_velocity_max = 1.8
	pm.gravity = Vector3(0, 1.2, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.35
	pm.scale_min = 0.35
	pm.scale_max = 0.8
	var curve := CurveTexture.new()
	var c := Curve.new()
	c.add_point(Vector2(0, 0.6))
	c.add_point(Vector2(0.3, 1.0))
	c.add_point(Vector2(1, 0.1))
	curve.curve = c
	pm.scale_curve = curve
	var ramp := GradientTexture1D.new()
	ramp.gradient = fire_gradient()
	pm.color_ramp = ramp
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.3, 0.38) * size
	q.material = particle_material()
	p.draw_pass_1 = q
	add_child(p)


func _add_embers_vent(pos: Vector3) -> void:
	var p := GPUParticles3D.new()
	p.position = pos
	p.amount = 10
	p.lifetime = 2.5
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.35
	pm.direction = Vector3.UP
	pm.spread = 25.0
	pm.initial_velocity_min = 0.3
	pm.initial_velocity_max = 0.8
	pm.gravity = Vector3(0, 0.15, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.4
	pm.scale_min = 0.15
	pm.scale_max = 0.3
	var ramp := GradientTexture1D.new()
	ramp.gradient = fire_gradient()
	pm.color_ramp = ramp
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.2, 0.2)
	q.material = particle_material()
	p.draw_pass_1 = q
	add_child(p)


# =========================================================================
# Environment
# =========================================================================

func _build_environment() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://shaders/night_sky.gdshader")
	sky.sky_material = sm
	# Static sky: rendered into the radiance map once, not every frame.
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("3a3f5c")
	env.ambient_light_energy = 0.95
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.45
	env.glow_intensity = 0.9
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 0.9
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.fog_light_color = Color("261c26")
	env.fog_density = 0.018
	env.fog_sky_affect = 0.35
	env.volumetric_fog_density = 0.018
	env.volumetric_fog_albedo = Color("8a7a8a")
	env.volumetric_fog_emission = Color("120808")
	env.volumetric_fog_length = 40.0
	env.ssao_radius = 1.2
	env.ssao_intensity = 2.2
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.1
	Settings.configure_environment(env)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var moon := DirectionalLight3D.new()
	moon.light_color = Color("8fa0d8")
	moon.light_energy = 0.85
	moon.rotation_degrees = Vector3(-52, 150, 0)
	var q := Settings.quality()
	moon.shadow_enabled = q >= 1
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if q < 3 else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	moon.directional_shadow_max_distance = [0.0, 22.0, 32.0, 45.0][q]
	moon.light_volumetric_fog_energy = 0.4
	add_child(moon)


func _build_atmosphere() -> void:
	var p := GPUParticles3D.new()
	p.amount = [60, 140, 260, 360][Settings.quality()]
	p.lifetime = 9.0
	p.preprocess = 9.0
	p.position = Vector3(W / 2.0, 0.5, H / 2.0)
	p.visibility_aabb = AABB(Vector3(-W, -2, -H), Vector3(W * 2, 14, H * 2))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(W / 2.0, 0.5, H / 2.0)
	pm.direction = Vector3(0.3, 1, 0.1)
	pm.spread = 30.0
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 0.6
	pm.gravity = Vector3(0.12, 0.08, 0.05)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.6
	pm.turbulence_noise_scale = 3.0
	pm.scale_min = 0.08
	pm.scale_max = 0.2
	var ramp := GradientTexture1D.new()
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.2, 0.8, 1.0])
	g.colors = PackedColorArray([Color(1, 0.5, 0.15, 0), Color(1, 0.55, 0.2, 0.9), Color(1, 0.35, 0.1, 0.6), Color(1, 0.2, 0.05, 0)])
	ramp.gradient = g
	pm.color_ramp = ramp
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.12, 0.12)
	q.material = particle_material()
	p.draw_pass_1 = q
	add_child(p)


func _process(dt: float) -> void:
	_time += dt
	for l in _lights:
		var s: float = l.seed
		var f := 0.82 + 0.1 * sin(_time * 9.0 + s) + 0.08 * sin(_time * 23.0 + s * 2.0)
		if is_instance_valid(l.light):
			l.light.light_energy = l.base * f


# =========================================================================
# Doors and zones
# =========================================================================

func _build_doors() -> void:
	for letter in DOORS:
		var cells: Array[Vector2i] = []
		for y in H:
			for x in W:
				if _ch(x, y) == letter:
					cells.append(Vector2i(x, y))
		var horizontal := cells.size() > 1 and cells[0].y == cells[1].y
		var center := Vector3.ZERO
		for c in cells:
			center += cell_center(c)
		center /= cells.size()
		var node := StaticBody3D.new()
		node.collision_layer = 1
		node.position = center
		node.rotation.y = 0.0 if horizontal else PI * 0.5
		var mi := MeshInstance3D.new()
		mi.mesh = M.door(float(cells.size()), 3.0)
		node.add_child(mi)
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(cells.size(), 3.0, 0.4)
		cs.shape = bs
		cs.position.y = 1.5
		node.add_child(cs)
		for side in [-1.0, 1.0]:
			var label := Label3D.new()
			label.text = "%s\n%d" % [DOORS[letter].name.to_upper(), DOORS[letter].cost]
			label.font = preload("res://assets/fonts/Bungee-Regular.ttf")
			label.font_size = 40
			label.pixel_size = 0.004
			label.modulate = Color("ffd9a8")
			label.outline_size = 8
			label.outline_modulate = Color(0, 0, 0, 0.8)
			label.position = Vector3(0, 2.2, 0.26 * side)
			label.rotation.y = 0.0 if side > 0 else PI
			node.add_child(label)
		add_child(node)
		doors[letter] = {"cost": DOORS[letter].cost, "name": DOORS[letter].name, "cells": cells, "open": false, "node": node, "pos": center}
		interactables.append({"kind": "door", "key": letter, "cost": DOORS[letter].cost, "pos": center + Vector3(0, 1.0, 0),
			"radius": 2.4, "label": "open the " + DOORS[letter].name})


func open_door(letter: String, animate := true) -> void:
	var d: Dictionary = doors.get(letter, {})
	if d.is_empty() or d.open:
		return
	d.open = true
	for c in d.cells:
		walk[c.y * W + c.x] = 1
	var node: Node3D = d.node
	for child in node.get_children():
		if child is CollisionShape3D:
			child.disabled = true
	if animate:
		Sfx.play_at("door", d.pos + Vector3.UP, 4.0)
		var tw := create_tween()
		tw.tween_property(node, "position:y", -3.1, 1.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_callback(node.queue_free)
		_dust_burst(d.pos)
	else:
		node.queue_free()
	for it in interactables:
		if it.kind == "door" and it.key == letter:
			interactables.erase(it)
			break
	_recompute_active()
	door_opened.emit(letter)


static var _dust_pm: ParticleProcessMaterial
static var _dust_quad: QuadMesh


## Dust kicked up when a door opens. The materials are kept for the whole
## session, so their shaders aren't rebuilt (and recompiled) for every door.
func _dust_burst(pos: Vector3) -> void:
	if _dust_pm == null:
		var pm := ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(1.0, 0.3, 1.0)
		pm.direction = Vector3.UP
		pm.spread = 70.0
		pm.initial_velocity_min = 0.5
		pm.initial_velocity_max = 2.0
		pm.gravity = Vector3(0, -0.5, 0)
		pm.scale_min = 1.0
		pm.scale_max = 2.5
		pm.color = Color(0.6, 0.5, 0.45, 0.35)
		_dust_pm = pm
		var q := QuadMesh.new()
		q.size = Vector2(0.5, 0.5)
		var m := particle_material().duplicate() as StandardMaterial3D
		m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
		q.material = m
		_dust_quad = q
	var p := GPUParticles3D.new()
	p.position = pos + Vector3(0, 0.3, 0)
	p.amount = 40
	p.lifetime = 1.6
	p.one_shot = true
	p.explosiveness = 0.8
	p.process_material = _dust_pm
	p.draw_pass_1 = _dust_quad
	add_child(p)
	p.emitting = true
	get_tree().create_timer(2.5).timeout.connect(p.queue_free)


## Flood-fill from the player spawn to find which cells are reachable.
func _recompute_active() -> void:
	active_cells.resize(W * H)
	active_cells.fill(0)
	var stack: Array[Vector2i] = []
	for s in player_spawns:
		stack.append(cell_of(s))
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		if not is_walkable(c) or active_cells[c.y * W + c.x] == 1:
			continue
		active_cells[c.y * W + c.x] = 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			stack.append(c + d)


func active_vents() -> Array:
	return vents.filter(func(v): return active_cells[v.cell.y * W + v.cell.x] == 1)


# =========================================================================
# Flow fields for enemy pathing (Dijkstra over the 8-connected grid)
# =========================================================================

const NEIGH := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]


## Integer step costs (tenths of a metre) keep every comparison exact.
const STRAIGHT := 10
const DIAGONAL := 14
const UNREACHED := 1 << 30
const DX := [1, -1, 0, 0, 1, 1, -1, -1]
const DY := [0, 0, 1, -1, 1, -1, 1, -1]


## Distance, in tenths of a metre, from every cell to `target`.
##
## Dial's algorithm: Dijkstra with a ring of buckets indexed by distance, so
## there's no heap and no floating point. The old float version could keep
## re-queueing equal-length routes forever on some cells, which froze the host
## whenever a player stepped onto one.
func flow_field(target: Vector2i) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(W * H)
	dist.fill(UNREACHED)
	if not is_walkable(target):
		# stand-in: nearest walkable neighbour (a player hugging a crate)
		for d in NEIGH:
			if is_walkable(target + d):
				target += d
				break
		if not is_walkable(target):
			return dist
	var offs := PackedInt32Array([1, -1, W, -W, W + 1, -W + 1, W - 1, -W - 1])
	var ring: Array = []
	for i in DIAGONAL + 1:
		ring.append([])
	var slots := ring.size()
	var start := target.y * W + target.x
	dist[start] = 0
	ring[0].append(start)
	var pending := 1
	var d := 0
	while pending > 0:
		var bucket: Array = ring[d % slots]
		if not bucket.is_empty():
			ring[d % slots] = []
			pending -= bucket.size()
			for idx in bucket:
				if dist[idx] != d:
					continue   # already reached by a shorter route
				var cx: int = idx % W
				var cy: int = idx / W
				for k in 8:
					var dx: int = DX[k]
					var dy: int = DY[k]
					var nx := cx + dx
					var ny := cy + dy
					if nx < 0 or ny < 0 or nx >= W or ny >= H:
						continue
					var n: int = idx + offs[k]
					if walk[n] == 0:
						continue
					if k >= 4 and (walk[idx + dx] == 0 or walk[idx + dy * W] == 0):
						continue   # no cutting corners
					var nd := d + (DIAGONAL if k >= 4 else STRAIGHT)
					if nd < dist[n]:
						dist[n] = nd
						ring[nd % slots].append(n)
						pending += 1
		d += 1
	return dist


## True if a circle (in the XZ plane) touches no blocked cell.
func circle_free(c: Vector2, r: float) -> bool:
	for cy in range(floori(c.y - r), floori(c.y + r) + 1):
		for cx in range(floori(c.x - r), floori(c.x + r) + 1):
			if cx >= 0 and cy >= 0 and cx < W and cy < H and walk[cy * W + cx] == 1:
				continue
			# nearest point of the blocked cell to the circle's centre
			var qx := clampf(c.x, cx, cx + 1.0)
			var qy := clampf(c.y, cy, cy + 1.0)
			if (c.x - qx) * (c.x - qx) + (c.y - qy) * (c.y - qy) < r * r:
				return false
	return true


## The best next cell centre to walk toward on a field from position `p`.
func flow_step(field: PackedInt32Array, p: Vector3) -> Vector3:
	var c := cell_of(p)
	if not is_walkable(c):
		# shoved into a prop: head for any walkable neighbour
		for d in NEIGH:
			if is_walkable(c + d):
				return cell_center(c + d)
		return p
	var best := c
	var best_d := field[c.y * W + c.x]
	for k in 8:
		var d: Vector2i = NEIGH[k]
		var n := c + d
		if not is_walkable(n):
			continue
		if k >= 4 and (not is_walkable(Vector2i(c.x + d.x, c.y)) or not is_walkable(Vector2i(c.x, c.y + d.y))):
			continue
		var nd := field[n.y * W + n.x]
		if nd < best_d:
			best_d = nd
			best = n
	return cell_center(best)


## Path distance in metres from `p` to the field's target (INF if unreachable).
func field_distance(field: PackedInt32Array, p: Vector3) -> float:
	var c := cell_of(p)
	if c.x < 0 or c.y < 0 or c.x >= W or c.y >= H:
		return INF
	var v := field[c.y * W + c.x]
	return INF if v >= UNREACHED else v / 10.0


# =========================================================================
# Interactables
# =========================================================================

static func yaw_for(face: Vector3) -> float:
	return atan2(-face.x, -face.z)


func _build_interactables() -> void:
	var W_ := preload("res://scripts/game/weapons.gd")
	var P_ := preload("res://scripts/game/perks.gd")
	for pl in PLACEMENTS:
		var cell: Vector2i = pl.cell
		var face: Vector3 = pl.face
		var yaw := yaw_for(face)
		var node := Node3D.new()
		node.rotation.y = yaw
		add_child(node)
		var it := {"kind": pl.kind, "key": pl.key, "node": node, "radius": 1.9}
		match pl.kind:
			"wallbuy":
				# mounted on the wall face that looks into the room
				var wall_center := cell_center(cell)
				node.position = wall_center + face * 0.5 + Vector3(0, 1.45, 0)
				var plaque := MeshInstance3D.new()
				plaque.mesh = M.plaque()
				node.add_child(plaque)
				var g := MeshInstance3D.new()
				g.mesh = M.gun(pl.key)
				g.position = Vector3(0, 0.3, -0.09)
				g.rotation.y = -PI * 0.5
				node.add_child(g)
				var wd: Dictionary = W_.get_def(pl.key)
				it.cost = wd.cost
				it.label = "buy the %s" % wd.name
				it.pos = node.position + face * 0.6 + Vector3(0, -0.4, 0)
				_add_label(node, "%s\n%d" % [wd.name.to_upper(), wd.cost], Vector3(0, 0.95, -0.06), true)
				_add_light(node.position + face * 0.6 + Vector3(0, 0.6, 0), Color("ffcf8a"), 2.6, 0.5, false)
			"tonic":
				var pd: Dictionary = P_.PERKS[pl.key]
				node.position = cell_center(cell)
				var mi := MeshInstance3D.new()
				mi.mesh = M.tonic_machine(pd.color)
				node.add_child(mi)
				_add_label(node, pd.name.to_upper(), Vector3(0, 2.1, -0.27), false, pd.color.lightened(0.4))
				_add_light(node.position + face * 0.7 + Vector3(0, 1.4, 0), pd.color, 4.5, 1.2, false)
				walk[cell.y * W + cell.x] = 0
				_add_box(node.position + Vector3(0, 1.0, 0), Vector3(0.95, 2.0, 0.95))
				it.cost = pd.cost
				it.label = "drink %s" % pd.name
				it.pos = node.position + face * 0.9 + Vector3(0, 1, 0)
			"forge":
				node.position = Vector3(cell.x + 1.0, 0, cell.y + 0.5)
				var mi := MeshInstance3D.new()
				mi.mesh = M.forge()
				node.add_child(mi)
				for c in [cell, cell + Vector2i(1, 0), cell + Vector2i(0, 1), cell + Vector2i(1, 1)]:
					walk[c.y * W + c.x] = 0
				_add_box(node.position + Vector3(0, 1.1, 0.05), Vector3(1.6, 2.2, 1.0))
				_add_box(node.position + face * 0.75 + Vector3(0, 0.3, 0), Vector3(0.8, 0.6, 0.4))
				_add_light(node.position + face * 0.6 + Vector3(0, 0.6, 0), Color("ff6a1a"), 6.0, 2.5)
				_add_fire(node.position + face * 0.3 + Vector3(0, 0.4, 0), 0.8)
				_add_label(node, "THE EMBER FORGE\n5000", Vector3(0, 2.6, -0.4), false, Color("ffb070"))
				it.cost = 5000
				it.label = "reforge your weapon"
				it.pos = node.position + face * 1.4 + Vector3(0, 1, 0)
			"cache":
				node.position = Vector3(cell.x + 1.0, 0, cell.y + 0.5)
				var parts: Dictionary = M.cache_chest()
				var base := MeshInstance3D.new()
				base.mesh = parts.base
				node.add_child(base)
				var hinge := Node3D.new()
				hinge.name = "Lid"
				hinge.position = parts.hinge
				node.add_child(hinge)
				var lid := MeshInstance3D.new()
				lid.mesh = parts.lid
				hinge.add_child(lid)
				var display := Node3D.new()
				display.name = "Display"
				display.position = Vector3(0, 0.75, 0)
				node.add_child(display)
				for c in [cell, cell + Vector2i(1, 0)]:
					walk[c.y * W + c.x] = 0
				_add_box(node.position + Vector3(0, 0.35, 0), Vector3(1.35, 0.7, 0.75))
				_add_light(node.position + face * 0.5 + Vector3(0, 1.0, 0), Color("b07cff"), 5.0, 1.6, false)
				_add_label(node, "RELIC CACHE\n950", Vector3(0, 1.6, 0), false, Color("d8b8ff"))
				it.cost = 950
				it.label = "open the Relic Cache"
				it.pos = node.position + face * 1.0 + Vector3(0, 1, 0)
		interactables.append(it)


func _add_label(parent: Node3D, text: String, pos: Vector3, flip: bool, color := Color("ffe2b8")) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = preload("res://assets/fonts/Bungee-Regular.ttf")
	l.font_size = 32
	l.pixel_size = 0.0035
	l.modulate = color
	l.outline_size = 8
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.position = pos
	l.rotation.y = PI    # Label3D reads from +Z; our fronts look along -Z
	parent.add_child(l)
	return l


func find_interactable(kind: String, key: String) -> Dictionary:
	for it in interactables:
		if it.kind == kind and it.key == key:
			return it
	return {}
