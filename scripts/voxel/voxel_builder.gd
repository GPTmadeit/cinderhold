extends RefCounted
## Voxel model builder: paint voxels into a grid, then mesh only exposed
## faces with per-corner ambient occlusion baked into vertex colours.
## Voxels marked as glowing go to a second, emissive surface.

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

var vox := {}      # Vector3i -> Color
var glow := {}     # Vector3i -> true
var skip_bottom := false
## Characters need hit-flash/dissolve; everything else uses the cheaper static shader.
var dynamic := false


## Deterministic per-voxel colour variation so surfaces read as hand-painted.
static func vary(c: Color, p: Vector3i, amount: float) -> Color:
	if amount <= 0.0:
		return c
	var h := float(absi(hash(p)) % 1000) / 1000.0 - 0.5
	return Color(clampf(c.r + h * amount, 0, 1), clampf(c.g + h * amount * 0.95, 0, 1), clampf(c.b + h * amount * 0.9, 0, 1))


func put(p: Vector3i, c: Color, noise := 0.0, glowing := false) -> void:
	# alpha carries the shader's per-voxel variation amount (see voxel.gdshader)
	vox[p] = Color(c.r, c.g, c.b, clampf(noise, 0.0, 0.5))
	if glowing:
		glow[p] = true
	else:
		glow.erase(p)


func box(a: Vector3i, b: Vector3i, c: Color, noise := 0.05, glowing := false) -> void:
	for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			for z in range(mini(a.z, b.z), maxi(a.z, b.z) + 1):
				put(Vector3i(x, y, z), c, noise, glowing)


## Paint only voxels that already exist inside the box (decals, stripes).
func paint(a: Vector3i, b: Vector3i, c: Color, noise := 0.05, glowing := false) -> void:
	for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			for z in range(mini(a.z, b.z), maxi(a.z, b.z) + 1):
				var p := Vector3i(x, y, z)
				if vox.has(p):
					put(p, c, noise, glowing)


func carve(a: Vector3i, b: Vector3i) -> void:
	for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			for z in range(mini(a.z, b.z), maxi(a.z, b.z) + 1):
				vox.erase(Vector3i(x, y, z))
				glow.erase(Vector3i(x, y, z))


## Mirror every voxel across the plane x = mirror_x (inclusive centre axis).
func mirror_x(mirror_at: int) -> void:
	for p in vox.keys():
		var q := Vector3i(2 * mirror_at - p.x, p.y, p.z)
		if not vox.has(q):
			vox[q] = vox[p]
			if glow.has(p):
				glow[q] = true


func sphere(c: Vector3, r: float, col: Color, noise := 0.05, glowing := false) -> void:
	var ri := int(ceil(r))
	for x in range(-ri, ri + 1):
		for y in range(-ri, ri + 1):
			for z in range(-ri, ri + 1):
				if Vector3(x, y, z).length() <= r:
					put(Vector3i(int(c.x) + x, int(c.y) + y, int(c.z) + z), col, noise, glowing)


func bounds() -> AABB:
	var lo := Vector3i(1 << 20, 1 << 20, 1 << 20)
	var hi := -lo
	for p in vox:
		lo = Vector3i(mini(lo.x, p.x), mini(lo.y, p.y), mini(lo.z, p.z))
		hi = Vector3i(maxi(hi.x, p.x), maxi(hi.y, p.y), maxi(hi.z, p.z))
	return AABB(Vector3(lo), Vector3(hi - lo + Vector3i.ONE))


static func material(glowing: bool, strength := 2.5, scale := 0.0625, pivot := Vector3(0.5, 0, 0.5), dyn := false) -> ShaderMaterial:
	var frac := Vector3(fposmod(pivot.x, 1.0), fposmod(pivot.y, 1.0), fposmod(pivot.z, 1.0))
	var key := "%s_%s_%s_%s_%s" % [glowing, strength, scale, frac, dyn]
	if not _materials.has(key):
		var m := ShaderMaterial.new()
		m.shader = SHADER if dyn else SHADER_STATIC
		m.set_shader_parameter("emission_strength", strength if glowing else 0.0)
		m.set_shader_parameter("roughness_base", 0.6 if glowing else 0.86)
		m.set_shader_parameter("voxel_size", scale)
		m.set_shader_parameter("pivot_frac", frac)
		_materials[key] = m
	return _materials[key]


## Build the mesh. `scale` is the edge length of one voxel in metres and
## `pivot` is the voxel-space point that becomes the mesh origin.
func build(scale: float, pivot := Vector3.ZERO, glow_strength := 2.5) -> ArrayMesh:
	return build_subset(vox.keys(), scale, pivot, glow_strength)


## Mesh only `keys`, still culling against every voxel in the model. Used to
## split large maps into chunks without seams.
##
## Greedy meshing: faces in the same plane with the same colour and uniform
## AO are merged into larger rectangles. Faces with AO gradients (corners,
## creases) stay single quads so the baked shading is preserved.
func build_subset(keys: Array, scale: float, pivot := Vector3.ZERO, glow_strength := 2.5) -> ArrayMesh:
	var surf := [_new_arrays(), _new_arrays()]
	# planes[face][plane_index] = {Vector2i(u, v): [color, ao, glowing]}
	var planes := []
	for fi in 6:
		planes.append({})
	for p in keys:
		var raw: Color = vox[p]
		var col := Color(raw.r, raw.g, raw.b).srgb_to_linear()
		col.a = raw.a
		var glowing := glow.has(p)
		for fi in 6:
			var f: Array = FACES[fi]
			var n: Vector3i = f[0]
			if skip_bottom and n.y == -1:
				continue
			var q: Vector3i = p + n
			if vox.has(q):
				continue
			var u: Vector3i = f[1]
			var v: Vector3i = f[2]
			var ao := [
				_ao(q - u, q - v, q - u - v),
				_ao(q + u, q - v, q + u - v),
				_ao(q + u, q + v, q + u + v),
				_ao(q - u, q + v, q - u + v),
			]
			if glowing or (ao[0] == ao[1] and ao[1] == ao[2] and ao[2] == ao[3]):
				var a := _axis(n)
				var plane: int = p[a]
				if not planes[fi].has(plane):
					planes[fi][plane] = {}
				planes[fi][plane][Vector2i(p[_axis(u)], p[_axis(v)])] = [col, 3 if glowing else ao[0], glowing]
			else:
				_quad(surf[0], p, f, 1, 1, col, ao, scale, pivot)
	for fi in 6:
		var f: Array = FACES[fi]
		var a := _axis(f[0])
		var ua := _axis(f[1])
		var va := _axis(f[2])
		for plane in planes[fi]:
			var cells: Dictionary = planes[fi][plane]
			var order := cells.keys()
			order.sort_custom(func(x: Vector2i, y: Vector2i): return x.y < y.y or (x.y == y.y and x.x < y.x))
			var used := {}
			for c in order:
				if used.has(c):
					continue
				var sig: Array = cells[c]
				var w := 1
				while true:
					var nc := Vector2i(c.x + w, c.y)
					if used.has(nc) or not cells.has(nc) or cells[nc] != sig:
						break
					w += 1
				var h := 1
				var grow := true
				while grow:
					for i in w:
						var nc := Vector2i(c.x + i, c.y + h)
						if used.has(nc) or not cells.has(nc) or cells[nc] != sig:
							grow = false
							break
					if grow:
						h += 1
				for j in h:
					for i in w:
						used[Vector2i(c.x + i, c.y + j)] = true
				var origin := Vector3i.ZERO
				origin[a] = plane
				origin[ua] = c.x
				origin[va] = c.y
				var aov: int = sig[1]
				_quad(surf[1] if sig[2] else surf[0], origin, f, w, h, sig[0], [aov, aov, aov, aov], scale, pivot, sig[2])
	var mesh := ArrayMesh.new()
	for k in 2:
		var sa: Dictionary = surf[k]
		if sa.v.is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = sa.v
		arr[Mesh.ARRAY_NORMAL] = sa.n
		arr[Mesh.ARRAY_COLOR] = sa.c
		arr[Mesh.ARRAY_INDEX] = sa.i
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material(k == 1, glow_strength, scale, pivot, dynamic))
	return mesh


static func _axis(d: Vector3i) -> int:
	return 0 if d.x != 0 else (1 if d.y != 0 else 2)


## Emit one quad covering w × h faces starting at voxel p, for face f.
func _quad(target: Dictionary, p: Vector3i, f: Array, w: int, h: int, col: Color, ao: Array, scale: float, pivot: Vector3, glowing := false) -> void:
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


func _ao(s1: Vector3i, s2: Vector3i, c: Vector3i) -> int:
	var a := vox.has(s1)
	var b := vox.has(s2)
	if a and b:
		return 0
	return 3 - int(a) - int(b) - int(vox.has(c))


static func _new_arrays() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "c": PackedColorArray(), "i": PackedInt32Array()}
