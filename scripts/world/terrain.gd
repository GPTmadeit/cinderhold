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
## Voxels per metre for meshing (maps built on this class may use fewer).
var vpc := VPC
var vs := VS
## Palette entries from here on glow (lit glass, signs).
var glow_from := 1 << 14
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
## Carve the voxel-sized relief (mortar grooves, tile grout, cobble gaps,
## grass). The rounded mesher (smooth_chunk) leaves it to the shader instead.
var carve := true


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
						if not carve:
							break
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
	if not carve:
		return
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
	return (GX / vpc + CHUNK - 1) / CHUNK


func _chunks_z() -> int:
	return (GZ / vpc + CHUNK - 1) / CHUNK


## Which +y faces of this column the per-cell caps (below) replace.
func _capped_bits(gx: int, gz: int) -> int:
	return 1 << (WALL_TOP - 1 - Y0) if kinds[(gz / VPC) * W + gx / VPC] == WALL else 0


## Faces drawn whole rather than voxel by voxel: one quad per wall cell top.
func _caps(surf: Array, x0: int, z0: int, x1: int, z1: int) -> void:
	for cz in range(z0 / VPC, (z1 + VPC - 1) / VPC):
		for cx in range(x0 / VPC, (x1 + VPC - 1) / VPC):
			if kinds[cz * W + cx] == WALL:
				var cap: Color = palette[P_CAP + (cx + cz) % 2]
				var lin := Color(cap.r, cap.g, cap.b).srgb_to_linear()
				lin.a = cap.a
				VB._quad(surf[0], Vector3i(cx * VPC, WALL_TOP - 1, cz * VPC), VB.FACES[2], VPC, VPC, lin, [3, 3, 3, 3], VS, Vector3.ZERO)


## Mesh arrays ([plain, glowing]) for chunk `index`, in world space. Safe to
## call from several threads at once once setup() has finished.
##
## For each column and face direction, the eight voxels around each face's
## front neighbour are gathered as whole-column bit masks shifted so bit b
## lines up with the face at layer b; most faces touch none of them and skip
## the per-corner occlusion maths entirely.
func mesh_chunk(index: int) -> Array:
	var x0 := (index % _chunks_x()) * CHUNK * vpc
	var z0 := (index / _chunks_x()) * CHUNK * vpc
	var x1 := mini(x0 + CHUNK * vpc, GX)
	var z1 := mini(z0 + CHUNK * vpc, GZ)
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
				var top := _color(gx, -1, gz, 2)
				keys[2].append(top_slot | (gx - x0) << 36 | (gz - z0) << 24 | top << 9 | int(top >= glow_from) << 8 | 255)
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
			f_yp &= ~_capped_bits(gx, gz)   # drawn whole by _caps()
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
					var col := _color(gx, b + Y0, gz, fi)
					target.append(base | b << shift | col << 9 | int(col >= glow_from) << 8 | aos)
				keys[fi] = target
	var surf := [VB._new_arrays(), VB._new_arrays()]
	_caps(surf, x0, z0, x1, z1)
	var lo := Vector3i(x0, Y0, z0)
	for fi in 6:
		var k: PackedInt64Array = keys[fi]
		if k.is_empty():
			continue
		k.sort()
		VB._merge(k, fi, lo, palette, surf, vs, Vector3.ZERO)
	return surf


# =========================================================================
# Rounded meshing
# =========================================================================

## Surfaces of the rounded terrain. Vertex alpha carries id / 32; the stone,
## tile, cobble and plank patterns are drawn by shaders/terrain.gdshader.
const M_STONE := 0
const M_STONE_OUT := 1
const M_PLINTH := 2
const M_CAP := 3
const M_TILE := 4
const M_CARPET := 5
const M_COBBLE := 6
const M_EARTH := 7
const M_PLANK := 8
const M_BEAM := 9
const M_SILL := 10
const M_LINTEL := 11
const M_COUNT := 12
const LS := 2               # fine voxels per lattice cell
const SMOOTH_PASSES := 4    # Taubin passes (λ, μ alternating)
const MARGIN := 6           # lattice cells meshed around a chunk so seams agree
const POP2 := [0, 1, 1, 2]


## Mesh arrays for chunk `index` as a rounded surface (world space).
##
## The columns are resampled on a lattice of LS fine voxels (a cell is solid
## when at least half of it is), every exposed lattice face becomes a quad,
## and the quads' corners are relaxed with Taubin smoothing, which rounds
## edges and corners while flat faces stay exactly flat. Quads that didn't
## move (and aren't in a crease's shade) are merged back into big quads with
## the voxel builder's greedy merge, so open floors and wall faces stay cheap.
## The chunk is meshed with a margin of neighbouring cells, so the smoothing
## sees the same neighbourhood on both sides of a seam.
func smooth_chunk(index: int) -> Dictionary:
	var span := CHUNK * vpc / LS
	var cx0 := (index % _chunks_x()) * span
	var cz0 := (index / _chunks_x()) * span
	var cx1 := mini(cx0 + span, GX / LS)
	var cz1 := mini(cz0 + span, GZ / LS)
	var ox := cx0 - MARGIN
	var oz := cz0 - MARGIN
	var nx := cx1 - cx0 + 2 * MARGIN
	var nz := cz1 - cz0 + 2 * MARGIN
	# lattice columns: bit b is layer b - 1 (fine y Y0 + 2(b - 1)); bit 0 is solid ground
	var lat := PackedInt64Array()
	lat.resize(nx * nz)
	for z in nz:
		for x in nx:
			var gx := (ox + x) * LS
			var gz := (oz + z) * LS
			var a := _col(gx, gz)
			var b := _col(gx + 1, gz)
			var c := _col(gx, gz + 1)
			var d := _col(gx + 1, gz + 1)
			var m := 1
			var any := a | b | c | d
			for j in 32:
				var sh := 2 * j
				if (any >> sh) & 3 == 0:
					continue
				var cnt: int = POP2[(a >> sh) & 3] + POP2[(b >> sh) & 3] + POP2[(c >> sh) & 3] + POP2[(d >> sh) & 3]
				if cnt >= 4:
					m |= 1 << (j + 1)
			lat[z * nx + x] = m
	# --- lattice faces, corners shared ---
	var ny := 35
	var lnx := nx + 1
	var lnxy := lnx * (ny + 1)
	var vid := PackedInt32Array()
	vid.resize(lnxy * (nz + 1))
	vid.fill(-1)
	var pos := PackedVector3Array()
	var quads := PackedInt32Array()      # 4 corner ids per quad
	var qinfo := PackedInt32Array()      # per quad: fi | mat << 3 | inside << 8, then the cell x, b, z
	for z in range(1, nz - 1):
		for x in range(1, nx - 1):
			var i := z * nx + x
			var m := lat[i]
			var fm := [m & ~lat[i + 1], m & ~lat[i - 1], m & ~(m >> 1), m & ~(m << 1) & ~1, m & ~lat[i + nx], m & ~lat[i - nx]]
			var inside := int(x >= MARGIN and z >= MARGIN and x < nx - MARGIN and z < nz - MARGIN)
			for fi in 6:
				var e: int = fm[fi]
				if fi == 2:
					e &= ~(1 << 33)
				while e != 0:
					var low := e & -e
					e ^= low
					var b: int = _bitpos[low]
					var f: Array = VB.FACES[fi]
					var nn: Vector3i = f[0]
					var u: Vector3i = f[1]
					var v: Vector3i = f[2]
					var base := Vector3i(x, b, z)
					if nn.x + nn.y + nn.z > 0:
						base += nn
					for k in 4:
						var lp: Vector3i = base + (u if k == 1 or k == 2 else Vector3i.ZERO) + (v if k >= 2 else Vector3i.ZERO)
						var li := lp.x + lp.y * lnx + lp.z * lnxy
						if vid[li] == -1:
							vid[li] = pos.size()
							pos.append(Vector3(lp))
						quads.append(vid[li])
					var mat := _smooth_material((ox + x) * LS, Y0 + 2 * (b - 1), (oz + z) * LS, fi)
					qinfo.append_array([fi | mat << 3 | inside << 8, x, b, z])
	var nv := pos.size()
	var nq := quads.size() / 4
	var surf := [VB._new_arrays(), VB._new_arrays()]
	if nq == 0:
		return surf[0]
	# --- Taubin smoothing over the quad edges ---
	var orig := pos.duplicate()
	var acc := PackedVector3Array()
	acc.resize(nv)
	var cnt := PackedFloat32Array()
	cnt.resize(nv)
	for pass_i in SMOOTH_PASSES:
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
		var lam := 0.55 if pass_i % 2 == 0 else -0.5
		for vi in nv:
			pos[vi] += (acc[vi] / cnt[vi] - pos[vi]) * lam
	# --- normals, then occlusion from the lattice ---
	var nrm := PackedVector3Array()
	nrm.resize(nv)
	for q in nq:
		var o := q * 4
		var p0 := pos[quads[o]]
		var fn := (pos[quads[o + 1]] - p0).cross(pos[quads[o + 2]] - p0) + (pos[quads[o + 2]] - p0).cross(pos[quads[o + 3]] - p0)
		for k in 4:
			nrm[quads[o + k]] += fn
	var ao := PackedFloat32Array()
	ao.resize(nv)
	for vi in nv:
		nrm[vi] = nrm[vi].normalized()
		var s := pos[vi] + nrm[vi] * 0.9
		ao[vi] = clampf(1.35 - 1.7 * _lat_sample(lat, nx, nz, s), 0.4, 1.0)
	# --- emit: untouched quads merge, the rest go out as they are ---
	var pivot := Vector3(0, 1 - Y0 / 2.0, 0)
	var scale := LS * vs
	var shift := Vector3(ox, 0, oz)
	var keys: Array[PackedInt64Array] = []
	for fi in 6:
		keys.append(PackedInt64Array())
	var target: Dictionary = surf[0]
	for q in nq:
		var info := qinfo[q * 4]
		if info >> 8 == 0:
			continue
		var fi := info & 7
		var mat := (info >> 3) & 31
		var o := q * 4
		var fnv := Vector3(VB.FACES[fi][0])
		var flat := true
		for k in 4:
			var vi := quads[o + k]
			if pos[vi].distance_squared_to(orig[vi]) > 1e-4 or nrm[vi].dot(fnv) < 0.9995 or ao[vi] < 0.999:
				flat = false
				break
		if flat:
			var cell := Vector3i(qinfo[q * 4 + 1], qinfo[q * 4 + 2], qinfo[q * 4 + 3])
			var f: Array = VB.FACES[fi]
			var plane: int = cell[VB._axis(f[0])]
			var u: int = cell[VB._axis(f[1])]
			var v: int = cell[VB._axis(f[2])]
			keys[fi].append(plane << 48 | v << 36 | u << 24 | mat << 9 | 255)
			continue
		var start: int = target.v.size()
		for k in 4:
			var vi := quads[o + k]
			target.v.append((pos[vi] + shift - pivot) * scale)
			target.n.append(nrm[vi])
			target.c.append(Color(ao[vi], ao[vi], ao[vi], (mat + 0.5) / 32.0))
		# split along the shorter diagonal so rounded edges stay convex
		if pos[quads[o]].distance_squared_to(pos[quads[o + 2]]) <= pos[quads[o + 1]].distance_squared_to(pos[quads[o + 3]]):
			target.i.append_array([start, start + 2, start + 1, start, start + 3, start + 2])
		else:
			target.i.append_array([start, start + 3, start + 1, start + 1, start + 3, start + 2])
	var colors: Array[Color] = []
	for mi in M_COUNT:
		colors.append(Color(1, 1, 1, (mi + 0.5) / 32.0))
	for fi in 6:
		if keys[fi].is_empty():
			continue
		keys[fi].sort()
		VB._merge(keys[fi], fi, Vector3i(ox, 0, oz), colors, surf, scale, pivot)
	return surf[0]


## Lattice occupancy at a lattice-space point (cell centres at +0.5), trilinear.
func _lat_sample(lat: PackedInt64Array, nx: int, nz: int, p: Vector3) -> float:
	var u := p - Vector3(0.5, 0.5, 0.5)
	var x0 := floori(u.x)
	var y0 := floori(u.y)
	var z0 := floori(u.z)
	var t := u - Vector3(x0, y0, z0)
	var sum := 0.0
	for dz in 2:
		for dx in 2:
			var x := x0 + dx
			var z := z0 + dz
			if x < 0 or z < 0 or x >= nx or z >= nz:
				continue
			var m := lat[z * nx + x]
			var w := (t.x if dx else 1.0 - t.x) * (t.z if dz else 1.0 - t.z)
			for dy in 2:
				var y := y0 + dy
				if y >= 0 and y < 63 and (m >> y) & 1:
					sum += w * (t.y if dy else 1.0 - t.y)
	return sum


## The surface a lattice cell at fine (gx, gy, gz) shows on face `fi`.
func _smooth_material(gx: int, gy: int, gz: int, fi: int) -> int:
	var cx := clampi(gx / VPC, 0, W - 1)
	var cz := clampi(gz / VPC, 0, H - 1)
	var ci := cz * W + cx
	match kinds[ci]:
		WALL:
			if gy >= WALL_TOP - COPING or fi == 2:
				return M_CAP
			if gy < PLINTH:
				return M_PLINTH
			return M_STONE_OUT if cz > 13 else M_STONE
		DOOR:
			return M_LINTEL if gy >= DOOR_TOP else M_SILL
	if gy >= 48:
		return M_BEAM
	if gy >= 0:
		return M_PLINTH if gy < PLINTH else M_CAP
	match styles[ci]:
		59:
			return M_CARPET if _carpet(cx, cz) else M_TILE
		46:
			return M_COBBLE
		58:
			return M_EARTH
	return M_PLANK
