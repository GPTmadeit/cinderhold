extends RefCounted
## The Cinderhold outpost: a ruined frontier fort in four parts (barracks,
## great hall, courtyard, garden) joined by barricade doors.
##
## One map cell is 1 m. Legend:
##   #  wall           ,  barracks planks   ;  hall tiles   .  cobble   :  earth
##   A-D door cells    S  player spawn
##   k bunk  t table  o barrel  c crate  w well  T dead tree  g grave  b brazier  l lantern

const ID := "outpost"
const TITLE := "Cinderhold Outpost"
const WALKABLE := ",;.:S"
const FLOOR_CHARS := ",;.:"
## Vents per zone each match.
const VENT_QUOTA := {"court": 2, "barracks": 1, "hall": 1, "garden": 1}

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


func zone_of(c: Vector2i) -> String:
	if c.y < 13:
		return "barracks" if c.x < 19 else "hall"
	return "court" if c.x < 23 else "garden"


## The floor style a cell sits on (props and vents stand on their zone's floor).
func floor_style(x: int, y: int, ch: String) -> String:
	if FLOOR_CHARS.contains(ch):
		return ch
	if y < 13:
		return "," if x < 19 else ";"
	if y > 13:
		return "." if x < 23 else ":"
	return ";"


## What a footstep sounds like on a cell: "wood", "stone" or "dirt".
func surface(c: Vector2i, floor_ch: String) -> String:
	if floor_ch == ",":
		return "wood"
	if floor_ch == ":" or (floor_ch == ";" and c.y >= 6 and c.y <= 7 and c.x >= 20):
		return "dirt"     # garden earth, and the hall's carpet runner is just as soft
	return "stone"


## The courtyard and garden are open to the sky; the halls are walled in.
func is_outdoor(c: Vector2i) -> bool:
	return c.y > 13
