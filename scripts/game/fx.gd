extends Node3D
## Hit effects: tracers, impact sparks, blood-ember bursts and impact lights.
##
## Each shot used to build its own particles, meshes and materials. A
## material's shader is freed along with its last user, so the next shot
## compiled it again, and phones spent the fight compiling GPU pipelines.
## Every effect now draws from a fixed ring of nodes that share resources
## made once per match, so nothing is created or freed while shooting.
## Powerups and other scene props are plain children of this node too.

const ArenaScript := preload("res://scripts/world/arena.gd")

const TRACER_LIFE := 0.07
const LIGHT_LIFE := 0.35

## pool -> [count, amount, lifetime, explosiveness, spread, speed min, speed max, scale min, scale max]
const POOLS := {
	"spark": [16, 6, 0.45, 1.0, 45.0, 1.0, 3.5, 0.5, 1.0],
	"blast": [6, 24, 0.45, 1.0, 180.0, 1.0, 6.0, 0.5, 1.0],
	"burst": [16, 8, 0.6, 0.95, 80.0, 1.5, 4.0, 0.6, 1.2],
	"burst_big": [8, 18, 0.6, 0.95, 80.0, 1.5, 4.0, 0.6, 1.2],
	"fireball": [4, 48, 0.8, 1.0, 180.0, 2.0, 7.5, 1.5, 3.2],
}
const TRACERS := 32
const LIGHTS := 4

var _pools := {}          # name -> Array[CPUParticles3D]
var _next := {}           # name -> next index
var _tracers: Array[MeshInstance3D] = []
var _tracer_t := PackedFloat32Array()
var _tracer_mats: Array[StandardMaterial3D] = []   # [normal, hot]
var _next_tracer := 0
var _lights: Array[OmniLight3D] = []
var _light_t := PackedFloat32Array()
var _light_e := PackedFloat32Array()   # each flash's starting energy
var _next_light := 0


func _ready() -> void:
	for pool in POOLS:
		_pools[pool] = _make_pool(pool)
		_next[pool] = 0
	var box := BoxMesh.new()   # unit box, scaled per tracer
	for hot in [false, true]:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1.0, 0.55, 0.2, 0.7) if hot else Color(1.0, 0.85, 0.55, 0.45)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_tracer_mats.append(m)
	for i in TRACERS:
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_tracers.append(mi)
	_tracer_t.resize(TRACERS)
	for i in LIGHTS:
		var l := OmniLight3D.new()
		l.light_color = Color("ffa040")
		l.omni_range = 6.0
		l.visible = false
		add_child(l)
		_lights.append(l)
	_light_t.resize(LIGHTS)
	_light_e.resize(LIGHTS)


func _make_pool(pool: String) -> Array[CPUParticles3D]:
	var cfg: Array = POOLS[pool]
	var mesh := BoxMesh.new()
	if pool.begins_with("burst") or pool == "fireball":
		mesh.size = Vector3(0.05, 0.05, 0.05) if pool != "fireball" else Vector3(0.09, 0.09, 0.09)
		mesh.material = ArenaScript.particle_material()
	else:
		mesh.size = Vector3(0.035, 0.035, 0.035)
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if pool == "blast" else BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mesh.material = m
	var ramp := ArenaScript.fire_gradient() if (pool.begins_with("burst") or pool == "fireball") else null
	var out: Array[CPUParticles3D] = []
	for i in int(cfg[0]):
		var p := CPUParticles3D.new()
		p.emitting = false
		p.one_shot = true
		p.amount = cfg[1]
		p.lifetime = cfg[2]
		p.explosiveness = cfg[3]
		p.spread = cfg[4]
		p.initial_velocity_min = cfg[5]
		p.initial_velocity_max = cfg[6]
		p.scale_amount_min = cfg[7]
		p.scale_amount_max = cfg[8]
		p.gravity = Vector3(0, 2.5, 0) if pool == "fireball" else Vector3(0, -9, 0)
		if pool == "fireball":
			p.damping_min = 4.0
			p.damping_max = 7.0
		p.mesh = mesh
		if ramp:
			p.color_ramp = ramp
		else:
			p.color = Color(1.0, 0.75, 0.4) if pool == "blast" else Color(0.75, 0.68, 0.6)
		add_child(p)
		out.append(p)
	return out


func _emit(pool: String, pos: Vector3, dir: Vector3) -> void:
	var list: Array = _pools[pool]
	var i: int = _next[pool]
	_next[pool] = (i + 1) % list.size()
	var p: CPUParticles3D = list[i]
	p.position = pos
	p.direction = dir
	p.restart()


## A bullet's streak from the muzzle to where it stopped.
func tracer(from: Vector3, to: Vector3, hot: bool, life := TRACER_LIFE) -> void:
	var length := from.distance_to(to)
	if length < 0.5:
		return
	var dir := (to - from) / length
	var b := Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT)
	b.x *= 0.012
	b.y *= 0.012
	b.z *= length
	var i := _next_tracer
	_next_tracer = (i + 1) % TRACERS
	var mi := _tracers[i]
	mi.transform = Transform3D(b, (from + to) * 0.5)
	mi.material_override = _tracer_mats[1 if hot else 0]
	mi.transparency = 0.0
	mi.visible = true
	_tracer_t[i] = life


## A jagged Cinderbolt arc made of short tracers.
func arc(from: Vector3, to: Vector3, rng: RandomNumberGenerator) -> void:
	var steps := 6
	var prev := from
	for i in range(1, steps + 1):
		var p := from.lerp(to, float(i) / steps)
		if i < steps:
			p += Vector3(rng.randf_range(-0.25, 0.25), rng.randf_range(-0.25, 0.25), rng.randf_range(-0.25, 0.25))
		tracer(prev, p, true)
		prev = p


## Sparks where a shot hit the world. `big` adds a flash of light.
func impact(pos: Vector3, normal: Vector3, big := false) -> void:
	_emit("blast" if big else "spark", pos + normal * 0.02, normal)
	if big:
		_flash(pos + normal * 0.3, 4.0, 6.0)


## A grenade going off: a fireball, flying debris, embers and a bright flash.
func blast(pos: Vector3) -> void:
	_emit("fireball", pos, Vector3.UP)
	_emit("blast", pos, Vector3.UP)
	_emit("burst_big", pos + Vector3.UP * 0.3, Vector3.UP)
	_flash(pos + Vector3.UP * 0.6, 12.0, 11.0)


func _flash(pos: Vector3, energy: float, range_m: float) -> void:
	var i := _next_light
	_next_light = (i + 1) % LIGHTS
	_lights[i].position = pos
	_lights[i].omni_range = range_m
	_lights[i].light_energy = energy
	_lights[i].visible = true
	_light_t[i] = LIGHT_LIFE
	_light_e[i] = energy


## Embers spraying from a wounded Husk.
func burst(pos: Vector3, big: bool) -> void:
	_emit("burst_big" if big else "burst", pos, Vector3.UP)


## Fire every kind of effect once at `pos` (behind the loading screen), so
## their pipelines are compiled before the first shot.
func warm(pos: Vector3) -> void:
	for pool in POOLS:
		_emit(pool, pos, Vector3.UP)
	tracer(pos - Vector3.RIGHT, pos + Vector3.RIGHT, false, 0.5)   # kept up while the warm-up draws
	tracer(pos - Vector3.UP, pos + Vector3.UP, true, 0.5)
	impact(pos, Vector3.UP, true)


func _process(dt: float) -> void:
	for i in TRACERS:
		if _tracer_t[i] > 0.0:
			_tracer_t[i] -= dt
			if _tracer_t[i] <= 0.0:
				_tracers[i].visible = false
			else:
				_tracers[i].transparency = 1.0 - minf(_tracer_t[i] / TRACER_LIFE, 1.0)
	for i in LIGHTS:
		if _light_t[i] > 0.0:
			_light_t[i] -= dt
			if _light_t[i] <= 0.0:
				_lights[i].visible = false
			else:
				_lights[i].light_energy = _light_e[i] * _light_t[i] / LIGHT_LIFE
