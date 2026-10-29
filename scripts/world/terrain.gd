extends RefCounted
## The outpost's floors, walls and roof beams at VPC voxels to the metre.
##
## Every voxel column is one 64-bit mask (bit k set = layer Y0 + k is
## solid), so carving relief into the masonry, culling hidden faces and
## working out corner occlusion are all bit tests. Chunks are meshed
## independently (setup() first, then mesh_chunk() from worker threads) and
## merged with the voxel builder's greedy mesher.

const VB := preload("res://scripts/voxel/voxel_builder.gd")

const VPC := 16
const VS := 1.0 / VPC
const Y0 := -2                 # the floor is two voxels thick, so grooves have a bottom
const WALL_TOP := 56           # 3.5 m
const DOOR_TOP := 48           # 3 m
const MERLON := 5
const PLINTH := 6              # base course, standing one voxel proud of the wall
const COPING := 2              # cap course, overhanging one voxel
const COURSE := 5              # 4 rows of stone + 1 of mortar
const FULL := (1 << 63) - 1    # every usable bit (bit 63 stays clear: >> sign-extends)
const CHUNK := 8               # cells per chunk side

# palette (colour, noise amount)
const PAL := [
	["625a5c", 0.10], ["6e6566", 0.10], ["57504f", 0.10], ["756b66", 0.10], ["5e5450", 0.10], ["69605a", 0.10],  # 0-5 wall stone
	["4f5a3e", 0.14], ["5a6444", 0.14],                     # 6-7 mossy stone
	["3a3436", 0.05],                                       # 8 mortar (groove bottoms)
	["4d4648", 0.08], ["554d4e", 0.08],                     # 9-10 plinth
	["7a7174", 0.08], ["837a7b", 0.08],                     # 11-12 coping, wall tops
	["6e4a2e", 0.06], ["7a5434", 0.06], ["85603c", 0.06], ["674428", 0.06], ["8a6440", 0.06], ["5e3e24", 0.06],  # 13-18 planks
	["3a2616", 0.03], ["2a2a2e", 0.0],                      # 19 plank seam, 20 nail
	["4d474d", 0.06], ["544e53", 0.06], ["49434a", 0.06],   # 21-23 tile A
	["5c555a", 0.06], ["635b5f", 0.06], ["575055", 0.06],   # 24-26 tile B
	["2e2a2c", 0.04], ["3a3437", 0.04],                     # 27 grout, 28 crack
	["5a1e22", 0.07], ["4a171b", 0.07], ["b08a3c", 0.05],   # 29 carpet, 30 carpet dark, 31 gold
	["5d5753", 0.12], ["6a625b", 0.12], ["534e4c", 0.12], ["70675e", 0.12], ["625c56", 0.12], ["58524f", 0.12],  # 32-37 cobbles
	["2c2622", 0.06], ["4a5236", 0.12],                     # 38 cobble gap, 39 mossy cobble
	["3d3128", 0.10], ["463829", 0.10], ["4a3d30", 0.10], ["382c24", 0.10], ["2f2620", 0.06],  # 40-44 earth, mud
	["3d4a26", 0.10], ["53602e", 0.10], ["6b6340", 0.10],   # 45-47 grass dark, mid, dry tip
	["4e4a48", 0.12],                                       # 48 pebble
	["4f331f", 0.06], ["3a2414", 0.05], ["5a3a24", 0.06],   # 49 beam, 50 beam end, 51 beam light
	["4a4448", 0.08], ["3d2a1c", 0.06],                     # 52 door sill, 53 lintel timber
]
const P_STONE := 0
const P_MOSS := 6
const P_MORTAR := 8
const P_PLINTH := 9
const P_CAP := 11
const P_PLANK := 13
const P_SEAM := 19
const P_NAIL := 20
const P_TILE_A := 21
const P_TILE_B := 24
const P_GROUT := 27
const P_CRACK := 28
const P_CARPET := 29
const P_CARPET_DARK := 30
const P_GOLD := 31
const P_COBBLE := 32
const P_GAP := 38
const P_COBBLE_MOSS := 39
const P_EARTH := 40
const P_MUD := 44
const P_GRASS := 45
const P_PEBBLE := 48
const P_BEAM := 49
const P_BEAM_END := 50
const P_SILL := 52
const P_LINTEL := 53

# cell kinds
const FLOOR := 0
const WALL := 1
const DOOR := 2

# floor column decorations (raised voxels)
const DECO_NONE := 0
const DECO_RIM := 1      # plinth, coping and proud stones along a wall
const DECO_GRASS := 2
const DECO_PEBBLE := 3

var W := 0
var H := 0
var GX := 0
var GZ := 0
var cols := PackedInt64Array()
var kinds := PackedByteArray()       # per cell
var styles := PackedByteArray()      # per cell: floor style char code
var open_sides := PackedByteArray()  # per wall cell: 1 -x, 2 +x, 4 -z, 8 +z open to a room
var deco := PackedByteArray()        # per column
var rim_along := PackedInt32Array()  # per rim column: the brick coordinate of the wall behind it
var palette: Array[Color] = []
var _bitpos := {}
# pattern tables (built in setup, read by the meshing threads)
var _al := 0                          # span of the `along` coordinate
var _stone_in := PackedByteArray()    # [course * _al + along] -> palette (indoor walls)
var _stone_out := PackedByteArray()   # same, outdoor walls (moss low down)
var _stone_flag := PackedByteArray()  # 1 proud stone, 2 fallen-out stone
var _cobble_tab := PackedByteArray()  # [(gz / 6) * GX + gx] -> palette
var _plank_tab := PackedByteArray()   # [(gz / 4) * GX + gx] -> palette, +64 = nail column
var _face_layer := PackedByteArray()  # per column: 1 = a wall's outermost layer (stone, not mortar)
var _padded := PackedInt64Array()     # cols with a border of FULL columns, (GX + 2) wide


func _init() -> void:
	for p in PAL:
		var c := Color(p[0])
		palette.append(Color(c.r, c.g, c.b, p[1]))
	for k in 63:
		_bitpos[1 << k] = k


static func bits(y_from: int, y_to: int) -> int:
	if y_to <= y_from:
		return 0
	return ((1 << (y_to - Y0)) - 1) & ~((1 << (y_from - Y0)) - 1)


static func h3(a: int, b: int, c: int) -> int:
	var h := (a * 73856093) ^ (b * 19349663) ^ (c * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	return (h >> 16) & 0xffff


## layout: Array of strings; floor_style: Callable(x, y) -> String (one char)
## for every non-wall cell; door_letters: String of door cell letters.
func setup(layout: Array, floor_style: Callable, door_letters: String) -> void:
	H = layout.size()
	W = String(layout[0]).length()
	GX = W * VPC
	GZ = H * VPC
	kinds.resize(W * H)
	styles.resize(W * H)
	open_sides.resize(W * H)
	for cz in H:
		for cx in W:
			var ch: String = layout[cz][cx]
			var i := cz * W + cx
			kinds[i] = WALL if ch == "#" else (DOOR if door_letters.contains(ch) else FLOOR)
			styles[i] = floor_style.call(cx, cz).unicode_at(0) if kinds[i] != WALL else 0
	for cz in H:
		for cx in W:
			if kinds[cz * W + cx] != WALL:
				continue
			var o := 0
			if _kind(cx - 1, cz) != WALL: o |= 1
			if _kind(cx + 1, cz) != WALL: o |= 2
			if _kind(cx, cz - 1) != WALL: o |= 4
			if _kind(cx, cz + 1) != WALL: o |= 8
			open_sides[cz * W + cx] = o
	cols.resize(GX * GZ)
	deco.resize(GX * GZ)
	rim_along.resize(GX * GZ)
	_face_layer.resize(GX * GZ)
	_tables()
	_base_columns()
	_wall_relief()
	_floor_relief()
	_beams()
	_padded.resize((GX + 2) * (GZ + 2))
	_padded.fill(FULL)
	for gz in GZ:
		for gx in GX:
			_padded[(gz + 1) * (GX + 2) + gx + 1] = cols[gz * GX + gx]


func _kind(cx: int, cz: int) -> int:
	if cx < 0 or cz < 0 or cx >= W or cz >= H:
		return WALL
	return kinds[cz * W + cx]


func _col(gx: int, gz: int) -> int:
	if gx < 0 or gz < 0 or gx >= GX or gz >= GZ:
		return FULL
	return cols[gz * GX + gx]


func _base_columns() -> void:
	var floor_bits := bits(Y0, 0)
	var wall_bits := bits(Y0, WALL_TOP)
	var door_bits := floor_bits | bits(DOOR_TOP, WALL_TOP)
	var merlon_bits := bits(WALL_TOP, WALL_TOP + MERLON)
	for cz in H:
		for cx in W:
			var kind := kinds[cz * W + cx]
			var edge := cx == 0 or cz == 0 or cx == W - 1 or cz == H - 1
			for lz in VPC:
				var gz := cz * VPC + lz
				for lx in VPC:
					var gx := cx * VPC + lx
					var m := floor_bits
					if kind == WALL:
						m = wall_bits
						# crenellations along the outer half of the perimeter
						if edge:
							var outer := (cx == 0 and lx < 8) or (cx == W - 1 and lx >= 8) \
									or (cz == 0 and lz < 8) or (cz == H - 1 and lz >= 8)
							var along := gx if (cz == 0 or cz == H - 1) else gz
							if outer and (along / 8) % 2 == 0:
								m |= merlon_bits
					elif kind == DOOR:
						m = door_bits
					cols[gz * GX + gx] = m


## The stone pattern on a wall face: returns block id (>= 0) or -1 for
## mortar. `along` runs along the face, y is the voxel layer.
static func brick(along: int, y: int) -> int:
	var c := (y - PLINTH) / COURSE
	if (y - PLINTH) % COURSE == COURSE - 1:
		return -1
	var t := along + (c * 7) % 12 + 1200
	var k := t / 12
	var b0 := k * 12 + h3(k, c, 3) % 5 - 2
	if t < b0:
		k -= 1
		b0 = k * 12 + h3(k, c, 3) % 5 - 2
	else:
		var b1 := (k + 1) * 12 + h3(k + 1, c, 3) % 5 - 2
		if t >= b1:
			k += 1
			b0 = b1
	if t == b0:
		return -1
	return (k & 0xffff) | (c << 16)


func _stone_color(block: int, outdoor: bool) -> int:
	var hh := h3(block & 0xffff, block >> 16, 17)
	if outdoor and (block >> 16) <= 1 and hh % 3 == 0:
		return P_MOSS + hh % 2
	return P_STONE + hh % 6


## Precompute the stone, cobble and plank patterns so meshing threads only
## look colours up.
func _tables() -> void:
	_al = GX + GZ
	var courses := (WALL_TOP - COPING - PLINTH + COURSE - 1) / COURSE
	_stone_in.resize(courses * _al)
	_stone_out.resize(courses * _al)
	_stone_flag.resize(courses * _al)
	for c in courses:
		var y := PLINTH + c * COURSE
		for a in _al:
			var b := brick(a, y)
			var i := c * _al + a
			if b < 0:
				_stone_in[i] = P_MORTAR
				_stone_out[i] = P_MORTAR
				continue
			_stone_in[i] = _stone_color(b, false)
			_stone_out[i] = _stone_color(b, true)
			var hh := h3(b & 0xffff, b >> 16, 29)
			_stone_flag[i] = 1 if hh % 29 == 0 else (2 if hh % 37 == 1 else 0)
	var rows := GZ / 6 + 1
	_cobble_tab.resize(rows * GX)
	for r in rows:
		for gx in GX:
			var st := _cobble(gx, r * 6)
			var v := P_GAP
			if st >= 0:
				var hh := h3(st & 0xffff, st >> 16, 31)
				v = P_COBBLE_MOSS if hh % 13 == 0 else P_COBBLE + hh % 6
			_cobble_tab[r * GX + gx] = v
	var prows := GZ / 4 + 1
	_plank_tab.resize(prows * GX)
	for r in prows:
		var plen := 32 + (r % 3) * 8
		var off := h3(r, 0, 7) % plen
		for gx in GX:
			var t := gx + off
			var v := P_PLANK + h3(t / plen, r, 13) % 6
			if t % plen == 0:
				v = P_SEAM
			elif t % plen == 2:
				v += 64
			_plank_tab[r * GX + gx] = v


## Grooves between the stones, a few proud or missing stones, a plinth along
## the floor and a coping under the top, on every wall face that looks into
## a room.
func _wall_relief() -> void:
	var dirs := [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]
	var plinth_bits := bits(0, PLINTH)
	var coping_bits := bits(WALL_TOP - COPING, WALL_TOP)
	for cz in H:
		for cx in W:
			var o := open_sides[cz * W + cx]
			if kinds[cz * W + cx] != WALL or o == 0:
				continue
			for d in 4:
				if o & (1 << d) == 0:
					continue
				var dir: Vector2i = dirs[d]
				var room_kind := _kind(cx + dir.x, cz + dir.y)
				for k in VPC:
					# surface column (depth 0) and the room column in front of it
					var sx: int
					var sz: int
					if dir.x != 0:
						sx = cx * VPC + (0 if dir.x < 0 else VPC - 1)
						sz = cz * VPC + k
					else:
						sx = cx * VPC + k
						sz = cz * VPC + (0 if dir.y < 0 else VPC - 1)
					var rx := sx + dir.x
					var rz := sz + dir.y
					var along := sx + sz
					var si := sz * GX + sx
					var ri := rz * GX + rx
					_face_layer[si] = 1
					var surf := cols[si]
					var room := cols[ri]
					var proud := 0
					for y in range(PLINTH, WALL_TOP - COPING):
						var r := y - PLINTH
						if r % COURSE == COURSE - 1:
							surf &= ~(1 << (y - Y0))     # bed joint: a groove
							continue
						# head joints are drawn, not carved
						var flag := _stone_flag[(r / COURSE) * _al + along]
						if flag == 1 and room_kind == FLOOR and y < DOOR_TOP - 4:
							proud |= 1 << (y - Y0)
						elif flag == 2:
							surf &= ~(1 << (y - Y0))     # a stone fallen out
					cols[si] = surf
					if room_kind == FLOOR:
						cols[ri] = room | plinth_bits | coping_bits | proud
						deco[ri] = DECO_RIM
						rim_along[ri] = along
	# outer corners: carry the plinth and coping round the corner column
	for cz in H:
		for cx in W:
			if kinds[cz * W + cx] != WALL:
				continue
			for dz in [-1, 1]:
				for dx in [-1, 1]:
					if _kind(cx + dx, cz) == WALL or _kind(cx, cz + dz) == WALL or _kind(cx + dx, cz + dz) != FLOOR:
						continue
					var gx := cx * VPC + (-1 if dx < 0 else VPC)
					var gz := cz * VPC + (-1 if dz < 0 else VPC)
					var i := gz * GX + gx
					cols[i] |= plinth_bits | coping_bits
					deco[i] = DECO_RIM
					rim_along[i] = gx + gz


## Floors: grout between the hall's tiles and the courtyard's cobbles, grass
## tufts and pebbles in the garden. Plank floors stay flat.
func _floor_relief() -> void:
	var top := 1 << (-1 - Y0)
	for cz in H:
		for cx in W:
			var kind := kinds[cz * W + cx]
			if kind != FLOOR:
				continue
			var style := styles[cz * W + cx]
			for lz in VPC:
				var gz := cz * VPC + lz
				for lx in VPC:
					var gx := cx * VPC + lx
					var i := gz * GX + gx
					if deco[i] == DECO_RIM:
						continue
					match style:
						59:   # ';' hall tiles
							if not _carpet(cx, cz) and (lx == 0 or lz == 0):
								cols[i] &= ~top
						46:   # '.' cobbles
							if gz % 6 == 5 or _cobble_tab[(gz / 6) * GX + gx] == P_GAP:
								cols[i] &= ~top
						58:   # ':' earth
							var hh := h3(gx, gz, 5)
							if hh % 400 == 0:
								cols[i] |= bits(0, 1)
								deco[i] = DECO_PEBBLE
	# grass tufts: a few blades around scattered centres
	for cz in H:
		for cx in W:
			if kinds[cz * W + cx] != FLOOR or styles[cz * W + cx] != 58:
				continue
			var hh := h3(cx, cz, 40)
			if hh % 5 >= 2:
				continue
			var ox := cx * VPC + 3 + hh % 10
			var oz := cz * VPC + 3 + (hh >> 4) % 10
			for blade in 4 + hh % 4:
				var bh := h3(ox, oz, blade)
				var gx := ox + bh % 5 - 2
				var gz := oz + (bh >> 3) % 5 - 2
				var i := gz * GX + gx
				if deco[i] == DECO_RIM:
					continue
				cols[i] |= bits(0, 1 + (bh >> 6) % 3)
				deco[i] = DECO_GRASS


func _carpet(cx: int, cz: int) -> bool:
	return cz >= 6 and cz <= 7 and cx >= 20


## Cobble pattern: stone id (>= 0) or -1 for the gaps between stones.
static func _cobble(gx: int, gz: int) -> int:
	var row := gz / 6
	if gz % 6 == 5:
		return -1
	var t := gx + h3(row, 0, 9) % 7 + 700
	var k := t / 7
	var b0 := k * 7 + h3(k, row, 11) % 3 - 1
	if t < b0:
		k -= 1
		b0 = k * 7 + h3(k, row, 11) % 3 - 1
	if t == b0:
		return -1
	return (k & 0xffff) | (row << 16)


## Timber beams across the barracks and the great hall.
func _beams() -> void:
	for cxb in range(1, 19, 4):
		for gz in range(1 * VPC, 13 * VPC):
			for lx in range(6, 10):
				var gx := cxb * VPC + lx
				cols[gz * GX + gx] |= bits(48, 52)
	for czb in range(2, 13, 3):
		for gx in range(20 * VPC, 39 * VPC):
			for lz in range(6, 10):
				var gz := czb * VPC + lz
				cols[gz * GX + gx] |= bits(52, 56)


## Palette index for the face of voxel (gx, gy, gz) looking along `n`
## (0 +x, 1 -x, 2 +y, 3 -y, 4 +z, 5 -z).
func _color(gx: int, gy: int, gz: int, n: int) -> int:
	var cx := gx / VPC
	var cz := gz / VPC
	var ci := cz * W + cx
	var kind := kinds[ci]
	if kind == WALL:
		if gy >= WALL_TOP - 1 and (n == 2 or gy >= WALL_TOP):
			return P_CAP + (gx / 8 + gz / 8) % 2
		if n == 2 or n == 3:
			# tops and bottoms of the stones inside a groove
			return _stone(gx + gz, gy + (1 if n == 3 else -1), cz > 13)
		if _face_layer[gz * GX + gx] == 0:
			return P_MORTAR   # deeper in: the back of a groove or a fallen stone's hole
		return _stone(gx + gz, gy, cz > 13)
	if kind == DOOR:
		return P_LINTEL if gy >= DOOR_TOP else P_SILL
	# floor cells
	if gy >= 48:
		var end := (gz < 1 * VPC + 4 or gz >= 13 * VPC - 4) if cx < 19 else (gx < 20 * VPC + 4 or gx >= 39 * VPC - 4)
		return P_BEAM_END if end else P_BEAM + (2 if n == 2 else 0)
	var i := gz * GX + gx
	if gy >= 0:
		match deco[i]:
			DECO_RIM:
				return _stone(rim_along[i], gy, cz > 13)
			DECO_GRASS:
				return P_GRASS + mini(gy, 2)
			_:
				return P_PEBBLE
	match styles[ci]:
		59:   # hall tiles and the carpet runner
			if _carpet(cx, cz):
				var e := gz - 6 * VPC
				if e <= 0 or e >= 2 * VPC - 1:
					return P_CARPET_DARK
				if e == 2 or e == 2 * VPC - 3:
					return P_GOLD
				var m := absi((gx % 16) - 8) + absi(e - VPC)
				return P_GOLD if m == 6 else (P_CARPET_DARK if m < 3 else P_CARPET)
			if gy == -2:
				return P_GROUT
			var hh := h3(cx, cz, 21)
			var lx := gx - cx * VPC
			if hh % 7 == 0 and lx == gz - cz * VPC and lx > 3 and lx < 12:
				return P_CRACK
			return (P_TILE_A if (cx + cz) % 2 == 0 else P_TILE_B) + hh % 3
		46:   # courtyard cobbles
			if gy == -2 or gz % 6 == 5:
				return P_GAP
			return _cobble_tab[(gz / 6) * GX + gx]
		58:   # garden earth
			var hh := h3(gx / 8 + (gz / 8) % 2 * 3, gz / 8, 41)
			return P_MUD if hh % 11 == 0 else P_EARTH + hh % 4
		_:    # barracks planks (and anything else)
			if gz % 4 == 0:
				return P_SEAM
			var v := _plank_tab[(gz / 4) * GX + gx]
			if v >= 64:
				return P_NAIL if gz % 4 != 2 else v - 64
			return v


## A wall stone's colour at layer y: plinth, mortar, stone or coping.
func _stone(along: int, y: int, outdoor: bool) -> int:
	if y < PLINTH:
		return P_PLINTH + (along / 12) % 2
	if y >= WALL_TOP - COPING:
		return P_CAP
	var r := y - PLINTH
	if r % COURSE == COURSE - 1:
		return P_MORTAR
	var i := (r / COURSE) * _al + along
	return _stone_out[i] if outdoor else _stone_in[i]


func chunk_count() -> int:
	return _chunks_x() * _chunks_z()


func _chunks_x() -> int:
	return (W + CHUNK - 1) / CHUNK


func _chunks_z() -> int:
	return (H + CHUNK - 1) / CHUNK


## Mesh arrays ([plain, glowing]) for chunk `index`, in world space. Safe to
## call from several threads at once once setup() has finished.
##
## For each column and face direction, the eight voxels around each face's
## front neighbour are gathered as whole-column bit masks shifted so bit b
## lines up with the face at layer b; most faces touch none of them and skip
## the per-corner occlusion maths entirely.
func mesh_chunk(index: int) -> Array:
	var x0 := (index % _chunks_x()) * CHUNK * VPC
	var z0 := (index / _chunks_x()) * CHUNK * VPC
	var x1 := mini(x0 + CHUNK * VPC, GX)
	var z1 := mini(z0 + CHUNK * VPC, GZ)
	var keys: Array[PackedInt64Array] = []
	for fi in 6:
		keys.append(PackedInt64Array())
	var pw := GX + 2
	var floor_m := bits(Y0, 0)
	var top_slot := (-1 - Y0) << 48     # layer of a flat floor's top face, as a +y key
	for gz in range(z0, z1):
		var pi := (gz + 1) * pw + x0
		for gx in range(x0, x1):
			pi += 1
			var m := _padded[pi]
			if m == 0:
				continue
			var c_xm := _padded[pi - 1]
			var c_xp := _padded[pi + 1]
			var c_zm := _padded[pi - pw]
			var c_zp := _padded[pi + pw]
			var c_mm := _padded[pi - pw - 1]
			var c_pm := _padded[pi - pw + 1]
			var c_mp := _padded[pi + pw - 1]
			var c_pp := _padded[pi + pw + 1]
			if m == floor_m and (c_xm & c_xp & c_zm & c_zp & 2) != 0 \
					and ((c_xm | c_xp | c_zm | c_zp | c_mm | c_pm | c_mp | c_pp) >> 2) == 0:
				# flat floor with flat floor all round: one plain top face
				keys[2].append(top_slot | (gx - x0) << 36 | (gz - z0) << 24 | _color(gx, -1, gz, 2) << 9 | 255)
				continue
			var f_xp := m & ~c_xp
			var f_xm := m & ~c_xm
			var f_yp := m & ~(m >> 1)
			var f_ym := m & ~(m << 1) & ~1
			var f_zp := m & ~c_zp
			var f_zm := m & ~c_zm
			if (f_xp | f_xm | f_yp | f_ym | f_zp | f_zm) == 0:
				continue
			var rx := gx - x0
			var rz := gz - z0
			if kinds[(gz / VPC) * W + gx / VPC] == WALL:
				f_yp &= ~(1 << (WALL_TOP - 1 - Y0))   # wall tops: one quad per cell, below
			for fi in 6:
				var e: int
				# neighbour masks: -u, +u, -v, +v, -u-v, +u-v, +u+v, -u+v
				var mu: int; var pu: int; var mv: int; var pv: int
				var dmm: int; var dpm: int; var dpp: int; var dmp: int
				match fi:
					0:
						e = f_xp
						if e == 0: continue
						mu = c_xp << 1 | 1; pu = c_xp >> 1; mv = c_pm; pv = c_pp
						dmm = c_pm << 1 | 1; dpm = c_pm >> 1; dpp = c_pp >> 1; dmp = c_pp << 1 | 1
					1:
						e = f_xm
						if e == 0: continue
						mu = c_mm; pu = c_mp; mv = c_xm << 1 | 1; pv = c_xm >> 1
						dmm = c_mm << 1 | 1; dpm = c_mp << 1 | 1; dpp = c_mp >> 1; dmp = c_mm >> 1
					2:
						e = f_yp
						mu = c_zm >> 1; pu = c_zp >> 1; mv = c_xm >> 1; pv = c_xp >> 1
						dmm = c_mm >> 1; dpm = c_mp >> 1; dpp = c_pp >> 1; dmp = c_pm >> 1
					3:
						e = f_ym
						if e == 0: continue
						mu = c_xm << 1 | 1; pu = c_xp << 1 | 1; mv = c_zm << 1 | 1; pv = c_zp << 1 | 1
						dmm = c_mm << 1 | 1; dpm = c_pm << 1 | 1; dpp = c_pp << 1 | 1; dmp = c_mp << 1 | 1
					4:
						e = f_zp
						if e == 0: continue
						mu = c_mp; pu = c_pp; mv = c_zp << 1 | 1; pv = c_zp >> 1
						dmm = c_mp << 1 | 1; dpm = c_pp << 1 | 1; dpp = c_pp >> 1; dmp = c_mp >> 1
					_:
						e = f_zm
						if e == 0: continue
						mu = c_zm << 1 | 1; pu = c_zm >> 1; mv = c_mm; pv = c_pm
						dmm = c_mm << 1 | 1; dpm = c_mm >> 1; dpp = c_pm >> 1; dmp = c_pm << 1 | 1
				var occl := mu | pu | mv | pv | dmm | dpm | dpp | dmp
				var target: PackedInt64Array = keys[fi]
				# key = plane << 48 | v << 36 | u << 24 | sig; the layer goes in
				# whichever slot is y for this direction
				var base: int
				var shift: int
				match fi:
					0: base = rx << 48 | rz << 36; shift = 24
					1: base = rx << 48 | rz << 24; shift = 36
					2: base = rx << 36 | rz << 24; shift = 48
					3: base = rz << 36 | rx << 24; shift = 48
					4: base = rz << 48 | rx << 24; shift = 36
					_: base = rz << 48 | rx << 36; shift = 24
				while e != 0:
					var low := e & -e
					e ^= low
					var b: int = _bitpos[low]
					var aos := 255
					if occl & low:
						var a_mu := (mu >> b) & 1
						var a_pu := (pu >> b) & 1
						var a_mv := (mv >> b) & 1
						var a_pv := (pv >> b) & 1
						var ao0 := 0 if a_mu + a_mv == 2 else 3 - a_mu - a_mv - ((dmm >> b) & 1)
						var ao1 := 0 if a_pu + a_mv == 2 else 3 - a_pu - a_mv - ((dpm >> b) & 1)
						var ao2 := 0 if a_pu + a_pv == 2 else 3 - a_pu - a_pv - ((dpp >> b) & 1)
						var ao3 := 0 if a_mu + a_pv == 2 else 3 - a_mu - a_pv - ((dmp >> b) & 1)
						aos = ao0 << 6 | ao1 << 4 | ao2 << 2 | ao3
					target.append(base | b << shift | _color(gx, b + Y0, gz, fi) << 9 | aos)
				keys[fi] = target
	var surf := [VB._new_arrays(), VB._new_arrays()]
	for cz in range(z0 / VPC, (z1 + VPC - 1) / VPC):
		for cx in range(x0 / VPC, (x1 + VPC - 1) / VPC):
			if kinds[cz * W + cx] == WALL:
				var cap: Color = palette[P_CAP + (cx + cz) % 2]
				var lin := Color(cap.r, cap.g, cap.b).srgb_to_linear()
				lin.a = cap.a
				VB._quad(surf[0], Vector3i(cx * VPC, WALL_TOP - 1, cz * VPC), VB.FACES[2], VPC, VPC, lin, [3, 3, 3, 3], VS, Vector3.ZERO)
	var lo := Vector3i(x0, Y0, z0)
	for fi in 6:
		var k: PackedInt64Array = keys[fi]
		if k.is_empty():
			continue
		k.sort()
		VB._merge(k, fi, lo, palette, surf, VS, Vector3.ZERO)
	return surf
