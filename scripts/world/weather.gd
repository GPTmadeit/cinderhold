extends Node3D
## Weather and ambience: a wind that rises and falls with gusts (shared with
## the shaders through the `wind` global, so grass, trees and banners lean
## and flutter with it), things blowing on it (ash and leaves at the outpost,
## paper and grit in the city), low mist drifting across the ground,
## lightning with thunder rolling in after it, and rain over Times Square
## with splashes and wet, shining streets (the `wetness` global).
## All local: every peer has its own weather, so nothing is networked.

const GLOBALS := {"wind": [RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(1, 0, 0.3, 0)],
	"wetness": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0]}

static var _globals_ready := false
static var _globals_lock := Mutex.new()

var arena: Node3D
var env: Environment
var storm := false               # rain and close lightning (the city)
var wind_dir := Vector2(1, 0.3).normalized()
var wind := 0.35                 # 0..1
var _gust := 0.0
var _gust_t := 6.0
var _flash_t := 12.0
var _flash := 0.0
var _flash_light: DirectionalLight3D
var _time := 0.0
var _blown: Array[GPUParticles3D] = []
var _rain: GPUParticles3D
var _splash: GPUParticles3D
var _mist: Array[Node3D] = []
var _mist_ground: GPUParticles3D
var _bounds := AABB()
var _rain_snd: AudioStreamPlayer
var _thunder_q: Array = []      # [time, volume]
var _siren_t := 30.0
var _rng := RandomNumberGenerator.new()
var _base_ambient := 1.0


## The shader globals must exist before any material that reads them is
## compiled; every builder calls this first. Safe from worker threads.
static func ensure_globals() -> void:
	if _globals_ready:
		return
	_globals_lock.lock()
	if not _globals_ready:
		for g in GLOBALS:
			RenderingServer.global_shader_parameter_add(g, GLOBALS[g][0], GLOBALS[g][1])
		_globals_ready = true
	_globals_lock.unlock()


func setup(a: Node3D, environment: Environment, is_storm: bool) -> void:
	arena = a
	env = environment
	storm = is_storm
	_rng.randomize()
	ensure_globals()
	_base_ambient = env.ambient_light_energy
	_bounds = AABB(Vector3.ZERO, Vector3(a.W, 6.0, a.H))
	wind_dir = Vector2.from_angle(_rng.randf() * TAU)
	var q := Settings.quality()
	# ground fog: thicker near the floor, thinning with height
	env.fog_height = 0.4
	env.fog_height_density = 0.6 if storm else 0.45
	if storm:
		env.fog_density *= 1.25
	# things on the wind
	if storm:
		_blown.append(_blow_particles([12, 30, 50, 70][q], _paper_mesh(), 7.0, Vector3(14, 3, 14)))
		_blown.append(_blow_particles([60, 140, 260, 360][q], _dust_mesh(Color(0.55, 0.52, 0.5, 0.5)), 4.0, Vector3(14, 4, 14)))
	else:
		_blown.append(_blow_particles([40, 90, 160, 220][q], _leaf_mesh(), 8.0, Vector3(14, 3, 14)))
		_blown.append(_blow_particles([80, 180, 320, 420][q], _dust_mesh(Color(0.6, 0.58, 0.56, 0.6)), 6.0, Vector3(14, 5, 14)))
	_build_mist(q)
	# lightning
	_flash_light = DirectionalLight3D.new()
	_flash_light.light_color = Color(0.75, 0.82, 1.0)
	_flash_light.light_energy = 0.0
	_flash_light.rotation_degrees = Vector3(-62, _rng.randf() * 360.0, 0)
	_flash_light.shadow_enabled = q >= 2
	_flash_light.visible = false
	add_child(_flash_light)
	_flash_t = _rng.randf_range(6.0, 14.0)
	if storm:
		_build_rain(q)
	RenderingServer.global_shader_parameter_set("wetness", 0.85 if storm else 0.0)


func _exit_tree() -> void:
	if _globals_ready:
		RenderingServer.global_shader_parameter_set("wetness", 0.0)


# =========================================================================
# Wind
# =========================================================================

func _process(dt: float) -> void:
	if arena == null:
		return
	_time += dt
	# the wind wanders, and now and then a gust rolls through
	wind_dir = wind_dir.rotated(sin(_time * 0.05) * dt * 0.05).normalized()
	_gust_t -= dt
	if _gust_t <= 0.0:
		_gust_t = _rng.randf_range(7.0, 18.0)
		_gust = 1.0
		Sfx.play("gust", -14.0 + _rng.randf_range(-3, 2), 0.15)
	_gust = maxf(_gust - dt * 0.28, 0.0)
	var g := sin(PI * clampf(_gust, 0.0, 1.0))
	wind = clampf(0.28 + 0.16 * sin(_time * 0.31) + 0.1 * sin(_time * 1.13) + 0.6 * g, 0.05, 1.0)
	RenderingServer.global_shader_parameter_set("wind", Vector4(wind_dir.x, wind_dir.y, wind, _time))
	var cam := get_viewport().get_camera_3d()
	var push := Vector3(wind_dir.x, 0, wind_dir.y) * wind
	for p in _blown:
		var pm := p.process_material as ParticleProcessMaterial
		pm.gravity = push * 6.0 + Vector3(0, -0.6 if p.draw_pass_1 is QuadMesh else -0.15, 0)
		if cam:
			p.global_position = cam.global_position * Vector3(1, 0, 1) + Vector3(0, 1.5, 0)
	for m in _mist:
		m.position += Vector3(wind_dir.x, 0, wind_dir.y) * (0.15 + wind * 0.6) * dt
		# wrap round the map so the mist keeps coming
		if m.position.x > _bounds.size.x + 6.0: m.position.x = -6.0
		elif m.position.x < -6.0: m.position.x = _bounds.size.x + 6.0
		if m.position.z > _bounds.size.z + 6.0: m.position.z = -6.0
		elif m.position.z < -6.0: m.position.z = _bounds.size.z + 6.0
	if _mist_ground and cam:
		_mist_ground.global_position = cam.global_position * Vector3(1, 0, 1)
		(_mist_ground.process_material as ParticleProcessMaterial).gravity = push * 0.6
	if _rain and cam:
		_rain.global_position = cam.global_position + Vector3(0, 9, 0) - push * 3.0
		(_rain.process_material as ParticleProcessMaterial).gravity = Vector3(0, -28, 0) + push * 10.0
		_splash.global_position = cam.global_position * Vector3(1, 0, 1) + Vector3(0, 0.03, 0)
	_lightning(dt)
	if _rain_snd:
		var out: bool = arena.ambience.is_outdoor.call(cam.global_position) if cam and arena.ambience.is_outdoor.is_valid() else true
		_rain_snd.volume_db = lerpf(_rain_snd.volume_db, (-10.0 if out else -20.0) + wind * 3.0, clampf(dt, 0.0, 1.0))
	elif storm and Sfx.is_ready():
		_rain_snd = AudioStreamPlayer.new()
		_rain_snd.stream = Sfx.streams.get("amb_rain")
		_rain_snd.bus = "SFX"
		_rain_snd.volume_db = -40.0
		add_child(_rain_snd)
		if _rain_snd.stream:
			_rain_snd.play()
	if storm and cam:
		_siren_t -= dt
		if _siren_t <= 0.0:
			_siren_t = _rng.randf_range(40.0, 90.0)
			var a := _rng.randf() * TAU
			Sfx.play_at("siren", cam.global_position + Vector3(cos(a), 0.3, sin(a)) * 60.0, -6.0, 0.1)


# =========================================================================
# Lightning
# =========================================================================

func _lightning(dt: float) -> void:
	_flash_t -= dt
	if _flash_t <= 0.0:
		_flash_t = _rng.randf_range(8.0, 22.0) if storm else _rng.randf_range(18.0, 45.0)
		_flash = 1.0
		_flash_light.rotation_degrees.y = _rng.randf() * 360.0
		# thunder arrives later the further off it was
		var far := _rng.randf_range(0.2, 1.0) if storm else _rng.randf_range(0.7, 1.0)
		_thunder_q.append([_time + far * 3.5, lerpf(2.0, -10.0, far)])
	if _flash > 0.0:
		_flash = maxf(_flash - dt * 2.6, 0.0)
		# a few flickers as the bolt restrikes
		var flicker := 1.0 if fmod(_flash * 9.0, 2.0) < 1.3 else 0.25
		var e := pow(_flash, 1.5) * flicker * (3.2 if storm else 1.3)
		_flash_light.visible = e > 0.01
		_flash_light.light_energy = e
		env.ambient_light_energy = _base_ambient + e * 0.35
	elif _flash_light.visible:
		_flash_light.visible = false
		env.ambient_light_energy = _base_ambient
	for i in range(_thunder_q.size() - 1, -1, -1):
		if _time >= _thunder_q[i][0]:
			Sfx.play("thunder", _thunder_q[i][1], 0.12)
			_thunder_q.remove_at(i)


# =========================================================================
# Particles and mist
# =========================================================================

func _blow_particles(amount: int, mesh: Mesh, life: float, extents: Vector3) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.preprocess = life
	p.local_coords = false
	p.visibility_aabb = AABB(-extents * 2.0, extents * 4.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = extents
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.1
	pm.initial_velocity_max = 0.6
	pm.angular_velocity_min = -280.0
	pm.angular_velocity_max = 280.0
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.4
	pm.turbulence_noise_scale = 4.0
	pm.turbulence_influence_min = 0.08
	pm.turbulence_influence_max = 0.25
	pm.damping_min = 0.3
	pm.damping_max = 0.8
	pm.scale_min = 0.6
	pm.scale_max = 1.3
	pm.particle_flag_rotate_y = true
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.12, 0.85, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp
	p.process_material = pm
	p.draw_pass_1 = mesh
	add_child(p)
	return p


static func _flake_mat(col: Color, unshaded := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.9
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


func _leaf_mesh() -> Mesh:
	var q := QuadMesh.new()
	q.size = Vector2(0.07, 0.05)
	q.material = _flake_mat(Color(0.36, 0.24, 0.12))
	return q


func _paper_mesh() -> Mesh:
	var q := QuadMesh.new()
	q.size = Vector2(0.07, 0.09)
	q.material = _flake_mat(Color(0.72, 0.7, 0.64))
	return q


func _dust_mesh(col: Color) -> Mesh:
	var q := QuadMesh.new()
	q.size = Vector2(0.025, 0.025)
	var m := _flake_mat(col)
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	q.material = m
	return q


static func _soft() -> GradientTexture2D:
	var t := GradientTexture2D.new()
	t.width = 64
	t.height = 64
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	t.gradient = g
	return t


## Low mist: real volumes drifting across the ground where volumetric fog
## runs, soft billboards hugging the floor around the camera elsewhere.
func _build_mist(q: int) -> void:
	if env.volumetric_fog_enabled:
		var noise := FastNoiseLite.new()
		noise.frequency = 0.06
		noise.fractal_octaves = 3
		var tex := NoiseTexture3D.new()
		tex.width = 48
		tex.height = 16
		tex.depth = 48
		tex.seamless = true
		tex.noise = noise
		var fm := FogMaterial.new()
		fm.density = 0.9 if storm else 0.7
		fm.albedo = Color(0.75, 0.75, 0.82)
		fm.height_falloff = 1.6
		fm.edge_fade = 0.35
		fm.density_texture = tex
		for i in (8 if q >= 3 else 5):
			var v := FogVolume.new()
			v.size = Vector3(_rng.randf_range(7, 12), 1.6, _rng.randf_range(7, 12))
			v.material = fm
			v.position = Vector3(_rng.randf() * _bounds.size.x, 0.5, _rng.randf() * _bounds.size.z)
			add_child(v)
			_mist.append(v)
		return
	var p := GPUParticles3D.new()
	p.amount = [16, 28, 40, 40][q]
	p.lifetime = 14.0
	p.preprocess = 14.0
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-20, -2, -20), Vector3(40, 6, 40))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(16, 0.2, 16)
	pm.initial_velocity_min = 0.05
	pm.initial_velocity_max = 0.2
	pm.spread = 180.0
	pm.scale_min = 0.8
	pm.scale_max = 1.6
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.3, 0.7, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(5.0, 1.4)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = _soft()
	m.albedo_color = Color(0.5, 0.5, 0.58, 0.16)
	m.proximity_fade_enabled = true
	m.proximity_fade_distance = 0.8
	m.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	m.distance_fade_min_distance = 1.0
	m.distance_fade_max_distance = 4.0
	quad.material = m
	p.draw_pass_1 = quad
	add_child(p)
	_mist_ground = p


# =========================================================================
# Rain
# =========================================================================

func _build_rain(q: int) -> void:
	_rain = GPUParticles3D.new()
	_rain.amount = [600, 1400, 2600, 4000][q]
	_rain.lifetime = 0.75
	_rain.preprocess = 1.0
	_rain.local_coords = false
	_rain.visibility_aabb = AABB(Vector3(-16, -14, -16), Vector3(32, 18, 32))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(14, 1.5, 14)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 3.0
	pm.initial_velocity_min = 10.0
	pm.initial_velocity_max = 13.0
	pm.particle_flag_align_y = true
	pm.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
	_rain.process_material = pm
	var streak := QuadMesh.new()
	streak.size = Vector2(0.012, 0.42)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	m.billboard_keep_scale = true
	m.albedo_color = Color(0.75, 0.8, 0.9, 0.28)
	streak.material = m
	_rain.draw_pass_1 = streak
	add_child(_rain)
	# rain stops at roofs, awnings and the floor
	var hf := GPUParticlesCollisionHeightField3D.new()
	hf.size = Vector3(32, 30, 32)
	hf.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_256
	hf.follow_camera_enabled = true
	hf.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_WHEN_MOVED
	add_child(hf)
	# splashes on the ground around the camera
	_splash = GPUParticles3D.new()
	_splash.amount = [80, 180, 320, 420][q]
	_splash.lifetime = 0.28
	_splash.local_coords = false
	_splash.visibility_aabb = AABB(Vector3(-12, -1, -12), Vector3(24, 2, 24))
	var sm := ParticleProcessMaterial.new()
	sm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	sm.emission_box_extents = Vector3(10, 0, 10)
	sm.gravity = Vector3.ZERO
	sm.initial_velocity_min = 0.0
	sm.initial_velocity_max = 0.0
	sm.scale_min = 0.5
	sm.scale_max = 1.0
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.2))
	grow.add_point(Vector2(1, 1.0))
	var gt := CurveTexture.new()
	gt.curve = grow
	sm.scale_curve = gt
	var fade := Gradient.new()
	fade.colors = PackedColorArray([Color(1, 1, 1, 0.6), Color(1, 1, 1, 0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	sm.color_ramp = ramp
	_splash.process_material = sm
	var ring := QuadMesh.new()
	ring.size = Vector2(0.14, 0.14)
	ring.orientation = PlaneMesh.FACE_Y
	var rm := StandardMaterial3D.new()
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.vertex_color_use_as_albedo = true
	rm.albedo_color = Color(0.8, 0.85, 0.95, 0.5)
	rm.albedo_texture = _soft()
	ring.material = rm
	_splash.draw_pass_1 = ring
	add_child(_splash)
