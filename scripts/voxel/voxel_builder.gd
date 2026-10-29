extends RefCounted
## Voxel model builder: paint voxels into a grid, then mesh only exposed
## faces with per-corner ambient occlusion baked into vertex colours.
## Voxels marked as glowing go to a second, emissive surface.
##
## `res` subdivides the authoring grid: with res 2, box(), put() and friends
## still take the old (coarse) coordinates but fill 2×2×2 fine voxels, and
## build() halves the voxel size, so a model keeps its size and proportions
## while the f*() calls (fput, fbox…) add detail on the fine grid.

const SHADER := preload("res://shaders/voxel.gdshader")
const SHADER_STATIC := preload("res://shaders/voxel_static.gdshader")

## [normal, u, v] with u × v = normal, so quads wind consistently.
const FACES := [
	[Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1)],
	[Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 1, 0)],
	[Vector3i(0, 1, 0), Vector3i(0, 0, 1), Vector3i(1, 0, 0)],
	[Vector3i(0, -1, 0), Vector3i(1, 0, 0), Vector3i(0, 0, 1)],
	[Vector3i(0, 0, 1), Vector3i(1, 0, 0), Vector3i(0, 1, 0)],
	[Vector3i(0, 0, -1), Vector3i(0, 1, 0), Vector3i(1, 0, 0)],
]
const AO_CURVE := [0.42, 0.62, 0.8, 1.0]

static var _materials := {}
static var _mat_lock := Mutex.new()

var vox := {}      # Vector3i (fine grid) -> Color (alpha = colour noise amount)
var glow := {}     # Vector3i -> true
var skip_bottom := false
## Characters need hit-flash/dissolve; everything else uses the cheaper static shader.
var dynamic := false
## Fine voxels per authoring voxel along each axis.
var res := 1


func _init(resolution := 1) -> void:
	res = resolution


## Deterministic per-voxel colour variation so surfaces read as hand-painted.
static func vary(c: Color, p: Vector3i, amount: float) -> Color:
	if amount <= 0.0:
		return c
	var h := float(absi(hash(p)) % 1000) / 1000.0 - 0.5
	return Color(clampf(c.r + h * amount, 0, 1), clampf(c.g + h * amount * 0.95, 0, 1), clampf(c.b + h * amount * 0.9, 0, 1))


# --- authoring on the coarse grid ------------------------------------------

func put(p: Vector3i, c: Color, noise := 0.0, glowing := false) -> void:
	if res == 1:
		fput(p, c, noise, glowing)
	else:
		fbox(p * res, p * res + Vector3i.ONE * (res - 1), c, noise, glowing)


func box(a: Vector3i, b: Vector3i, c: Color, noise := 0.05, glowing := false) -> void:
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	fbox(lo * res, hi * res + Vector3i.ONE * (res - 1), c, noise, glowing)


## A box with its edges and corners shaved off one fine voxel, for a softer,
## hand-carved look. Thin boxes (under two coarse voxels across) stay square.
func rbox(a: Vector3i, b: Vector3i, c: Color, noise := 0.05, glowing := false) -> void:
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z)) * res
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z)) * res + Vector3i.ONE * (res - 1)
	var size := hi - lo + Vector3i.ONE
	var round_x := size.x >= 4
	var round_y := size.y >= 4
	var round_z := size.z >= 4
	var col := Color(c.r, c.g, c.b, clampf(noise, 0.0, 0.5))
	for x in range(lo.x, hi.x + 1):
		var ex := round_x and (x == lo.x or x == hi.x)
		for y in range(lo.y, hi.y + 1):
			var ey := round_y and (y == lo.y or y == hi.y)
			for z in range(lo.z, hi.z + 1):
				var ez := round_z and (z == lo.z or z == hi.z)
				if int(ex) + int(ey) + int(ez) >= 2:
					continue
				var p := Vector3i(x, y, z)
				vox[p] = col
				if glowing:
					glow[p] = true
				else:
					glow.erase(p)


## Paint only voxels that already exist inside the box (decals, stripes).
func paint(a: Vector3i, b: Vector3i, c: Color, noise := 0.05, glowing := false) -> void:
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	fpaint(lo * res, hi * res + Vector3i.ONE * (res - 1), c, noise, glowing)


func carve(a: Vector3i, b: Vector3i) -> void:
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	fcarve(lo * res, hi * res + Vector3i.ONE * (res - 1))


## Mirror every voxel across the plane x = mirror_at (inclusive centre axis).
func mirror_x(mirror_at: int) -> void:
	# coarse column mirror_at spans fine x in [m*res, m*res + res - 1]
	var axis2 := 2 * mirror_at * res + res - 1
	for p in vox.keys():
		var q := Vector3i(axis2 - p.x, p.y, p.z)
		if not vox.has(q):
			vox[q] = vox[p]
			if glow.has(p):
				glow[q] = true


func sphere(c: Vector3, r: float, col: Color, noise := 0.05, glowing := false) -> void:
	fsphere((c + Vector3(0.5, 0.5, 0.5)) * res - Vector3(0.5, 0.5, 0.5), r * res, col, noise, glowing)


# --- authoring on the fine grid --------------------------------------------

func fput(p: Vector3i, c: Color, noise := 0.0, glowing := false) -> void:
	# alpha carries the shader's per-voxel variation amount (see voxel.gdshader)
	vox[p] = Color(c.r, c.g, c.b, clampf(noise, 0.0, 0.5))
	if glowing:
		glow[p] = true
	else:
		glow.erase(p)


func fbox(a: Vector3i, b: Vector3i, c: Color, noise := 0.05, glowing := false) -> void:
	var col := Color(c.r, c.g, c.b, clampf(noise, 0.0, 0.5))
	for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			for z in range(mini(a.z, b.z), maxi(a.z, b.z) + 1):
				var p := Vector3i(x, y, z)
				vox[p] = col
				if glowing:
					glow[p] = true
				elif not glow.is_empty():
					glow.erase(p)


func fpaint(a: Vector3i, b: Vector3i, c: Color, noise := 0.05, glowing := false) -> void:
	var col := Color(c.r, c.g, c.b, clampf(noise, 0.0, 0.5))
	for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			for z in range(mini(a.z, b.z), maxi(a.z, b.z) + 1):
				var p := Vector3i(x, y, z)
				if vox.has(p):
					vox[p] = col
					if glowing:
						glow[p] = true
					else:
						glow.erase(p)


func fcarve(a: Vector3i, b: Vector3i) -> void:
	for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			for z in range(mini(a.z, b.z), maxi(a.z, b.z) + 1):
				vox.erase(Vector3i(x, y, z))
				glow.erase(Vector3i(x, y, z))


## Sphere centred on fine-grid point `c` (voxel centres sit on integers).
func fsphere(c: Vector3, r: float, col: Color, noise := 0.05, glowing := false) -> void:
	var ri := int(ceil(r)) + 1
	var ci := Vector3i(roundi(c.x), roundi(c.y), roundi(c.z))
	for x in range(ci.x - ri, ci.x + ri + 1):
		for y in range(ci.y - ri, ci.y + ri + 1):
			for z in range(ci.z - ri, ci.z + ri + 1):
				if Vector3(x, y, z).distance_to(c) <= r:
					fput(Vector3i(x, y, z), col, noise, glowing)


## Split off every voxel with fine y below `fine_y` into a new builder (for
## limbs that bend at the elbow or knee). Both halves keep their own faces at
## the cut, so the joint shows solid material when it bends.
func split_below(fine_y: int) -> RefCounted:
	var other = get_script().new(res)
	other.dynamic = dynamic
	other.skip_bottom = skip_bottom
	for p in vox.keys():
		if p.y < fine_y:
			other.vox[p] = vox[p]
			if glow.has(p):
				other.glow[p] = true
			vox.erase(p)
			glow.erase(p)
	return other


func bounds() -> AABB:
	var lo := Vector3i(1 << 20, 1 << 20, 1 << 20)
	var hi := -lo
	for p in vox:
		lo = Vector3i(mini(lo.x, p.x), mini(lo.y, p.y), mini(lo.z, p.z))
		hi = Vector3i(maxi(hi.x, p.x), maxi(hi.y, p.y), maxi(hi.z, p.z))
	var fine := AABB(Vector3(lo), Vector3(hi - lo + Vector3i.ONE))
	return AABB(fine.position / res, fine.size / res)


static func material(glowing: bool, strength := 2.5, scale := 0.0625, pivot := Vector3(0.5, 0, 0.5), dyn := false) -> ShaderMaterial:
	var frac := Vector3(fposmod(pivot.x, 1.0), fposmod(pivot.y, 1.0), fposmod(pivot.z, 1.0))
	var key := "%s_%s_%s_%s_%s" % [glowing, strength, scale, frac, dyn]
	_mat_lock.lock()
	if not _materials.has(key):
		var m := ShaderMaterial.new()
		m.shader = SHADER if dyn else SHADER_STATIC
		m.set_shader_parameter("emission_strength", strength if glowing else 0.0)
		m.set_shader_parameter("roughness_base", 0.6 if glowing else 0.86)
		m.set_shader_parameter("voxel_size", scale)
		m.set_shader_parameter("pivot_frac", frac)
		_materials[key] = m
	var out: ShaderMaterial = _materials[key]
	_mat_lock.unlock()
	return out


## Build the mesh. `scale` is the edge length of one authoring (coarse) voxel
## in metres and `pivot` is the coarse-grid point that becomes the mesh origin.
func build(scale: float, pivot := Vector3.ZERO, glow_strength := 2.5) -> ArrayMesh:
	var arrays := mesh_arrays(scale / res, pivot * res)
	return arrays_to_mesh(arrays, scale / res, pivot * res, glow_strength, dynamic)


## Mesh only `keys` (fine grid), still culling against every voxel, so a
## large model can be split into chunks without seams.
func build_subset(keys: Array, scale: float, pivot := Vector3.ZERO, glow_strength := 2.5) -> ArrayMesh:
	return arrays_to_mesh(mesh_arrays(scale / res, pivot * res, keys), scale / res, pivot * res, glow_strength, dynamic)


## Turn mesh_arrays() output into an ArrayMesh with the voxel materials.
static func arrays_to_mesh(surfs: Array, fine_scale: float, fine_pivot: Vector3, glow_strength: float, dyn: bool) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for k in 2:
		var sa: Dictionary = surfs[k]
		if sa.v.is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = sa.v
		arr[Mesh.ARRAY_NORMAL] = sa.n
		arr[Mesh.ARRAY_COLOR] = sa.c
		arr[Mesh.ARRAY_INDEX] = sa.i
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material(k == 1, glow_strength, fine_scale, fine_pivot, dyn))
	return mesh


## Greedy-mesh every voxel into [plain, glowing] surface arrays. `scale` is
## the fine voxel size and `pivot` a fine-grid point.
##
## Exposed faces are collected per direction as packed 64-bit keys (plane,
## row, column, signature) and sorted natively, so merging is a linear scan:
## first into runs along each row, then runs stack into rectangles across
## rows. Faces only merge when their colour matches and their corner
## occlusion is constant along the merge direction, so creases keep their
## baked shading while long strips of them still become one quad.
func mesh_arrays(scale: float, pivot: Vector3, only: Array = []) -> Array:
	var surf := [_new_arrays(), _new_arrays()]
	if vox.is_empty():
		return surf
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for p in vox:
		lo = Vector3i(mini(lo.x, p.x), mini(lo.y, p.y), mini(lo.z, p.z))
		hi = Vector3i(maxi(hi.x, p.x), maxi(hi.y, p.y), maxi(hi.z, p.z))
	lo -= Vector3i.ONE
	hi += Vector3i.ONE
	var dx := hi.x - lo.x + 1
	var dy := hi.y - lo.y + 1
	var dxy := dx * (hi.y - lo.y + 1)
	var occ := PackedByteArray()
	occ.resize(dxy * (hi.z - lo.z + 1))
	for p in vox:
		occ[(p.x - lo.x) + (p.y - lo.y) * dx + (p.z - lo.z) * dxy] = 1
	# palette: colour (with noise alpha) -> index; glow is part of the signature
	var palette := {}
	var colors: Array[Color] = []
	var stride := [1, dx, dxy]
	var face_keys: Array[PackedInt64Array] = []
	var off_n := PackedInt32Array()
	var off_u := PackedInt32Array()
	var off_v := PackedInt32Array()
	for fi in 6:
		face_keys.append(PackedInt64Array())
		var f: Array = FACES[fi]
		off_n.append(_offset(f[0], dx, dxy))
		off_u.append(_offset(f[1], dx, dxy))
		off_v.append(_offset(f[2], dx, dxy))
	var has_glow := not glow.is_empty()
	for p: Vector3i in (only if not only.is_empty() else vox.keys()):
		var i: int = (p.x - lo.x) + (p.y - lo.y) * dx + (p.z - lo.z) * dxy
		if occ[i + 1] & occ[i - 1] & occ[i + dx] & occ[i - dx] & occ[i + dxy] & occ[i - dxy] == 1:
			continue   # buried: no face can show
		var col_idx := -1
		for fi in 6:
			if skip_bottom and fi == 3:
				continue
			var q: int = i + off_n[fi]
			if occ[q] == 1:
				continue
			if col_idx == -1:
				var c: Color = vox[p]
				var pi = palette.get(c)
				if pi == null:
					pi = colors.size()
					palette[c] = pi
					colors.append(c)
				col_idx = pi
			var uo: int = off_u[fi]
			var vo: int = off_v[fi]
			var a_mu := occ[q - uo]
			var a_pu := occ[q + uo]
			var a_mv := occ[q - vo]
			var a_pv := occ[q + vo]
			var ao0 := 0 if a_mu + a_mv == 2 else 3 - a_mu - a_mv - occ[q - uo - vo]
			var ao1 := 0 if a_pu + a_mv == 2 else 3 - a_pu - a_mv - occ[q + uo - vo]
			var ao2 := 0 if a_pu + a_pv == 2 else 3 - a_pu - a_pv - occ[q + uo + vo]
			var ao3 := 0 if a_mu + a_pv == 2 else 3 - a_mu - a_pv - occ[q - uo + vo]
			var glowing := has_glow and glow.has(p)
			if glowing:
				ao0 = 3; ao1 = 3; ao2 = 3; ao3 = 3
			var f: Array = FACES[fi]
			var rel: Vector3i = p - lo
			var plane: int = rel[_axis(f[0])]
			var u: int = rel[_axis(f[1])]
			var v: int = rel[_axis(f[2])]
			var sig: int = col_idx << 9 | int(glowing) << 8 | ao0 << 6 | ao1 << 4 | ao2 << 2 | ao3
			face_keys[fi].append(plane << 48 | v << 36 | u << 24 | sig)
	for fi in 6:
		var keys: PackedInt64Array = face_keys[fi]
		if keys.is_empty():
			continue
		keys.sort()
		_merge(keys, fi, lo, colors, surf, scale, pivot)
	return surf


static func _offset(d: Vector3i, dx: int, dxy: int) -> int:
	return d.x + d.y * dx + d.z * dxy


## Linear merge of one direction's sorted face keys into quads.
static func _merge(keys: PackedInt64Array, fi: int, lo: Vector3i, colors: Array[Color], surf: Array, scale: float, pivot: Vector3) -> void:
	var f: Array = FACES[fi]
	var a := _axis(f[0])
	var ua := _axis(f[1])
	var va := _axis(f[2])
	var mask12 := (1 << 12) - 1
	var mask24 := (1 << 24) - 1
	var open := {}      # runs that can still grow: key (u0, len, sig) -> [v0, v_last]
	var cur_plane := -1
	var cur_v := -1
	var n := keys.size()
	var k := 0
	while k < n:
		var key: int = keys[k]
		var plane: int = key >> 48
		var v: int = (key >> 36) & mask12
		var u0: int = (key >> 24) & mask12
		var sig: int = key & mask24
		# run along u
		var len := 1
		var u_ok := (sig >> 6 & 3) == (sig >> 4 & 3) and (sig & 3) == (sig >> 2 & 3)
		while u_ok and k + len < n:
			var nk: int = keys[k + len]
			if (nk >> 36) != (key >> 36) or ((nk >> 24) & mask12) != u0 + len or (nk & mask24) != sig:
				break
			len += 1
		k += len
		if plane != cur_plane or v != cur_v:
			# new row: runs that didn't continue into it are finished
			var keep := plane == cur_plane and v == cur_v + 1
			for rk in open.keys():
				var r: Array = open[rk]
				if not keep or r[1] < v - 1:
					_emit(rk, r, plane if keep else cur_plane, fi, a, ua, va, lo, colors, surf, scale, pivot)
					open.erase(rk)
			cur_plane = plane
			cur_v = v
		var v_ok := (sig >> 6 & 3) == (sig & 3) and (sig >> 4 & 3) == (sig >> 2 & 3)
		var rkey: int = u0 << 36 | len << 24 | sig
		if v_ok and open.has(rkey) and open[rkey][1] == v - 1:
			open[rkey][1] = v
		else:
			if open.has(rkey):
				_emit(rkey, open[rkey], plane, fi, a, ua, va, lo, colors, surf, scale, pivot)
			open[rkey] = [v, v] if v_ok else [v, v]
			if not v_ok:
				_emit(rkey, open[rkey], plane, fi, a, ua, va, lo, colors, surf, scale, pivot)
				open.erase(rkey)
	for rk in open.keys():
		_emit(rk, open[rk], cur_plane, fi, a, ua, va, lo, colors, surf, scale, pivot)


static func _emit(rkey: int, r: Array, plane: int, fi: int, a: int, ua: int, va: int, lo: Vector3i,
		colors: Array[Color], surf: Array, scale: float, pivot: Vector3) -> void:
	var sig: int = rkey & ((1 << 24) - 1)
	var w: int = (rkey >> 24) & ((1 << 12) - 1)
	var u0: int = rkey >> 36
	var v0: int = r[0]
	var h: int = r[1] - v0 + 1
	var origin := Vector3i.ZERO
	origin[a] = plane + lo[a]
	origin[ua] = u0 + lo[ua]
	origin[va] = v0 + lo[va]
	var glowing := (sig >> 8) & 1 == 1
	var ao := [sig >> 6 & 3, sig >> 4 & 3, sig >> 2 & 3, sig & 3]
	var raw: Color = colors[sig >> 9]
	var col := Color(raw.r, raw.g, raw.b).srgb_to_linear()
	col.a = raw.a
	_quad(surf[1] if glowing else surf[0], origin, FACES[fi], w, h, col, ao, scale, pivot, glowing)


static func _axis(d: Vector3i) -> int:
	return 0 if d.x != 0 else (1 if d.y != 0 else 2)


## Emit one quad covering w × h faces starting at voxel p, for face f.
static func _quad(target: Dictionary, p: Vector3i, f: Array, w: int, h: int, col: Color, ao: Array, scale: float, pivot: Vector3, glowing := false) -> void:
	var n: Vector3i = f[0]
	var u := Vector3(f[1]) * w
	var v := Vector3(f[2]) * h
	var base := Vector3(p)
	if n.x + n.y + n.z > 0:
		base += Vector3(n)
	var corners := [base, base + u, base + u + v, base + v]
	var nf := Vector3(n)
	var start: int = target.v.size()
	for k in 4:
		target.v.append((corners[k] - pivot) * scale)
		target.n.append(nf)
		var shade: float = 1.0 if glowing else AO_CURVE[ao[k]]
		target.c.append(Color(col.r * shade, col.g * shade, col.b * shade, col.a))
	# Clockwise winding (Godot front faces); flip the diagonal to follow the
	# darker corners and avoid AO streaks.
	if ao[0] + ao[2] >= ao[1] + ao[3]:
		target.i.append_array([start, start + 2, start + 1, start, start + 3, start + 2])
	else:
		target.i.append_array([start, start + 3, start + 1, start + 1, start + 3, start + 2])


static func _new_arrays() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "c": PackedColorArray(), "i": PackedInt32Array()}
