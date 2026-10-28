extends RefCounted
## Voxel model builder: paint voxels into a grid, then mesh only exposed
## faces with per-corner ambient occlusion baked into vertex colours.
## Voxels marked as glowing go to a second, emissive surface.

const SHADER := preload("res://shaders/voxel.gdshader")

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


## Deterministic per-voxel colour variation so surfaces read as hand-painted.
static func vary(c: Color, p: Vector3i, amount: float) -> Color:
	if amount <= 0.0:
		return c
	var h := float(absi(hash(p)) % 1000) / 1000.0 - 0.5
	return Color(clampf(c.r + h * amount, 0, 1), clampf(c.g + h * amount * 0.95, 0, 1), clampf(c.b + h * amount * 0.9, 0, 1))


func put(p: Vector3i, c: Color, noise := 0.0, glowing := false) -> void:
	vox[p] = vary(c, p, noise)
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


static func material(glowing: bool, strength := 2.5) -> ShaderMaterial:
	var key := "%s_%s" % [glowing, strength]
	if not _materials.has(key):
		var m := ShaderMaterial.new()
		m.shader = SHADER
		m.set_shader_parameter("emission_strength", strength if glowing else 0.0)
		m.set_shader_parameter("roughness_base", 0.6 if glowing else 0.86)
		_materials[key] = m
	return _materials[key]


## Build the mesh. `scale` is the edge length of one voxel in metres and
## `pivot` is the voxel-space point that becomes the mesh origin.
func build(scale: float, pivot := Vector3.ZERO, glow_strength := 2.5) -> ArrayMesh:
	return build_subset(vox.keys(), scale, pivot, glow_strength)


## Mesh only `keys`, still culling against every voxel in the model. Used to
## split large maps into chunks without seams.
func build_subset(keys: Array, scale: float, pivot := Vector3.ZERO, glow_strength := 2.5) -> ArrayMesh:
	var surf := [_new_arrays(), _new_arrays()]
	for p in keys:
		var col: Color = (vox[p] as Color).srgb_to_linear()
		var target: Dictionary = surf[1] if glow.has(p) else surf[0]
		for f in FACES:
			var n: Vector3i = f[0]
			if skip_bottom and n.y == -1:
				continue
			var q: Vector3i = p + n
			if vox.has(q):
				continue
			var u: Vector3i = f[1]
			var v: Vector3i = f[2]
			var base := Vector3(p)
			if n.x + n.y + n.z > 0:
				base += Vector3(n)
			var ao := [
				_ao(q - u, q - v, q - u - v),
				_ao(q + u, q - v, q + u - v),
				_ao(q + u, q + v, q + u + v),
				_ao(q - u, q + v, q - u + v),
			]
			var corners := [base, base + Vector3(u), base + Vector3(u + v), base + Vector3(v)]
			var nf := Vector3(n)
			var start: int = target.v.size()
			for k in 4:
				target.v.append((corners[k] - pivot) * scale)
				target.n.append(nf)
				var a: float = 1.0 if glow.has(p) else AO_CURVE[ao[k]]
				target.c.append(Color(col.r * a, col.g * a, col.b * a))
			# Clockwise winding (Godot front faces); flip the diagonal to
			# follow the darker corners and avoid AO streaks.
			if ao[0] + ao[2] >= ao[1] + ao[3]:
				target.i.append_array([start, start + 2, start + 1, start, start + 3, start + 2])
			else:
				target.i.append_array([start, start + 3, start + 1, start + 1, start + 3, start + 2])
	var mesh := ArrayMesh.new()
	for k in 2:
		var s: Dictionary = surf[k]
		if s.v.is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = s.v
		arr[Mesh.ARRAY_NORMAL] = s.n
		arr[Mesh.ARRAY_COLOR] = s.c
		arr[Mesh.ARRAY_INDEX] = s.i
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material(k == 1, glow_strength))
	return mesh


func _ao(s1: Vector3i, s2: Vector3i, c: Vector3i) -> int:
	var a := vox.has(s1)
	var b := vox.has(s2)
	if a and b:
		return 0
	return 3 - int(a) - int(b) - int(vox.has(c))


static func _new_arrays() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "c": PackedColorArray(), "i": PackedInt32Array()}
