extends RefCounted
## Builds Times Square's look from times_square_data.gd: the street level
## (asphalt, crossings, curbs, sidewalks, plaza pavers, storefronts with lit
## windows and signs) at 8 voxels per metre, building facades above it and
## the skyline beyond, collision that follows the real outlines, and the
## props: lamps, screens, subway entrances, wrecked cabs, barricades, rubble.

const D := preload("res://scripts/world/maps/times_square_data.gd")
const VB := preload("res://scripts/voxel/voxel_builder.gd")
const FACADE := preload("res://shaders/facade.gdshader")
const SCREEN := preload("res://shaders/billboard.gdshader")

const STORE_H := 4.5             # storefront height in metres; facades start here
const STORE := 36                # the same in street voxels (8 per metre)

## facade styles: [wall colour, alpha style] by building kind
const STYLE_COLORS := [
	[Color("7a4636"), 0], [Color("6e3a2e"), 0], [Color("a3957f"), 1], [Color("8e8576"), 1],
	[Color("4c484c"), 2], [Color("5a5458"), 2], [Color("3f4a56"), 3], [Color("354048"), 3],
]

var street := PackedInt32Array()     # D.STREET decoded (fine columns)
var sky := PackedInt32Array()        # D.SKYLINE decoded
var styles := PackedInt32Array()     # per building: index into STYLE_COLORS (theatres: -1)
var arena: Node3D
var map: RefCounted

static var _decoded := {}            # the rasters, decoded once per session

static var _cache := {}              # meshes shared by the menu and every match
static var _lock := Mutex.new()


func _init() -> void:
	if _decoded.is_empty():
		var sw := int((D.W + 2 * D.MARGIN) * D.SKY)
		var sh := int((D.H + 2 * D.MARGIN) * D.SKY)
		_decoded.street = _decode(D.STREET, D.W * D.FINE * D.H * D.FINE)
		_decoded.sky = _decode(D.SKYLINE, sw * sh)
	street = _decoded.street
	sky = _decoded.sky
	for i in D.BUILDINGS.size():
		var b: Array = D.BUILDINGS[i]
		var h := absi(hash(str(b[0]) + str(i)))
		match str(b[2]):
			"theatre": styles.append(-1)
			"tower": styles.append(6 + h % 2)
			"lowrise": styles.append(h % 2 if h % 3 else 4 + h % 2)
			_: styles.append(2 + h % 4)


static func _decode(b64: String, size: int) -> PackedInt32Array:
	var raw := Marshalls.base64_to_raw(b64)
	var out := PackedInt32Array()
	out.resize(size)
	var i := 0
	for k in range(0, raw.size(), 4):
		var v := raw.decode_u16(k)
		var n := raw.decode_u16(k + 2)
		if v != 0:
			for j in n:
				out[i + j] = v
		i += n
	return out


func build(a: Node3D, m: RefCounted) -> void:
	arena = a
	map = m
	if not _cache.has("terrain"):
		await _build_meshes()
	var off := OS.get_environment("CINDER_DISABLE").split(",")   # dev bisecting
	for k in ["terrain", "facades"]:
		if k in off:
			continue
		for mesh in _cache[k]:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			arena.add_child(mi)
	_build_collision()
	arena._add_box(Vector3(D.W / 2.0, -0.5, D.H / 2.0), Vector3(D.W + 2, 1.0, D.H + 2))   # the street
	_build_ground()
	if not "props" in off:
		_build_props()
	else:
		for y in arena.H:
			for x in arena.W:
				if arena._ch(x, y) == "S":
					arena.player_spawns.append(Vector3(x + 0.5, 0, y + 0.5))
	# the map definition holds this builder: don't hold it back (a cycle would leak both)
	arena = null
	map = null


# =========================================================================
# Meshes (threaded, built once per session)
# =========================================================================

func _build_meshes() -> void:
	var t := CityTerrain.new()
	await arena._run_tasks(func(_i): t.setup_city(street, D.W * D.FINE, D.H * D.FINE, styles), 1, 0.05, 0.15, "Paving the streets…")
	var n: int = t.chunk_count()
	var results := []
	results.resize(n)
	await arena._run_tasks(func(i): results[i] = t.mesh_chunk(i), n, 0.15, 0.5, "Raising the storefronts…")
	var terrain: Array[ArrayMesh] = []
	for i in n:
		terrain.append(VB.arrays_to_mesh(results[i], 1.0 / t.vpc, Vector3.ZERO, 3.0, false))
	_cache.terrain = terrain
	# facades in tiles, so the camera can skip the ones behind it
	var tiles := 6
	var fac := []
	fac.resize(tiles * tiles)
	await arena._run_tasks(func(i): fac[i] = _facade_arrays(i % tiles, i / tiles, tiles), tiles * tiles, 0.5, 0.7, "Raising the towers…")
	var facades: Array[ArrayMesh] = []
	var mat := ShaderMaterial.new()
	mat.shader = FACADE
	for arr in fac:
		if arr.v.is_empty():
			continue
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = arr.v
		a[Mesh.ARRAY_NORMAL] = arr.n
		a[Mesh.ARRAY_COLOR] = arr.c
		a[Mesh.ARRAY_TEX_UV] = arr.uv
		a[Mesh.ARRAY_TEX_UV2] = arr.uv2
		a[Mesh.ARRAY_INDEX] = arr.i
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		mesh.surface_set_material(0, mat)
		facades.append(mesh)
	_cache.facades = facades


## Walls above the storefronts (and whole walls for the skyline outside the
## play area), plus roofs, for one tile of the skyline raster.
func _facade_arrays(tx: int, tz: int, tiles: int) -> Dictionary:
	var out := {"v": PackedVector3Array(), "n": PackedVector3Array(), "c": PackedColorArray(),
		"uv": PackedVector2Array(), "uv2": PackedVector2Array(), "i": PackedInt32Array()}
	var sw := int((D.W + 2 * D.MARGIN) * D.SKY)
	var sh := int((D.H + 2 * D.MARGIN) * D.SKY)
	var c0 := tx * sw / tiles
	var c1 := (tx + 1) * sw / tiles
	var r0 := tz * sh / tiles
	var r1 := (tz + 1) * sh / tiles
	var s := 1.0 / D.SKY
	# walls facing -z and +z: runs along x
	for r in range(r0, r1):
		for dir in [-1, 1]:
			var run_start := -1
			var run_key := ""
			for c in range(c0, c1 + 1):
				var key := ""
				var b := -1
				var y0 := 0.0
				var y1 := 0.0
				if c < c1:
					b = sky[r * sw + c] - 1
					if b >= 0:
						var nb := -1 if r + dir < 0 or r + dir >= sh else sky[(r + dir) * sw + c] - 1
						y1 = float(D.BUILDINGS[b][1])
						y0 = maxf(_base_h(c, r), float(D.BUILDINGS[nb][1]) if nb >= 0 else 0.0)
						if y1 > y0 + 0.01:
							key = "%d_%.2f" % [b, y0]
				if key != run_key:
					if run_key != "":
						var rb: int = int(run_key.get_slice("_", 0))
						var ry0 := float(run_key.get_slice("_", 1))
						var z := -D.MARGIN + (r + (1.0 if dir > 0 else 0.0)) * s
						var xa := -D.MARGIN + run_start * s
						var xb := -D.MARGIN + c * s
						_wall(out, Vector3(xa, 0, z), Vector3(xb, 0, z), ry0, float(D.BUILDINGS[rb][1]), Vector3(0, 0, dir), rb)
					run_key = key
					run_start = c
	# walls facing -x and +x: runs along z
	for c in range(c0, c1):
		for dir in [-1, 1]:
			var run_start := -1
			var run_key := ""
			for r in range(r0, r1 + 1):
				var key := ""
				if r < r1:
					var b := sky[r * sw + c] - 1
					if b >= 0:
						var nb := -1 if c + dir < 0 or c + dir >= sw else sky[r * sw + c + dir] - 1
						var y1 := float(D.BUILDINGS[b][1])
						var y0 := maxf(_base_h(c, r), float(D.BUILDINGS[nb][1]) if nb >= 0 else 0.0)
						if y1 > y0 + 0.01:
							key = "%d_%.2f" % [b, y0]
				if key != run_key:
					if run_key != "":
						var rb: int = int(run_key.get_slice("_", 0))
						var ry0 := float(run_key.get_slice("_", 1))
						var x := -D.MARGIN + (c + (1.0 if dir > 0 else 0.0)) * s
						var za := -D.MARGIN + run_start * s
						var zb := -D.MARGIN + r * s
						_wall(out, Vector3(x, 0, za), Vector3(x, 0, zb), ry0, float(D.BUILDINGS[rb][1]), Vector3(dir, 0, 0), rb)
					run_key = key
					run_start = r
	# roofs: runs along x
	for r in range(r0, r1):
		var run_start := -1
		var run_b := -1
		for c in range(c0, c1 + 1):
			var b := sky[r * sw + c] - 1 if c < c1 else -1
			if b != run_b:
				if run_b >= 0:
					var y := float(D.BUILDINGS[run_b][1])
					var x0 := -D.MARGIN + run_start * s
					var x1 := -D.MARGIN + c * s
					var z0 := -D.MARGIN + r * s
					_roof(out, x0, x1, z0, z0 + s, y, run_b)
				run_b = b
				run_start = c
	return out


## Facades start above the storefronts inside the play area (the street
## mesher draws those); outside it they go down to the ground.
func _base_h(c: int, r: int) -> float:
	var x := -D.MARGIN + (c + 0.5) / D.SKY
	var z := -D.MARGIN + (r + 0.5) / D.SKY
	return STORE_H if x > 0.0 and z > 0.0 and x < D.W and z < D.H else 0.0


func _style_color(b: int) -> Color:
	var st: int = styles[b]
	if st < 0:
		return Color(Color("c2a882"), 4.0 / 8.0)     # theatre cream
	var e: Array = STYLE_COLORS[st]
	var c: Color = e[0]
	return Color(c.r, c.g, c.b, float(e[1]) / 8.0)


func _wall(out: Dictionary, a: Vector3, b: Vector3, y0: float, y1: float, normal: Vector3, bid: int) -> void:
	var start: int = out.v.size()
	var col := _style_color(bid)
	var lin := Color(col.r, col.g, col.b).srgb_to_linear()
	lin.a = col.a
	var along_a := a.x if normal.z != 0.0 else a.z
	var along_b := b.x if normal.z != 0.0 else b.z
	var seed := float(absi(hash(bid)) % 997) / 997.0
	var corners := [Vector3(a.x, y0, a.z), Vector3(b.x, y0, b.z), Vector3(b.x, y1, b.z), Vector3(a.x, y1, a.z)]
	var uvs := [Vector2(along_a, y0), Vector2(along_b, y0), Vector2(along_b, y1), Vector2(along_a, y1)]
	for k in 4:
		out.v.append(corners[k])
		out.n.append(normal)
		out.c.append(lin)
		out.uv.append(uvs[k])
		out.uv2.append(Vector2(y1, seed))
	# wind so the face points along `normal`
	var flip := (normal.z > 0.0) or (normal.x < 0.0)
	if flip:
		out.i.append_array([start, start + 1, start + 2, start, start + 2, start + 3])
	else:
		out.i.append_array([start, start + 2, start + 1, start, start + 3, start + 2])


func _roof(out: Dictionary, x0: float, x1: float, z0: float, z1: float, y: float, bid: int) -> void:
	var start: int = out.v.size()
	var lin := Color("3a3638").srgb_to_linear()
	lin.a = 7.0 / 8.0
	var seed := float(absi(hash(bid)) % 997) / 997.0
	for p in [Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1)]:
		out.v.append(p)
		out.n.append(Vector3.UP)
		out.c.append(lin)
		out.uv.append(Vector2(p.x, p.z))
		out.uv2.append(Vector2(y, seed))
	out.i.append_array([start, start + 1, start + 2, start, start + 2, start + 3])


# =========================================================================
# Collision: walls along the real outlines (skyline raster, 25 cm)
# =========================================================================

func _build_collision() -> void:
	var sw := int((D.W + 2 * D.MARGIN) * D.SKY)
	var sh := int((D.H + 2 * D.MARGIN) * D.SKY)
	var faces := PackedVector3Array()
	var s := 1.0 / D.SKY
	var top := 8.0
	# only the play area (plus a little) needs walls
	var c0 := int((D.MARGIN - 1.0) * D.SKY)
	var c1 := int((D.MARGIN + D.W + 1.0) * D.SKY)
	var r0 := int((D.MARGIN - 1.0) * D.SKY)
	var r1 := int((D.MARGIN + D.H + 1.0) * D.SKY)
	for r in range(r0, r1):
		for dir in [-1, 1]:
			var start := -1
			for c in range(c0, c1 + 1):
				var edge := c < c1 and sky[r * sw + c] != 0 and sky[(r + dir) * sw + c] == 0
				if edge and start < 0:
					start = c
				elif not edge and start >= 0:
					var z := -D.MARGIN + (r + (1.0 if dir > 0 else 0.0)) * s
					_quad_faces(faces, Vector3(-D.MARGIN + start * s, 0, z), Vector3(-D.MARGIN + c * s, 0, z), top)
					start = -1
	for c in range(c0, c1):
		for dir in [-1, 1]:
			var start := -1
			for r in range(r0, r1 + 1):
				var edge := r < r1 and sky[r * sw + c] != 0 and sky[r * sw + c + dir] == 0
				if edge and start < 0:
					start = r
				elif not edge and start >= 0:
					var x := -D.MARGIN + (c + (1.0 if dir > 0 else 0.0)) * s
					_quad_faces(faces, Vector3(x, 0, -D.MARGIN + start * s), Vector3(x, 0, -D.MARGIN + r * s), top)
					start = -1
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	arena._world_body.add_child(cs)


static func _quad_faces(faces: PackedVector3Array, a: Vector3, b: Vector3, top: float) -> void:
	var a1 := a + Vector3.UP * top
	var b1 := b + Vector3.UP * top
	faces.append_array([a, b, b1, a, b1, a1])


func _build_ground() -> void:
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color("26262a")
	gm.roughness = 1.0
	ground.material_override = gm
	ground.position = Vector3(D.W / 2.0, -0.02, D.H / 2.0)
	arena.add_child(ground)


# =========================================================================
# Facade lookups
# =========================================================================

## The building at a street-level point (index), or -1.
func building_at(x: float, z: float) -> int:
	var c := int(x * D.FINE)
	var r := int(z * D.FINE)
	if c < 0 or r < 0 or c >= D.W * D.FINE or r >= D.H * D.FINE:
		return -2
	var v := street[r * D.W * D.FINE + c]
	return v - 64 if v >= 64 else -1


## From `from`, walk along `dir` (flat) to the first building wall; returns
## the point on the facade (y = 0), or `from` if there's none within 3 m.
func facade_point(from: Vector3, dir: Vector3) -> Vector3:
	var d := Vector3(dir.x, 0, dir.z).normalized()
	for k in 48:
		var p := from + d * (k / 16.0)
		if building_at(p.x, p.z) >= 0:
			return p - d * (1.0 / 32.0)
	return from


## The same against the facades above the shops (the skyline outline,
## which is coarser than the street's).
func sky_point(from: Vector3, dir: Vector3) -> Vector3:
	var d := Vector3(dir.x, 0, dir.z).normalized()
	var sw := int((D.W + 2 * D.MARGIN) * D.SKY)
	for k in 64:
		var p := from + d * (k / 16.0)
		var c := int((p.x + D.MARGIN) * D.SKY)
		var r := int((p.z + D.MARGIN) * D.SKY)
		if sky[r * sw + c] != 0:
			return p - d * (1.0 / 32.0)
	return from


# =========================================================================
# Props
# =========================================================================

var _taken := {}     # cells the map's machines, doors and spawns need clear


func _build_props() -> void:
	for y in arena.H:
		for x in arena.W:
			var ch: String = arena._ch(x, y)
			if ch == "S":
				arena.player_spawns.append(Vector3(x + 0.5, 0, y + 0.5))
			if ch == "S" or map.DOORS.has(ch):
				_taken[Vector2i(x, y)] = true
	for pl in map.PLACEMENTS:
		var c: Vector2i = pl.cell
		var f := Vector2i(roundi(pl.face.x), roundi(pl.face.z))
		for d in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
			_taken[c + d] = true
			_taken[c + d + f] = true
	_rubble()
	_screens()
	_lamps()
	_subways()
	_cabs()
	_red_steps()
	arena.ambience.add("amb_hum", Vector3(17.0, 6.0, 40.0), -22.0, 30.0, 0.5)   # the square's electric drone


## Collapsed concrete, rebar and sandbags close every street at the map
## edge: one pile per edge cell, drawn as a few multimeshes.
func _rubble() -> void:
	var cells: Array[Vector2i] = []
	for x in arena.W:
		for y in [0, arena.H - 1]:
			if arena._ch(x, y) == "X":
				cells.append(Vector2i(x, y))
	for y in range(1, arena.H - 1):
		for x in [0, arena.W - 1]:
			if arena._ch(x, y) == "X":
				cells.append(Vector2i(x, y))
	var by_kind: Array = [[], [], [], []]
	for c in cells:
		var p := Vector3(c.x + 0.5, 0, c.y + 0.5)
		var h := absi(hash(c))
		var t := Transform3D(Basis(Vector3.UP, float(h % 628) / 100.0).scaled(Vector3.ONE * (0.85 + float(h % 31) / 100.0)), p)
		by_kind[h % 4].append(t)
		arena._add_box(p + Vector3(0, 1.5, 0), Vector3(1.0, 3.0, 1.0))
	for k in 4:
		if by_kind[k].is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = rubble_mesh(k)
		mm.instance_count = by_kind[k].size()
		for i in by_kind[k].size():
			mm.set_instance_transform(i, by_kind[k][i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.name = "Rubble%d" % k
		arena.add_child(mmi)


## The square's screens: on the buildings either side of the bowtie.
func _screens() -> void:
	var spots := [
		[Vector3(12.0, 0, 6.0), Vector3.LEFT, 4.2, 2.6, 6.0], [Vector3(20.5, 0, 8.0), Vector3.RIGHT, 3.6, 3.0, 8.5],
		[Vector3(13.0, 0, 24.0), Vector3.LEFT, 3.2, 2.2, 5.5], [Vector3(19.5, 0, 26.0), Vector3.RIGHT, 3.8, 2.8, 7.0],
		[Vector3(15.0, 0, 40.0), Vector3.LEFT, 3.0, 2.4, 6.0], [Vector3(21.5, 0, 43.0), Vector3.RIGHT, 4.4, 3.2, 9.0],
		[Vector3(16.0, 0, 57.0), Vector3.LEFT, 3.4, 2.4, 6.5], [Vector3(24.0, 0, 60.0), Vector3.RIGHT, 3.6, 2.6, 7.5],
		[Vector3(21.5, 0, 72.0), Vector3.FORWARD, 2.0, 3.6, 8.0], [Vector3(16.0, 0, 74.0), Vector3.LEFT, 3.2, 2.4, 6.0],
	]
	var tints := [Color("ff6a2a"), Color("2ad0ff"), Color("ff2a7a"), Color("ffd23a"), Color("6aff4a"), Color("b05aff")]
	var k := 0
	for s in spots:
		var wall := sky_point(s[0], s[1])
		if wall == s[0]:
			continue
		var q := QuadMesh.new()
		q.size = Vector2(s[2], s[3])
		var mi := MeshInstance3D.new()
		mi.mesh = q
		mi.material_override = _screen_mat()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var n: Vector3 = -s[1]
		mi.position = wall + n * 0.06 + Vector3.UP * float(s[4])
		mi.rotation.y = atan2(n.x, n.z)
		mi.set_instance_shader_parameter("seed", float(k) * 1.37)
		mi.set_instance_shader_parameter("tint", tints[k % tints.size()])
		arena.add_child(mi)
		# a few screens light the street below them (lights are what this map
		# costs the GPU most, so fewer on lower settings)
		if k % 3 == 0 and Settings.quality() >= 2:
			_spot(mi.position + n * 0.8 + Vector3.DOWN * 0.8, tints[k % tints.size()], 9.0, 2.2, 50.0, (n + Vector3.DOWN * 0.9).normalized())
		k += 1


static var _screen_material: ShaderMaterial


static func _screen_mat() -> ShaderMaterial:
	if _screen_material == null:
		_screen_material = ShaderMaterial.new()
		_screen_material.shader = SCREEN
	return _screen_material


## Street lamps along 7th Avenue and the plazas.
func _lamps() -> void:
	var lamp := lamp_mesh()
	var lamps := 0
	for z in [4.0, 15.0, 27.0, 39.0, 46.0, 58.0, 70.0, 79.0]:
		for side in [-1, 1]:
			var probe := Vector3(17.7, 0, z)
			var wall := facade_point(probe, Vector3(side, 0, 0))
			if wall == probe:
				continue
			var p := wall - Vector3(side, 0, 0) * 0.45
			if building_at(p.x, p.z) != -1 or not arena.is_walkable(arena.cell_of(p)) or _taken.has(arena.cell_of(p)):
				continue
			var mi: MeshInstance3D = arena._place_mesh(lamp, p, 0.0 if side > 0 else PI)
			mi.name = "Lamp"
			arena._add_box(p + Vector3(0, 1.8, 0), Vector3(0.18, 3.6, 0.18))
			lamps += 1
			if Settings.quality() >= 1 or lamps % 2 == 1:
				_spot(p + Vector3(-side * 0.6, 3.55, 0), Color("ffc27a"), 6.5, 2.4, 58.0, Vector3.DOWN)


## Real subway entrances: railings, two green globes, stairs into the dark.
func _subways() -> void:
	for s in D.SUBWAY:
		var p := Vector3(s.x, 0, s.y)
		var c: Vector2i = arena.cell_of(p)
		if not arena.is_walkable(c) or _taken.has(c):
			continue
		_taken[c] = true
		p = arena.cell_center(c)
		var yaw := 0.0 if absf(p.x - 17.7) > 3.0 else PI * 0.5
		arena._place_mesh(subway_mesh(), p, yaw)
		arena._add_box(p + Vector3(0, 0.5, 0), Vector3(1.0, 1.0, 1.0).rotated(Vector3.UP, yaw).abs())
		arena.walk[c.y * arena.W + c.x] = 0
		arena._add_light(p + Vector3(0, 1.4, 0), Color("6aff9a"), 3.0, 0.7, false)


## A few cabs left where they stalled on 7th Avenue.
func _cabs() -> void:
	for spot in [Vector3(18.6, 0, 24.5), Vector3(16.9, 0, 61.0), Vector3(18.4, 0, 9.0)]:
		var c: Vector2i = arena.cell_of(spot)
		var yaw := PI * (0.02 if c.y % 2 else -0.04)
		arena._place_mesh(cab_mesh(), spot, yaw)
		arena._add_box(spot + Vector3(0, 0.55, 0), Vector3(0.95, 1.1, 2.3))
		for k in [-1, 0, 1]:
			var cc: Vector2i = arena.cell_of(spot + Vector3(0, 0, k))
			arena.walk[cc.y * arena.W + cc.x] = 0


## Duffy Square's red steps, rising to the north, the ticket booth under
## the top end. The lowest steps can be stood on; the rest is solid.
func _red_steps() -> void:
	var r: Rect2 = D.TKTS
	var p := Vector3(r.get_center().x, 0, r.get_center().y)
	arena._place_mesh(steps_mesh(), p, 0.0)
	var low := 1.0                                     # the first steps, from the south end
	arena._add_box(Vector3(p.x, 0.375, r.end.y - low / 2.0), Vector3(r.size.x, 0.75, low))
	arena._add_box(Vector3(p.x, 1.3, r.position.y + (r.size.y - low) / 2.0), Vector3(r.size.x, 2.6, r.size.y - low))
	_spot(Vector3(p.x, 3.4, r.end.y + 1.2), Color("ff3a30"), 6.0, 2.0, 55.0, Vector3(0, -0.7, -0.7).normalized())


## A steady electric light shining along `dir` (street lamps, screens). Spot
## lights only touch what's in their cone, which keeps a street full of them
## affordable; they don't flicker like the outpost's fires.
func _spot(pos: Vector3, color: Color, range_m: float, energy: float, angle: float, dir: Vector3) -> void:
	var l := SpotLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.spot_range = range_m
	l.spot_angle = angle
	l.spot_attenuation = 1.2
	l.light_specular = 0.0
	l.light_volumetric_fog_energy = 1.2
	l.distance_fade_enabled = true
	l.distance_fade_begin = 26.0
	l.distance_fade_length = 6.0
	arena.add_child(l)
	l.position = pos
	if absf(dir.normalized().dot(Vector3.UP)) > 0.99:
		l.rotation = Vector3(-PI * 0.5 * signf(-dir.y), 0, 0)
	else:
		l.look_at(pos + dir, Vector3.UP)


# =========================================================================
# Models
# =========================================================================

func barricade_mesh(width_m: float) -> Mesh:
	return _cached("barricade_%s" % width_m, func():
		var b := VB.new(2)
		var w := int(width_m * 8)
		var rust := Color("6a4a32")
		var sheet := Color("5a5a58")
		for x in range(0, w, 6):                          # corrugated sheets, leaning
			var c := sheet if (x / 6) % 3 else rust
			b.box(Vector3i(x, 0, 0), Vector3i(mini(x + 5, w - 1), 18 + (x * 7) % 5, 0), c, 0.12)
			for fx in range(x * 2, mini(x + 6, w) * 2, 2):
				b.fpaint(Vector3i(fx, 0, 0), Vector3i(fx, 40, 1), c.darkened(0.25), 0.05)
		b.box(Vector3i(0, 6, -1), Vector3i(w - 1, 7, -1), Color("4a3422"), 0.1)       # a timber brace
		b.box(Vector3i(0, 14, -1), Vector3i(w - 1, 15, -1), Color("4a3422"), 0.1)
		for x in range(0, w, 3):                         # sandbags along the foot
			b.rbox(Vector3i(x, 0, -3), Vector3i(mini(x + 2, w - 1), 2, -2), Color("8a7a58"), 0.1)
		for i in 6:                                      # ember-lit cracks
			b.put(Vector3i((i * 17 + 5) % w, 4 + (i * 5) % 10, -1), Color("ff7a1a"), 0.0, true)
		return b.build(0.125, Vector3(float(w) / 2.0, 0, 0.5)))


func manhole_mesh() -> Mesh:
	return _cached("manhole", func():
		var b := VB.new(2)
		for x in range(-6, 7):
			for z in range(-6, 7):
				var d := Vector2(x, z).length()
				if d <= 6.4 and d > 4.6:
					b.put(Vector3i(x, 0, z), Color("2e2a26"), 0.06)            # the ring
				elif d <= 4.6:
					b.put(Vector3i(x, -1, z), Color("ff6a1a") if (x + z) % 3 else Color("ffb040"), 0.1, true)  # embers below
		for x in range(-4, 9):                                              # the cover, shoved aside
			for z in range(-4, 5):
				if Vector2(x - 2, z).length() <= 4.5:
					b.put(Vector3i(x + 3, 1, z), Color("3a3632") if (x + z) % 2 else Color("2c2925"), 0.05)
		return b.build(0.0625, Vector3(0.5, 0, 0.5), 3.0))


func lamp_mesh() -> Mesh:
	return _cached("lamp", func():
		var b := VB.new(2)
		var iron := Color("2e3234")
		b.box(Vector3i(-1, 0, -1), Vector3i(1, 2, 1), iron, 0.05)
		b.box(Vector3i(0, 0, 0), Vector3i(0, 58, 0), iron, 0.04)
		for x in range(0, 9):                                   # the arm, over the street
			b.put(Vector3i(-x, 58 + mini(x, 3) / 2, 0), iron, 0.04)
		b.box(Vector3i(-11, 57, -1), Vector3i(-8, 58, 1), Color("3a3e40"), 0.04)
		b.box(Vector3i(-10, 56, -1), Vector3i(-9, 56, 0), Color("ffd08a"), 0.0, true)
		return b.build(0.0625, Vector3(0.5, 0, 0.5), 3.5))


func subway_mesh() -> Mesh:
	return _cached("subway", func():
		var b := VB.new(2)
		var green := Color("2e5a3a")
		for x in [-8, 7]:
			b.box(Vector3i(x, 0, -7), Vector3i(x, 13, 7), green, 0.06)          # railings
			b.box(Vector3i(x, 13, -7), Vector3i(x, 13, 7), Color("3a6a46"), 0.04)
		b.box(Vector3i(-8, 0, 7), Vector3i(7, 13, 7), green, 0.06)
		for y in range(0, 6):                                                  # stairs going down
			b.box(Vector3i(-7, -y, -6 + y * 2), Vector3i(6, -y, -5 + y * 2), Color("4a4644"), 0.06)
		for x in [-8, 7]:                                                     # the green globes
			b.box(Vector3i(x, 14, 6), Vector3i(x, 17, 6), green, 0.0)
			b.sphere(Vector3(x, 19, 6), 1.6, Color("7aff9a"), 0.0, true)
		return b.build(0.0625, Vector3(0.5, 0, 0.5), 3.0))


func cab_mesh() -> Mesh:
	return _cached("cab", func():
		var b := VB.new(2)
		var yellow := Color("d8a628")
		b.rbox(Vector3i(-7, 3, -18), Vector3i(7, 9, 18), yellow, 0.08)        # body
		b.rbox(Vector3i(-6, 10, -8), Vector3i(6, 15, 9), yellow, 0.08)        # cabin
		b.box(Vector3i(-6, 11, -9), Vector3i(6, 14, -9), Color("1a2228"), 0.02)  # windscreen, cracked
		b.box(Vector3i(-7, 11, -7), Vector3i(-7, 14, 8), Color("1a2228"), 0.02)
		b.box(Vector3i(7, 11, -7), Vector3i(7, 14, 8), Color("1a2228"), 0.02)
		b.box(Vector3i(-2, 16, -1), Vector3i(2, 17, 1), Color("f0e8c8"), 0.0)   # roof sign
		b.paint(Vector3i(-7, 5, -18), Vector3i(7, 6, 18), Color("1c1c1e"), 0.04)  # checker stripe
		for z in [-12, 12]:                                                    # wheels
			for x in [-8, 7]:
				b.box(Vector3i(x, 0, z - 3), Vector3i(x, 4, z + 3), Color("141414"), 0.02)
		b.paint(Vector3i(-7, 9, -18), Vector3i(7, 9, -4), Color("5a3a22"), 0.15)  # scorched hood
		b.put(Vector3i(-3, 10, -14), Color("ff7a1a"), 0.0, true)
		b.put(Vector3i(2, 10, -16), Color("ffb040"), 0.0, true)
		return b.build(0.0625, Vector3(0.5, 0, 0.5), 3.0))


func steps_mesh() -> Mesh:
	return _cached("red_steps", func():
		# coarse voxels of 12.5 cm: 24 across, 28 deep, rising to the north (-z)
		var b := VB.new(2)
		var red := Color("8e1c1a")
		var lit := Color("ff4a3a")
		var steel := Color("2a2a2e")
		for k in 10:
			var z1 := 27 - 3 * k
			var z0 := maxi(z1 - 2, 0)
			var top := 2 * k + 1
			b.box(Vector3i(1, 0, z0), Vector3i(22, top, z1), red, 0.05)                # the step
			b.box(Vector3i(1, top, z1), Vector3i(22, top, z1), lit, 0.0, true)       # its lit nose
		for x in [0, 23]:                                                           # glass rails up the sides
			for z in 28:
				var h := 2 * ((27 - z) / 3) + 4
				b.box(Vector3i(x, 0, z), Vector3i(x, mini(h, 22), z), steel, 0.02)
		# the booth under the top end: dark glass, two lit ticket windows
		b.paint(Vector3i(1, 0, 0), Vector3i(22, 19, 0), Color("1a1c22"), 0.02)
		for x in [4, 14]:
			b.paint(Vector3i(x, 3, 0), Vector3i(x + 5, 8, 0), Color("ffc27a"), 0.0, true)
		return b.build(0.125, Vector3(12, 0, 14), 2.2))


func rubble_mesh(seed_v: int) -> Mesh:
	return _cached("rubble_%d" % seed_v, func():
		# coarse voxels of 12.5 cm: a heap about 2 m across and 1.5-2 m high
		var b := VB.new(2)
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_v * 131 + 7
		var concrete := Color("6a6662")
		for layer in 5:                                                        # the heap, narrowing upwards
			var r := 8 - layer
			for i in 3 + layer:
				var c := Vector3i(rng.randi_range(-r, r - 3), layer * 3, rng.randi_range(-r, r - 3))
				var sz := Vector3i(rng.randi_range(2, 5), rng.randi_range(2, 4), rng.randi_range(2, 5))
				b.box(c, c + sz, concrete.darkened(rng.randf() * 0.35), 0.15)
		for i in 3:                                                            # slabs leaning on it
			var x := rng.randi_range(-6, 4)
			var z := rng.randi_range(-6, 4)
			for k in 6:
				b.box(Vector3i(x + k, k * 2, z), Vector3i(x + k, k * 2 + 2, z + 4), Color("7a7470").darkened(rng.randf() * 0.2), 0.1)
		for i in 5:                                                            # bent rebar
			var x := rng.randi_range(-5, 5)
			var z := rng.randi_range(-5, 5)
			var top := 10 + rng.randi_range(0, 8)
			b.box(Vector3i(x, 4, z), Vector3i(x, top, z), Color("5a3a28"), 0.0)
			b.put(Vector3i(x + 1, top, z), Color("5a3a28"), 0.0)
		if seed_v % 2 == 0:                                                    # sandbags along the foot
			for x in range(-8, 8, 3):
				b.rbox(Vector3i(x, 0, 8), Vector3i(x + 2, 1, 9), Color("8a7a58"), 0.1)
		if seed_v == 3:                                                        # embers still glowing inside
			b.put(Vector3i(1, 3, 2), Color("ff7a1a"), 0.0, true)
			b.put(Vector3i(-2, 5, -1), Color("ffb040"), 0.0, true)
		b.box(Vector3i(-9, 0, -9), Vector3i(9, 0, 9), Color("3a3634"), 0.1)     # spilled grit
		return b.build(0.125, Vector3(0.5, 0, 0.5)))


## Models are built on worker threads (model_jobs() in times_square.gd)
## and then reused; the lock keeps the shared table consistent.
func _cached(key: String, maker: Callable) -> Mesh:
	_lock.lock()
	var mesh: Mesh = _cache.get(key)
	_lock.unlock()
	if mesh == null:
		mesh = maker.call()
		_lock.lock()
		_cache[key] = mesh
		_lock.unlock()
	return mesh


# =========================================================================
# The street level (8 voxels per metre)
# =========================================================================

class CityTerrain extends "res://scripts/world/terrain.gd":
	const STORE_LAYERS := 36
	const CITY_PAL := [
		["2c2c31", 0.06], ["34343a", 0.07], ["25252a", 0.05],                 # 0-2 asphalt
		["d8d6cc", 0.03], ["cfcdc4", 0.03], ["8a8986", 0.06],                 # 3 crossing, 4 lane, 5 curb
		["8b857e", 0.08], ["6d6862", 0.05],                                   # 6 sidewalk, 7 joint
		["5e5956", 0.08], ["6a6460", 0.08], ["4e4a49", 0.08],                 # 8-10 pavers
		["3a3632", 0.05], ["27241f", 0.04],                                   # 11 manhole, 12 rim
		["7a4636", 0.08], ["5e2c22", 0.06], ["4a3a34", 0.06], ["8e7e72", 0.06],   # 13-16 brick: wall, trim, base, cornice
		["a3957f", 0.06], ["8e826e", 0.06], ["5a5450", 0.06], ["b8ab96", 0.05],   # 17-20 limestone
		["4c484c", 0.06], ["3a3638", 0.05], ["2e2c2e", 0.05], ["5e5a5c", 0.05],   # 21-24 dark stone
		["3f4a56", 0.04], ["2a3038", 0.04], ["22262c", 0.04], ["56606a", 0.04],   # 25-28 glass tower base
		["c2a882", 0.06], ["8a6a4a", 0.05], ["4a3a30", 0.05], ["d8c49a", 0.05],   # 29-32 theatre
		["14181e", 0.02], ["2a2420", 0.04], ["5e4a32", 0.12],                 # 33 dark glass, 34 door, 35 plywood
		["1c1a1e", 0.03], ["3e3a3a", 0.04],                                   # 36 sign panel, 37 dead sign letter
		["6e5434", 0.06], ["3e5468", 0.06],                                   # 38-39 lit shop windows (glow, dim)
		["c42a2a", 0.0], ["c8a02a", 0.0], ["2a62c8", 0.0], ["c02aa0", 0.0], ["2ac06a", 0.0], ["c8661a", 0.0],  # 40-45 sign letters
	]
	const GLOW := 38
	const SIGN_WORDS := ["TIX", "SHOW", "LIVE", "OPEN", "DELI", "CAFE", "NEWS", "TOYS", "GIFT", "BAR", "SALE",
		"FOOD", "HATS", "SODA", "MART", "JAZZ", "ROCK", "FILM", "PAWN", "BANK", "INN", "SHOP", "PIES", "CLUB"]
	## 3x5 letters, one row per entry, high bit on the left
	const FONT := {
		"A": [2, 5, 7, 5, 5], "B": [6, 5, 6, 5, 6], "C": [3, 4, 4, 4, 3], "D": [6, 5, 5, 5, 6], "E": [7, 4, 6, 4, 7],
		"F": [7, 4, 6, 4, 4], "G": [3, 4, 5, 5, 3], "H": [5, 5, 7, 5, 5], "I": [7, 2, 2, 2, 7], "J": [1, 1, 1, 5, 2],
		"K": [5, 5, 6, 5, 5], "L": [4, 4, 4, 4, 7], "M": [5, 7, 7, 5, 5], "N": [6, 5, 5, 5, 5], "O": [2, 5, 5, 5, 2],
		"P": [6, 5, 6, 4, 4], "R": [6, 5, 6, 5, 5], "S": [3, 4, 2, 1, 6], "T": [7, 2, 2, 2, 2], "U": [5, 5, 5, 5, 7],
		"V": [5, 5, 5, 5, 2], "W": [5, 5, 7, 7, 5], "X": [5, 5, 2, 5, 5], "Y": [5, 5, 2, 2, 2], "Z": [7, 1, 2, 4, 7],
	}
	const BAY := 24                      # one shop front: 3 m

	var codes := PackedInt32Array()
	var outer := PackedByteArray()
	var bstyle := PackedInt32Array()     # per building: base palette entry of its material
	## per storefront column (and the one behind it): the coordinate along the
	## wall, running left to right as seen from the street, so signs read
	var read := PackedInt32Array()


	func setup_city(raster: PackedInt32Array, fw: int, fh: int, building_styles: PackedInt32Array) -> void:
		vpc = 8
		vs = 1.0 / 8.0
		GX = fw
		GZ = fh
		W = fw / vpc
		H = fh / vpc
		codes = raster
		palette.clear()
		for p in CITY_PAL:
			var c := Color(p[0])
			palette.append(Color(c.r, c.g, c.b, p[1]))
		glow_from = GLOW
		for st in building_styles:
			bstyle.append(29 if st < 0 else [13, 13, 17, 17, 21, 21, 25, 25][st])
		cols.resize(GX * GZ)
		deco.resize(GX * GZ)
		deco.fill(DECO_NONE)
		rim_along.resize(GX * GZ)
		rim_along.fill(0)
		outer.resize(GX * GZ)
		outer.fill(0)
		read.resize(GX * GZ)
		read.fill(0)
		var ground := bits(Y0, 0)
		var wall := bits(Y0, STORE_LAYERS)
		for i in GX * GZ:
			var v := codes[i]
			cols[i] = wall if v >= 64 else (ground | bits(0, 1) if v == 5 else ground)
		# storefronts: recessed windows and doors on every building's outer layer,
		# a cornice ledge over the pavement in front
		for gz in GZ:
			for gx in GX:
				var i := gz * GX + gx
				if codes[i] < 64:
					continue
				var open_dir := Vector2i.ZERO
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = gx + d.x
					var nz: int = gz + d.y
					if nx >= 0 and nz >= 0 and nx < GX and nz < GZ and codes[nz * GX + nx] < 64:
						open_dir = d
						break
				if open_dir == Vector2i.ZERO:
					continue
				outer[i] = 1
				# walls facing +x or -z are read with the coordinate running backwards
				var rd := gx + gz
				if open_dir == Vector2i(1, 0) or open_dir == Vector2i(0, -1):
					rd = BAY * 100000 - rd
				read[i] = rd
				var behind := (gz - open_dir.y) * GX + gx - open_dir.x
				if gx - open_dir.x >= 0 and gx - open_dir.x < GX and gz - open_dir.y >= 0 and gz - open_dir.y < GZ:
					read[behind] = rd
				var bay := rd % BAY
				var door := (rd / BAY) % 3 == 1
				var m := cols[i]
				if door and bay >= 8 and bay <= 15:
					m &= ~bits(0, 20)                           # a doorway
				elif bay >= 3 and bay <= 21:
					m &= ~bits(3, 20)                           # a shop window
				cols[i] = m
				var ri := (gz + open_dir.y) * GX + gx + open_dir.x
				if codes[ri] < 64 and codes[ri] != 5:
					cols[ri] |= bits(33, STORE_LAYERS)
					deco[ri] = DECO_RIM
					rim_along[ri] = codes[i] - 64
		_padded.resize((GX + 2) * (GZ + 2))
		_padded.fill(FULL)
		for gz in GZ:
			for gx in GX:
				_padded[(gz + 1) * (GX + 2) + gx + 1] = cols[gz * GX + gx]


	func _capped_bits(_gx: int, _gz: int) -> int:
		return 0


	func _caps(_surf: Array, _x0: int, _z0: int, _x1: int, _z1: int) -> void:
		pass


	func _color(gx: int, gy: int, gz: int, n: int) -> int:
		var i := gz * GX + gx
		var v := codes[i]
		if v >= 64:
			var base := bstyle[v - 64]
			if n == 2:
				return base + 3                                  # the ledge on top
			var rd := read[i]
			var bay := rd % BAY
			var shop := rd / BAY
			if outer[i] == 0:
				# seen through a recess: a door, or the shop window
				if shop % 3 == 1 and bay >= 8 and bay <= 15 and gy < 20:
					return 34
				match h3(shop, v, 3) % 8:
					0, 1: return 35                              # boarded up
					2, 3: return 38                              # lights still on
					4: return 39
					_: return 33
			if gy >= STORE_LAYERS - 3:
				return base + 3                                  # cornice
			if gy < 3:
				return base + 2                                  # stone base
			if bay < 3:
				return base + 1                                  # pilaster
			if gy >= 21 and gy < 28 and n != 3:
				return _sign(shop, bay, gy, v, base)
			return base
		if gy >= 0:
			if deco[i] == DECO_RIM:
				return bstyle[rim_along[i]] + 3                  # the cornice ledge
			return 5                                             # curb
		match v:
			2:
				var hm := h3(gx / 12, gz / 12, 5)
				if hm % 17 == 0 and Vector2(gx % 12 - 6, gz % 12 - 6).length() < 3.2:
					return 11 if Vector2(gx % 12 - 6, gz % 12 - 6).length() < 2.5 else 12   # a manhole
				return 2 if h3(gx / 5, gz / 5, 9) % 7 == 0 else (1 if h3(gx / 9, gz / 9, 2) % 4 == 0 else 0)
			3, 4:
				return v
			5:
				return 5
			1:
				if gx % 3 == 0 or gz % 3 == 0:
					return 7
				return 6
			_:
				var row := gz / 2
				var off := 2 if row % 2 else 0
				if (gx + off) % 4 == 0:
					return 10
				return 8 + h3((gx + off) / 4, row, 7) % 2


	## The sign over a shop: a dark panel with a word in blocky letters, lit in
	## the shop's colour (some have gone dark).
	func _sign(shop: int, bay: int, gy: int, v: int, base: int) -> int:
		var hs := h3(shop, v, 11)
		if hs % 6 == 0:
			return base + 1                                      # no sign here
		if bay == 3 or bay > 20 or gy == 21 or gy == 27:
			return 36
		var word: String = SIGN_WORDS[(hs >> 3) % SIGN_WORDS.size()]
		var start := 4 + (4 - word.length()) * 2
		var k := bay - start
		if k < 0 or k >= word.length() * 4 or k % 4 == 3:
			return 36
		var glyph: Array = FONT.get(word[k / 4], [])
		if glyph.is_empty() or (int(glyph[26 - gy]) >> (2 - k % 4)) & 1 == 0:
			return 36
		return 37 if hs % 7 == 1 else 40 + (hs >> 8) % 6
