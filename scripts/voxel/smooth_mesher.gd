extends RefCounted
## Rounded meshes for voxel models, so organic and turned things (bodies,
## heads, barrels, grenades) don't look like stacked cubes.
##
## The model is resampled on a lattice of `step` fine voxels (the authoring
## grid for res-2 models) and blurred; every exposed lattice face becomes a
## quad whose corners are pulled onto the blurred shape's surface, which
## rounds corners and edges by about `radius` lattice cells while flat faces
## stay flat. Corners hardly move outward (carved detail stays recessed),
## and never further in than 45% of the material behind
## it, so thin parts keep their thickness. A limb cut at a joint
## (`cut_below`/`cut_above`, fine y) is treated as carrying on past the cut,
## so the cut face stays flat and meets the other half.
##
## Colours don't live on the vertices: a 3D texture holds one texel per fine
## voxel (spread a couple of cells outward to cover the rounded shell), and the
## shader (shaders/voxel_smooth*.gdshader) samples the voxel just under the
## surface, so painted detail stays as crisp as on the blocky meshes.

const SHADER := preload("res://shaders/voxel_smooth.gdshader")
const VB := preload("res://scripts/voxel/voxel_builder.gd")
const Weather := preload("res://scripts/world/weather.gd")
const SHADER_STATIC := preload("res://shaders/voxel_smooth_static.gdshader")

## [normal, u, v] with u × v = normal (the same table as voxel_builder.gd).
const FACES := [
	[Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1)],
	[Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 1, 0)],
	[Vector3i(0, 1, 0), Vector3i(0, 0, 1), Vector3i(1, 0, 0)],
	[Vector3i(0, -1, 0), Vector3i(1, 0, 0), Vector3i(0, 0, 1)],
	[Vector3i(0, 0, 1), Vector3i(1, 0, 0), Vector3i(0, 1, 0)],
	[Vector3i(0, 0, -1), Vector3i(0, 1, 0), Vector3i(1, 0, 0)],
]
## A lattice cell is solid when at least this share of its fine voxels is.
const FILL := 0.3
const NO_CUT := -1073741824     # no joint cut


## `vox`/`glow`: the builder's fine voxels. `scale`: fine voxel size in
## metres; `pivot`: the fine-grid point that becomes the mesh origin.
static func build(vox: Dictionary, glow: Dictionary, step: int, radius: int, scale: float, pivot: Vector3,
		glow_strength: float, dyn: bool, cut_below := NO_CUT, cut_above := NO_CUT) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if vox.is_empty():
		return mesh
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for p in vox:
		lo = Vector3i(mini(lo.x, p.x), mini(lo.y, p.y), mini(lo.z, p.z))
		hi = Vector3i(maxi(hi.x, p.x), maxi(hi.y, p.y), maxi(hi.z, p.z))
	# --- coarse occupancy ---
	var pad := radius + 2
	var co := Vector3i(floori(float(lo.x) / step), floori(float(lo.y) / step), floori(float(lo.z) / step)) - Vector3i.ONE * pad
	var chi := Vector3i(floori(float(hi.x) / step), floori(float(hi.y) / step), floori(float(hi.z) / step)) + Vector3i.ONE * pad
	var n := chi - co + Vector3i.ONE
	var nxy := n.x * n.y
	var occ := PackedFloat32Array()
	occ.resize(nxy * n.z)
	var unit := 1.0 / (step * step * step)
	for p: Vector3i in vox:
		var c := Vector3i(floori(float(p.x) / step), floori(float(p.y) / step), floori(float(p.z) / step)) - co
		occ[c.x + c.y * n.x + c.z * nxy] += unit
	# carry the material on past joint cuts, for the field only
	var ext := occ.duplicate()
	if cut_below != NO_CUT:
		_extend(ext, n, floori(float(cut_below) / step) - co.y, -1)
	if cut_above != NO_CUT:
		_extend(ext, n, floori(float(cut_above) / step) - co.y - 1, 1)
	var field := _blur(ext, n, radius)
	var solid := PackedByteArray()
	solid.resize(occ.size())
	for i in occ.size():
		solid[i] = 1 if occ[i] >= FILL else 0

	# --- faces on the lattice, corners shared ---
	var ln := n + Vector3i.ONE
	var lnxy := ln.x * ln.y
	var vid := PackedInt32Array()
	vid.resize(lnxy * ln.z)
	vid.fill(-1)
	var corners := PackedVector3Array()   # lattice point of each vertex
	var raw_n := PackedVector3Array()     # sum of the blocky face normals there
	var idx := PackedInt32Array()
	var offs := [1, -1, n.x, -n.x, nxy, -nxy]
	for z in range(1, n.z - 1):
		for y in range(1, n.y - 1):
			for x in range(1, n.x - 1):
				var i := x + y * n.x + z * nxy
				if solid[i] == 0:
					continue
				for fi in 6:
					if solid[i + offs[fi]] == 1:
						continue
					var f: Array = FACES[fi]
					var nn: Vector3i = f[0]
					var u: Vector3i = f[1]
					var v: Vector3i = f[2]
					var base := Vector3i(x, y, z)
					if nn.x + nn.y + nn.z > 0:
						base += nn
					var q := PackedInt32Array()
					for k in 4:
						var lp: Vector3i = base + (u if k == 1 or k == 2 else Vector3i.ZERO) + (v if k >= 2 else Vector3i.ZERO)
						var li := lp.x + lp.y * ln.x + lp.z * lnxy
						if vid[li] == -1:
							vid[li] = corners.size()
							corners.append(Vector3(lp))
							raw_n.append(Vector3.ZERO)
						var vi := vid[li]
						raw_n[vi] += Vector3(nn)
						q.append(vi)
					idx.append_array([q[0], q[2], q[1], q[0], q[3], q[2]])

	# --- pull the corners onto the rounded surface ---
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(corners.size())
	norms.resize(corners.size())
	cols.resize(corners.size())
	var reach := radius * 0.9 + 0.25
	for vi in corners.size():
		var p0: Vector3 = corners[vi]
		var rn: Vector3 = raw_n[vi].normalized() if raw_n[vi].length_squared() > 0.0 else Vector3.UP
		var p := p0
		for it in 5:
			var vg := _sample_grad(field, n, p)
			var val := vg.x
			if absf(val - 0.5) < 0.01:
				break
			var g := Vector3(vg.y, vg.z, vg.w)
			var g2 := g.length_squared()
			if g2 < 1e-6:
				break
			var stp := g * ((0.5 - val) / g2)
			if stp.length() > 0.5:
				stp = stp.normalized() * 0.5
			p += stp
		# never deeper than 45% of the material behind the corner
		var thick := 0.0
		while thick < 2.0 * radius + 2.0:
			var s := p0 - rn * (thick + 0.25)
			var c := Vector3i(floori(s.x), floori(s.y), floori(s.z))
			if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= n.x or c.y >= n.y or c.z >= n.z or solid[c.x + c.y * n.x + c.z * nxy] == 0:
				break
			thick += 0.5
		var d := p - p0
		# barely outward: carved sockets, mouths and grooves stay recessed
		var out := d.dot(rn)
		if out > 0.15:
			d -= rn * (out - 0.15)
		var lim := minf(reach, 0.45 * maxf(thick, 0.5))
		if d.length() > lim:
			d = d.normalized() * lim
		p = p0 + d
		var ao := clampf(1.3 - 1.6 * _sample(field, n, p + rn * 0.9), 0.45, 1.0)
		var fine := (p + Vector3(co)) * step
		verts[vi] = (fine - pivot) * scale
		norms[vi] = Vector3.ZERO
		raw_n[vi] = rn
		cols[vi] = Color(ao, ao, ao, 1.0)
	# smooth normals: each vertex averages its triangles (area-weighted)
	for t in range(0, idx.size(), 3):
		var a := idx[t]
		var b := idx[t + 1]
		var c := idx[t + 2]
		var fn := (verts[c] - verts[a]).cross(verts[b] - verts[a])
		norms[a] += fn
		norms[b] += fn
		norms[c] += fn
	for vi in norms.size():
		norms[vi] = norms[vi].normalized() if norms[vi].length_squared() > 1e-20 else raw_n[vi]
	if idx.is_empty():
		return mesh
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	# the shell sits at most a lattice cell (plus a sliver) outside the voxels
	var margin := step + 2
	mesh.surface_set_material(0, _material(vox, glow, lo - Vector3i.ONE * margin, hi + Vector3i.ONE * margin,
		scale, pivot, glow_strength, dyn, margin))
	return mesh


## Copy layer `y` of `f` over every layer beyond it in direction `dir` (±1).
static func _extend(f: PackedFloat32Array, n: Vector3i, y: int, dir: int) -> void:
	if y < 0 or y >= n.y:
		return
	var nxy := n.x * n.y
	var yy := y + dir
	while yy >= 0 and yy < n.y:
		for z in n.z:
			for x in n.x:
				f[x + yy * n.x + z * nxy] = f[x + y * n.x + z * nxy]
		yy += dir


## Box blur, twice along each axis (close to a Gaussian), radius `r` cells.
static func _blur(src: PackedFloat32Array, n: Vector3i, r: int) -> PackedFloat32Array:
	var a := src.duplicate()
	if r <= 0:
		return a
	var strides := [1, n.x, n.x * n.y]
	var lens := [n.x, n.y, n.z]
	var b := PackedFloat32Array()
	b.resize(a.size())
	var inv := 1.0 / (2 * r + 1)
	for axis in 3:
		var st: int = strides[axis]
		var len: int = lens[axis]
		# the other two axes enumerate the lines' first cells
		var oa: int = (axis + 1) % 3
		var ob: int = (axis + 2) % 3
		var starts := PackedInt32Array()
		for ib in lens[ob]:
			for ia in lens[oa]:
				starts.append(ia * strides[oa] + ib * strides[ob])
		for _pass in 2:
			for start in starts:
				var sum := 0.0
				for k in range(-r, r + 1):
					if k >= 0 and k < len:
						sum += a[start + k * st]
				for k in len:
					b[start + k * st] = sum * inv
					var out_k := k - r
					var in_k := k + r + 1
					if out_k >= 0:
						sum -= a[start + out_k * st]
					if in_k < len:
						sum += a[start + in_k * st]
			var t := a
			a = b
			b = t
	return a


## The field at a lattice-space point (cell centres sit at +0.5), trilinear.
static func _sample(f: PackedFloat32Array, n: Vector3i, p: Vector3) -> float:
	var u := p - Vector3(0.5, 0.5, 0.5)
	var x0 := clampi(floori(u.x), 0, n.x - 2)
	var y0 := clampi(floori(u.y), 0, n.y - 2)
	var z0 := clampi(floori(u.z), 0, n.z - 2)
	var tx := clampf(u.x - x0, 0.0, 1.0)
	var ty := clampf(u.y - y0, 0.0, 1.0)
	var tz := clampf(u.z - z0, 0.0, 1.0)
	var nxy := n.x * n.y
	var i := x0 + y0 * n.x + z0 * nxy
	var c00 := lerpf(f[i], f[i + 1], tx)
	var c10 := lerpf(f[i + n.x], f[i + n.x + 1], tx)
	var c01 := lerpf(f[i + nxy], f[i + nxy + 1], tx)
	var c11 := lerpf(f[i + nxy + n.x], f[i + nxy + n.x + 1], tx)
	return lerpf(lerpf(c00, c10, ty), lerpf(c01, c11, ty), tz)


## Value and gradient in one lookup (x = value, yzw = gradient), from the
## trilinear cell around `p`; cheap enough for the corner search.
static func _sample_grad(f: PackedFloat32Array, n: Vector3i, p: Vector3) -> Vector4:
	var u := p - Vector3(0.5, 0.5, 0.5)
	var x0 := clampi(floori(u.x), 0, n.x - 2)
	var y0 := clampi(floori(u.y), 0, n.y - 2)
	var z0 := clampi(floori(u.z), 0, n.z - 2)
	var tx := clampf(u.x - x0, 0.0, 1.0)
	var ty := clampf(u.y - y0, 0.0, 1.0)
	var tz := clampf(u.z - z0, 0.0, 1.0)
	var nxy := n.x * n.y
	var i := x0 + y0 * n.x + z0 * nxy
	var c000 := f[i]
	var c100 := f[i + 1]
	var c010 := f[i + n.x]
	var c110 := f[i + n.x + 1]
	var c001 := f[i + nxy]
	var c101 := f[i + nxy + 1]
	var c011 := f[i + nxy + n.x]
	var c111 := f[i + nxy + n.x + 1]
	var x00 := lerpf(c000, c100, tx)
	var x10 := lerpf(c010, c110, tx)
	var x01 := lerpf(c001, c101, tx)
	var x11 := lerpf(c011, c111, tx)
	var y0v := lerpf(x00, x10, ty)
	var y1v := lerpf(x01, x11, ty)
	return Vector4(lerpf(y0v, y1v, tz),
		lerpf(lerpf(c100 - c000, c110 - c010, ty), lerpf(c101 - c001, c111 - c011, ty), tz),
		lerpf(x10 - x00, x11 - x01, tz),
		y1v - y0v)


static func _grad(f: PackedFloat32Array, n: Vector3i, p: Vector3) -> Vector3:
	var h := 0.5
	return Vector3(
		_sample(f, n, p + Vector3(h, 0, 0)) - _sample(f, n, p - Vector3(h, 0, 0)),
		_sample(f, n, p + Vector3(0, h, 0)) - _sample(f, n, p - Vector3(0, h, 0)),
		_sample(f, n, p + Vector3(0, 0, h)) - _sample(f, n, p - Vector3(0, 0, h))) / (2.0 * h)


## The colour texture over fine cells [tlo, thi], each voxel's colour spread
## outward ring by ring so the rounded shell always finds one.
static func _material(vox: Dictionary, glow: Dictionary, tlo: Vector3i, thi: Vector3i, scale: float, pivot: Vector3,
		glow_strength: float, dyn: bool, rings_max: int) -> ShaderMaterial:
	var ts := thi - tlo + Vector3i.ONE
	var txy := ts.x * ts.y
	var data := PackedByteArray()
	data.resize(txy * ts.z * 4)
	var filled := PackedByteArray()
	filled.resize(txy * ts.z)
	var front := PackedInt32Array()
	for p: Vector3i in vox:
		var c: Color = vox[p]
		var i := (p.x - tlo.x) + (p.y - tlo.y) * ts.x + (p.z - tlo.z) * txy
		data[i * 4] = c.r8
		data[i * 4 + 1] = c.g8
		data[i * 4 + 2] = c.b8
		data[i * 4 + 3] = 255 if glow.has(p) else roundi(clampf(c.a, 0.0, 0.5) / 0.5 * 0.4 * 255.0)
		filled[i] = 1
		front.append(i)
	var offs := [1, -1, ts.x, -ts.x, txy, -txy]
	var rings := rings_max
	while not front.is_empty() and rings > 0:
		rings -= 1
		var next := PackedInt32Array()
		for i in front:
			var x := i % ts.x
			var y := (i / ts.x) % ts.y
			var z := i / txy
			for k in 6:
				if (k == 0 and x == ts.x - 1) or (k == 1 and x == 0) or (k == 2 and y == ts.y - 1) \
						or (k == 3 and y == 0) or (k == 4 and z == ts.z - 1) or (k == 5 and z == 0):
					continue
				var j: int = i + offs[k]
				if filled[j] == 1:
					continue
				filled[j] = 1
				for b in 4:
					data[j * 4 + b] = data[i * 4 + b]
				next.append(j)
		front = next
	var images: Array[Image] = []
	for z in ts.z:
		images.append(Image.create_from_data(ts.x, ts.y, false, Image.FORMAT_RGBA8, data.slice(z * txy * 4, (z + 1) * txy * 4)))
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RGBA8, ts.x, ts.y, ts.z, false, images)
	Weather.ensure_globals()
	var m := ShaderMaterial.new()
	m.shader = SHADER if dyn else SHADER_STATIC
	m.set_shader_parameter("albedo_tex", tex)
	m.set_shader_parameter("grid_origin", pivot - Vector3(tlo))
	m.set_shader_parameter("grid_size", Vector3(ts))
	m.set_shader_parameter("voxel_size", scale)
	m.set_shader_parameter("emission_strength", glow_strength)
	return m


## Rounded mesh by relaxation: every exposed lattice face (a lattice cell is
## `step` fine voxels, solid when at least half full) becomes a quad, and the
## corners are relaxed (`passes` Laplacian steps, each corner allowed to sink
## at most ~40% of the material behind it). Unlike build(), nothing can
## vanish however thin it is: a one-voxel strap becomes a round cord, a limb
## a tube. Quads the relaxation never reached are merged back into large
## flat quads, as the blocky mesher does. Joint cuts keep their height so
## elbows and knees meet. Colours come from the fine voxels (_material).
static func build_relaxed(vox: Dictionary, glow: Dictionary, passes: int, scale: float, pivot: Vector3,
		glow_strength: float, dyn: bool, cut_below := NO_CUT, cut_above := NO_CUT, step := 1) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if vox.is_empty():
		return mesh
	var flo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var fhi := -flo
	for p in vox:
		flo = Vector3i(mini(flo.x, p.x), mini(flo.y, p.y), mini(flo.z, p.z))
		fhi = Vector3i(maxi(fhi.x, p.x), maxi(fhi.y, p.y), maxi(fhi.z, p.z))
	# lattice bounds (cells), one empty cell of border
	var lo := Vector3i(floori(float(flo.x) / step), floori(float(flo.y) / step), floori(float(flo.z) / step)) - Vector3i.ONE
	var hi := Vector3i(floori(float(fhi.x) / step), floori(float(fhi.y) / step), floori(float(fhi.z) / step)) + Vector3i.ONE
	var n := hi - lo + Vector3i.ONE
	var nxy := n.x * n.y
	var occ := PackedByteArray()
	occ.resize(nxy * n.z)
	if step == 1:
		for p: Vector3i in vox:
			var r := p - lo
			occ[r.x + r.y * n.x + r.z * nxy] = 1
	else:
		var cnt_f := PackedInt32Array()
		cnt_f.resize(nxy * n.z)
		for p: Vector3i in vox:
			var r := Vector3i(floori(float(p.x) / step), floori(float(p.y) / step), floori(float(p.z) / step)) - lo
			cnt_f[r.x + r.y * n.x + r.z * nxy] += 1
		var need := (step * step * step + 1) / 2
		for i in cnt_f.size():
			occ[i] = 1 if cnt_f[i] >= need else 0
	var ln := n + Vector3i.ONE
	var lnxy := ln.x * ln.y
	var vid := PackedInt32Array()
	vid.resize(lnxy * ln.z)
	vid.fill(-1)
	var pos := PackedVector3Array()
	var quads := PackedInt32Array()
	var qcell := PackedInt32Array()      # per quad: face index, cell x, y, z
	var offs := [1, -1, n.x, -n.x, nxy, -nxy]
	for z in range(1, n.z - 1):
		for y in range(1, n.y - 1):
			for x in range(1, n.x - 1):
				var i := x + y * n.x + z * nxy
				if occ[i] == 0:
					continue
				for fi in 6:
					if occ[i + offs[fi]] == 1:
						continue
					var f: Array = FACES[fi]
					var nn: Vector3i = f[0]
					var u: Vector3i = f[1]
					var v: Vector3i = f[2]
					var base := Vector3i(x, y, z)
					if nn.x + nn.y + nn.z > 0:
						base += nn
					for k in 4:
						var lp: Vector3i = base + (u if k == 1 or k == 2 else Vector3i.ZERO) + (v if k >= 2 else Vector3i.ZERO)
						var li := lp.x + lp.y * ln.x + lp.z * lnxy
						if vid[li] == -1:
							vid[li] = pos.size()
							pos.append(Vector3(lp))
						quads.append(vid[li])
					qcell.append_array([fi, x, y, z])
	var nv := pos.size()
	var nq := quads.size() / 4
	if nq == 0:
		return mesh
	# each corner may sink at most ~40% of the material behind it, and
	# `passes` / 4 cells in all, so thin parts round off but never collapse
	var raw_n := PackedVector3Array()
	raw_n.resize(nv)
	for q in nq:
		var o := q * 4
		var fnq := Vector3(FACES[qcell[q * 4]][0])
		for k in 4:
			raw_n[quads[o + k]] += fnq
	var reach := PackedFloat32Array()
	reach.resize(nv)
	var cap := passes * 0.25
	for vi in nv:
		var rn := raw_n[vi].normalized() if raw_n[vi].length_squared() > 0.0 else Vector3.UP
		var thick := 0.0
		while thick < cap * 3.0:
			var sp := pos[vi] - rn * (thick + 0.3)
			var c := Vector3i(floori(sp.x), floori(sp.y), floori(sp.z))
			if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= n.x or c.y >= n.y or c.z >= n.z or occ[c.x + c.y * n.x + c.z * nxy] == 0:
				break
			thick += 0.5
		reach[vi] = minf(cap, 0.4 * maxf(thick, 0.5))
	var orig := pos.duplicate()
	# vertices on a joint cut keep their height
	var pin_y := PackedByteArray()
	pin_y.resize(nv)
	for vi in nv:
		var y := (int(pos[vi].y) + lo.y) * step
		if (cut_below != NO_CUT and y == cut_below) or (cut_above != NO_CUT and y == cut_above):
			pin_y[vi] = 1
	var acc := PackedVector3Array()
	acc.resize(nv)
	var cnt := PackedFloat32Array()
	cnt.resize(nv)
	for pass_i in passes:
		acc.fill(Vector3.ZERO)
		cnt.fill(0.0)
		for q in nq:
			var o := q * 4
			for k in 4:
				var va := quads[o + k]
				var vb := quads[o + (k + 1) % 4]
				acc[va] += pos[vb]
				acc[vb] += pos[va]
				cnt[va] += 1.0
				cnt[vb] += 1.0
		for vi in nv:
			var d := (acc[vi] / cnt[vi] - pos[vi]) * 0.5
			if pin_y[vi]:
				d.y = 0.0
			var np := pos[vi] + d
			var off := np - orig[vi]
			if off.length() > reach[vi]:
				np = orig[vi] + off.normalized() * reach[vi]
			pos[vi] = np
	var nrm := PackedVector3Array()
	nrm.resize(nv)
	for q in nq:
		var o := q * 4
		var a := quads[o]
		var fn := (pos[quads[o + 1]] - pos[a]).cross(pos[quads[o + 2]] - pos[a]) + (pos[quads[o + 2]] - pos[a]).cross(pos[quads[o + 3]] - pos[a])
		for k in 4:
			nrm[quads[o + k]] += fn
	var ao := PackedFloat32Array()
	ao.resize(nv)
	for vi in nv:
		var nr := nrm[vi].normalized() if nrm[vi].length_squared() > 1e-20 else Vector3.UP
		nrm[vi] = nr
		# occlusion: how much of the 2×2×2 block in front of the corner is solid
		var sp := pos[vi] + nr * 1.2 - Vector3(0.5, 0.5, 0.5)
		var c0 := Vector3i(floori(sp.x), floori(sp.y), floori(sp.z))
		var solid := 0
		for dz in 2:
			for dy in 2:
				for dx in 2:
					var c := c0 + Vector3i(dx, dy, dz)
					if c.x >= 0 and c.y >= 0 and c.z >= 0 and c.x < n.x and c.y < n.y and c.z < n.z and occ[c.x + c.y * n.x + c.z * nxy] == 1:
						solid += 1
		ao[vi] = clampf(1.15 - solid * 0.12, 0.5, 1.0)
	# untouched flat quads go to the greedy merge; the rest are emitted as they are
	var lattice_scale := scale * step
	var lattice_pivot := (pivot - Vector3(lo * step)) / step
	var keys: Array[PackedInt64Array] = []
	for fi in 6:
		keys.append(PackedInt64Array())
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var remap := PackedInt32Array()
	remap.resize(nv)
	remap.fill(-1)
	for q in nq:
		var o := q * 4
		var fi := qcell[o]
		var fnv := Vector3(FACES[fi][0])
		var flat := true
		for k in 4:
			var vi := quads[o + k]
			if pos[vi].distance_squared_to(orig[vi]) > 1e-6 or nrm[vi].dot(fnv) < 0.9995 or ao[vi] < 0.999:
				flat = false
				break
		if flat:
			var cell := Vector3i(qcell[o + 1], qcell[o + 2], qcell[o + 3])
			var f: Array = FACES[fi]
			var ax := [0 if f[0].x != 0 else (1 if f[0].y != 0 else 2), 0 if f[1].x != 0 else (1 if f[1].y != 0 else 2), 0 if f[2].x != 0 else (1 if f[2].y != 0 else 2)]
			keys[fi].append(cell[ax[0]] << 48 | cell[ax[2]] << 36 | cell[ax[1]] << 24 | 255)
			continue
		var ids := PackedInt32Array()
		for k in 4:
			var vi := quads[o + k]
			if remap[vi] == -1:
				remap[vi] = verts.size()
				verts.append((pos[vi] - lattice_pivot) * lattice_scale)
				norms.append(nrm[vi])
				cols.append(Color(ao[vi], ao[vi], ao[vi], 1.0))
			ids.append(remap[vi])
		if pos[quads[o]].distance_squared_to(pos[quads[o + 2]]) <= pos[quads[o + 1]].distance_squared_to(pos[quads[o + 3]]):
			idx.append_array([ids[0], ids[2], ids[1], ids[0], ids[3], ids[2]])
		else:
			idx.append_array([ids[0], ids[3], ids[1], ids[1], ids[3], ids[2]])
	var surf := [{"v": verts, "n": norms, "c": cols, "i": idx}, {"v": PackedVector3Array(), "n": PackedVector3Array(), "c": PackedColorArray(), "i": PackedInt32Array()}]
	var white: Array[Color] = [Color(1, 1, 1, 1)]
	for fi in 6:
		if keys[fi].is_empty():
			continue
		keys[fi].sort()
		VB._merge(keys[fi], fi, Vector3i.ZERO, white, surf, lattice_scale, lattice_pivot)
	var sa: Dictionary = surf[0]
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = sa.v
	arr[Mesh.ARRAY_NORMAL] = sa.n
	arr[Mesh.ARRAY_COLOR] = sa.c
	arr[Mesh.ARRAY_INDEX] = sa.i
	var margin := 2 * step + 1
	var mat := _material(vox, glow, flo - Vector3i.ONE * margin, fhi + Vector3i.ONE * margin, scale, pivot, glow_strength, dyn, margin + 1)
	# simpler versions for when it's small on screen (a crowd down the street)
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, mat)
	im.generate_lods(30.0, 70.0, [])
	return im.get_mesh()
