extends RefCounted
## Times Square, from Manhattan's real streets and buildings (OpenStreetMap,
## see times_square_data.gd): 42nd to 47th Street around the bowtie where
## Broadway crosses 7th Avenue, at one fifth of real size (heights shrink
## less, so the streets stay canyons). Players hold the square between 44th
## and 45th; barricades open the north end (Duffy Square), the south end
## (One Times Square) and the side streets. Map data (c) OpenStreetMap
## contributors, ODbL.
##
## Grid legend (1 m cells): # building, . street, X rubble at the map edge,
## S spawn, A-F barricades.

const D := preload("res://scripts/world/maps/times_square_data.gd")
const WorldScript := preload("res://scripts/world/maps/times_square_world.gd")

const ID := "times_square"
const TITLE := "Times Square"
## shown wherever the map is (the data's licence asks for it)
const ATTRIBUTION := "Map data © OpenStreetMap contributors, ODbL (openstreetmap.org/copyright)"
const WALKABLE := ".S"
const FLOOR_CHARS := "."
const VENT_QUOTA := {"square": 2, "north": 1, "south": 1, "streets": 1}

const DOORS := {
	"A": {"cost": 1000, "name": "Duffy Square Barricade"},
	"B": {"cost": 1000, "name": "43rd Street Barricade"},
	"C": {"cost": 750, "name": "West 45th Barricade"},
	"D": {"cost": 750, "name": "East 45th Barricade"},
	"E": {"cost": 750, "name": "West 44th Barricade"},
	"F": {"cost": 750, "name": "East 44th Barricade"},
}

## [letter, x0, y0, x1, y1]: where each barricade stands
const BARRICADES := [
	["A", 11, 32, 20, 32], ["B", 15, 52, 23, 52],
	["C", 10, 33, 10, 35], ["D", 25, 33, 25, 35],
	["E", 12, 49, 12, 51], ["F", 25, 48, 25, 51],
]

const PLACEMENTS := [
	{"kind": "wallbuy", "key": "kestrel", "cell": Vector2i(14, 40), "face": Vector3.RIGHT},
	{"kind": "wallbuy", "key": "tinder", "cell": Vector2i(22, 41), "face": Vector3.LEFT},
	{"kind": "wallbuy", "key": "warden", "cell": Vector2i(7, 12), "face": Vector3.RIGHT},
	{"kind": "wallbuy", "key": "breacher", "cell": Vector2i(25, 58), "face": Vector3.LEFT},
	{"kind": "tonic", "key": "ironhide", "cell": Vector2i(15, 46), "face": Vector3.RIGHT},
	{"kind": "tonic", "key": "quickhands", "cell": Vector2i(20, 22), "face": Vector3.LEFT},
	{"kind": "tonic", "key": "fleetfoot", "cell": Vector2i(30, 33), "face": Vector3.BACK},
	{"kind": "tonic", "key": "secondwind", "cell": Vector2i(15, 70), "face": Vector3.RIGHT},
	{"kind": "forge", "key": "forge", "cell": Vector2i(9, 13), "face": Vector3.BACK},
	{"kind": "cache", "key": "cache", "cell": Vector2i(16, 76), "face": Vector3.BACK},
]

const SPAWNS := [Vector2i(17, 42), Vector2i(18, 42), Vector2i(17, 43), Vector2i(18, 43)]

var LAYOUT: Array = []
var world: RefCounted     # the builder for the look (times_square_world.gd)


func _init() -> void:
	var rows: Array = []
	for r in D.LAYOUT:
		rows.append(r.to_ascii_buffer())
	var w: int = D.W
	var h: int = D.H
	var dot := ".".unicode_at(0)
	# the streets run off the edge of the map: rubble closes them
	for y in h:
		for x in w:
			if (x == 0 or y == 0 or x == w - 1 or y == h - 1) and rows[y][x] == dot:
				rows[y][x] = "X".unicode_at(0)
	for b in BARRICADES:
		for y in range(b[2], b[4] + 1):
			for x in range(b[1], b[3] + 1):
				rows[y][x] = String(b[0]).unicode_at(0)
	for s in SPAWNS:
		rows[s.y][s.x] = "S".unicode_at(0)
	# the red steps stand on the plaza
	var steps: Rect2 = D.TKTS
	for y in range(floori(steps.position.y), ceili(steps.end.y)):
		for x in range(floori(steps.position.x), ceili(steps.end.x)):
			if steps.has_point(Vector2(x + 0.5, y + 0.5)):
				rows[y][x] = "#".unicode_at(0)
	# ground nobody can reach (sealed courtyards, behind rubble) is solid
	var reach := {}
	var stack: Array[Vector2i] = [SPAWNS[0]]
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		if c.x < 0 or c.y < 0 or c.x >= w or c.y >= h or reach.has(c):
			continue
		var ch := char(rows[c.y][c.x])
		if ch == "#" or ch == "X":
			continue
		reach[c] = true
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			stack.append(c + d)
	for y in h:
		for x in w:
			if rows[y][x] == dot and not reach.has(Vector2i(x, y)):
				rows[y][x] = "#".unicode_at(0)
		LAYOUT.append(rows[y].get_string_from_ascii())
	world = WorldScript.new()


func zone_of(c: Vector2i) -> String:
	if c.y <= 32:
		return "north"
	if c.y >= 52:
		return "south"
	if c.y <= 35:
		return "streets" if (c.x <= 10 or c.x >= 25) else "square"
	if c.y >= 48:
		return "streets" if (c.x <= 12 or c.x >= 25) else "square"
	return "square"


func floor_style(_x: int, _y: int, _ch: String) -> String:
	return "."


func surface(_c: Vector2i, _floor: String) -> String:
	return "stone"     # asphalt and concrete


func is_outdoor(_c: Vector2i) -> bool:
	return true


## Build everything the outpost builds from its layout chars: the streets
## and buildings, the skyline beyond, props, lights, the barricades' look.
func build_world(arena: Node3D) -> void:
	await world.build(arena, self)


## Where a wall-mounted thing should hang: the real facade in front of a
## wall cell, rather than the cell's edge.
func wall_point(cell: Vector2i, face: Vector3) -> Vector3:
	return world.facade_point(Vector3(cell.x + 0.5, 0.0, cell.y + 0.5) + face, -face)


## Where a machine standing in `cell` goes: its back against the facade
## behind it.
func stand_point(cell: Vector2i, face: Vector3) -> Vector3:
	var c := Vector3(cell.x + 0.5, 0.0, cell.y + 0.5)
	var w: Vector3 = world.facade_point(c, -face)
	return c if w == c else w + face * 0.5


## Every model the city needs, for the arena to build on worker threads.
func model_jobs() -> Array[Callable]:
	var jobs: Array[Callable] = [func(): world.manhole_mesh(), func(): world.lamp_mesh(), func(): world.subway_mesh(),
		func(): world.cab_mesh(), func(): world.steps_mesh()]
	for i in 4:
		jobs.append(func(): world.rubble_mesh(i))
	for b in BARRICADES:
		var w := float(maxi(b[3] - b[1], b[4] - b[2]) + 1)
		jobs.append(func(): world.barricade_mesh(w))
	return jobs


## The city at night: thinner haze so the towers read, lit from below by
## the screens.
func tune_environment(env: Environment) -> void:
	env.fog_density = 0.011
	env.fog_light_color = Color("2a2030")
	env.volumetric_fog_density = 0.012
	env.volumetric_fog_length = 64.0
	env.ambient_light_color = Color("40435e")


func door_mesh(width_m: float) -> Mesh:
	return world.barricade_mesh(width_m)


func vent_mesh() -> Mesh:
	return world.manhole_mesh()
