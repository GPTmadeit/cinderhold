extends CharacterBody3D
## A survivor. The owning peer simulates movement, health, weapons and
## interaction, then streams its state to everyone else at 20 Hz. Remote
## copies interpolate that state and animate a third-person voxel model.

const Prof := preload("res://scripts/core/prof.gd")
const M := preload("res://scripts/voxel/models.gd")
const W := preload("res://scripts/game/weapons.gd")
const P := preload("res://scripts/game/perks.gd")
const ArenaScript := preload("res://scripts/world/arena.gd")
const A := preload("res://scripts/game/rig_anim.gd")

const WALK := 4.6
const SPRINT := 6.9
const CROUCH := 2.4
const AIM_WALK := 2.9
const CRAWL := 0.9
const JUMP := 5.6               # ~1.05 m: enough to land on crates, barrels and tables
const GRAVITY := 15.0
const EYE := 1.62
const EYE_CROUCH := 1.1
const EYE_DOWN := 0.55
const BLEED_TIME := 35.0
const REVIVE_TIME := 3.0
const STATE_RATE := 20.0
const MAX_SLOTS := 2
const MAX_GRENADES := 4
const MASK_SHOT := 1 | 4

var game: Node
var peer_id := 1
var display_name := "Survivor"
var color_idx := 0

# --- simulation state (authoritative on the owner) -----------------------
var hp := P.MAX_HEALTH
var max_hp := P.MAX_HEALTH
var downed := false
var dead := false
var bleed_t := 0.0
var self_revive_t := -1.0
var weapons: Array = []          # [{id, upgraded, mag, reserve}]
var cur := 0
var perks: Array[String] = []
var yaw := 0.0
var pitch := 0.0
var aiming := false
var sprinting := false
var crouching := false
var reload_t := -1.0
var reload_total := 1.0
var swap_t := 0.0
var melee_t := 0.0
var fire_cd := 0.0
var ads_k := 0.0
var bloom := 0.0
var hurt_flash := 0.0
var hurt_dir := Vector3.ZERO
var forge_pending := ""
var revive_progress := 0.0
var revive_target := 0
var prompt := ""
var prompt_cost := 0
var since_hurt := 99.0
var touch_look := Vector2.ZERO
var grenades := 2

# --- remote state ---------------------------------------------------------
var _net_flags := 0
var _net_weapon := ""
var _net_upgraded := false
var _net_buf: Array = []       # [t, pos, yaw, pitch]
var _remote_speed := 0.0

# --- nodes ----------------------------------------------------------------
var head: Node3D
var camera: Camera3D
var viewmodel: Node3D
var _gun_mesh: MeshInstance3D
var _arm_l: MeshInstance3D
var _arm_r: MeshInstance3D
var _muzzle: Node3D
var _muzzle_light: OmniLight3D
var _muzzle_flash: MeshInstance3D
var _body: Node3D
var _parts := {}
var _tp_gun: MeshInstance3D
var _name_label: Label3D
# third-person animation (what other players see; also drives our own shadow)
var _tp_phase := 0.0
var _tp_kick := 0.0
var _tp_melee := 0.0
var _tp_throw := 0.0
# first-person off hand: the knife slash and the grenade throw
var _hand_rig: Node3D
var _hand_knife: MeshInstance3D
var _hand_nade: MeshInstance3D
var _hand_anim := ""
var _hand_t := 0.0
var _melee_hit_t := -1.0
var _release_t := -1.0
var _arm_l_rest := Transform3D()
var _shake := 0.0

var _state_t := 0.0
var _step_t := 0.0
var _was_grounded := true
var _fall_speed := 0.0
var _bob_t := 0.0
var _sway := Vector2.ZERO
var _kick := 0.0
var _semi_ready := true
var _empty_clicked := false
var _flash_t := 0.0
var _vm_def: Dictionary = {}
var _vm_id := ""
var _sight: Dictionary = {}          # models.gd gun_sight() of the gun in hand
var _reticle: MeshInstance3D
var _rng := RandomNumberGenerator.new()
var _last_pos := Vector3.ZERO


func is_local() -> bool:
	return is_multiplayer_authority()


func _ready() -> void:
	_rng.randomize()
	collision_layer = 2
	collision_mask = 1 | 4
	floor_snap_length = 0.3
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.34
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	cs.name = "Shape"
	add_child(cs)

	head = Node3D.new()
	head.name = "Head"
	head.position.y = EYE
	add_child(head)
	camera = Camera3D.new()
	camera.near = 0.03
	camera.far = 300.0
	camera.fov = float(Settings.get_v("gameplay", "fov"))
	head.add_child(camera)
	_build_body()

	if is_local():
		camera.current = true
		_build_viewmodel()
		weapons = [_new_slot("tinder", false)]
		_refresh_viewmodel()
		if Settings.can_capture_mouse():
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		for mi in _body_meshes():
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		_name_label.visible = false
	yaw = rotation.y
	_last_pos = global_position


func _new_slot(id: String, upgraded: bool) -> Dictionary:
	var d := W.get_def(id, upgraded)
	return {"id": id, "upgraded": upgraded, "mag": d.mag, "reserve": d.reserve}


func weapon() -> Dictionary:
	return weapons[cur] if cur < weapons.size() else {}


func weapon_def() -> Dictionary:
	var w := weapon()
	return W.get_def(w.id, w.upgraded) if not w.is_empty() else {}


func alive() -> bool:
	if is_local():
		return not dead
	return _net_flags & 8 == 0


func targetable() -> bool:
	if is_local():
		return not dead and not downed
	return _net_flags & (4 | 8) == 0


func is_downed() -> bool:
	return downed if is_local() else (_net_flags & 4 != 0 and _net_flags & 8 == 0)


func has_perk(k: String) -> bool:
	return k in perks


# =========================================================================
# Model building
# =========================================================================

func _build_body() -> void:
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)
	_parts = M.instance_rig(M.survivor(color_idx), _body)
	# the gun sits in the right hand, barrel along the forearm
	_tp_gun = MeshInstance3D.new()
	_tp_gun.position = Vector3(0, -0.3, -0.04)
	_tp_gun.rotation.x = -PI * 0.5
	_tp_gun.scale = Vector3.ONE * 1.4
	_parts.fore_r.add_child(_tp_gun)
	_name_label = Label3D.new()
	_name_label.font = preload("res://assets/fonts/Rajdhani-Bold.ttf")
	_name_label.font_size = 48
	_name_label.pixel_size = 0.004
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.no_depth_test = true
	_name_label.outline_size = 10
	_name_label.modulate = Settings.PLAYER_COLORS[color_idx % 4].lightened(0.3)
	_name_label.text = display_name
	_name_label.position.y = 2.25
	add_child(_name_label)


func _body_meshes() -> Array:
	var out := []
	for p in _parts.values():
		for c in p.get_children():
			if c is MeshInstance3D:
				out.append(c)
	return out


func _build_viewmodel() -> void:
	viewmodel = Node3D.new()
	viewmodel.name = "ViewModel"
	# Smaller than life, as shooters do: reads like a narrower viewmodel FOV.
	viewmodel.scale = Vector3.ONE * 0.6
	camera.add_child(viewmodel)
	_gun_mesh = MeshInstance3D.new()
	_gun_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	viewmodel.add_child(_gun_mesh)
	var arms: Dictionary = M.arms()
	_arm_r = MeshInstance3D.new()
	_arm_r.mesh = arms.r
	_arm_l = MeshInstance3D.new()
	_arm_l.mesh = arms.l
	for a in [_arm_r, _arm_l]:
		a.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		viewmodel.add_child(a)
		_viewmodel_materials(a)
	# the off hand for melee and throws, posed in camera space
	_hand_rig = Node3D.new()
	_hand_rig.scale = Vector3.ONE * 0.6
	_hand_rig.visible = false
	camera.add_child(_hand_rig)
	var hand_arm := MeshInstance3D.new()
	hand_arm.mesh = arms.l
	_hand_knife = MeshInstance3D.new()
	_hand_knife.mesh = M.knife()
	_hand_knife.position = Vector3(0.0, 0.01, -0.08)
	_hand_knife.rotation = Vector3(0.25, 0.0, 0.0)
	_hand_nade = MeshInstance3D.new()
	_hand_nade.mesh = M.grenade()
	_hand_nade.position = Vector3(0.0, 0.03, -0.09)
	for mi in [hand_arm, _hand_knife, _hand_nade]:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_hand_rig.add_child(mi)
		_viewmodel_materials(mi)
	# the survivor's pack lantern: keeps the viewmodel and nearby ground readable
	var lantern := OmniLight3D.new()
	lantern.light_color = Color("ffb879")
	lantern.light_energy = 0.7
	lantern.omni_range = 5.0
	lantern.position = Vector3(0.3, -0.35, 0.25)
	camera.add_child(lantern)
	_muzzle = Node3D.new()
	viewmodel.add_child(_muzzle)
	_muzzle_light = OmniLight3D.new()
	_muzzle_light.light_color = Color("ffb46a")
	_muzzle_light.omni_range = 6.0
	_muzzle_light.light_energy = 0.0
	_muzzle.add_child(_muzzle_light)
	_muzzle_flash = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.22, 0.22)
	var fm := ArenaScript.particle_material().duplicate() as StandardMaterial3D
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fm.albedo_color = Color(1.0, 0.7, 0.3)
	q.material = fm
	_muzzle_flash.mesh = q
	_muzzle_flash.visible = false
	_muzzle.add_child(_muzzle_flash)


static var _vm_mats := {}


## Viewmodel meshes sit inside the player's own (shadow-only) body, so they
## use a variant of the voxel material that ignores shadows.
func _viewmodel_materials(mi: MeshInstance3D) -> void:
	if mi.mesh == null:
		return
	for i in mi.mesh.get_surface_count():
		var src: ShaderMaterial = mi.mesh.surface_get_material(i)
		if not _vm_mats.has(src):
			var m := src.duplicate() as ShaderMaterial
			m.shader = preload("res://shaders/voxel_viewmodel.gdshader")
			_vm_mats[src] = m
		mi.set_surface_override_material(i, _vm_mats[src])


func _refresh_viewmodel() -> void:
	var w := weapon()
	if not is_local():
		return
	if w.is_empty():
		_gun_mesh.mesh = null
		_vm_id = ""
		return
	var key := "%s_%s" % [w.id, w.upgraded]
	if key == _vm_id:
		return
	_vm_id = key
	_vm_def = weapon_def()
	_gun_mesh.mesh = M.gun(w.id, w.upgraded)
	_viewmodel_materials(_gun_mesh)
	_sight = M.gun_sight(w.id)
	if _reticle == null:
		_reticle = MeshInstance3D.new()
		var q := QuadMesh.new()
		var rm := ShaderMaterial.new()
		rm.shader = preload("res://shaders/red_dot.gdshader")
		q.material = rm
		_reticle.mesh = q
		_reticle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_gun_mesh.add_child(_reticle)
	_reticle.visible = _sight.kind == "dot"
	_reticle.position = _sight.point
	(_reticle.mesh as QuadMesh).size = Vector2.ONE * float(_sight.size)
	var aabb := _gun_mesh.mesh.get_aabb()
	_muzzle.position = Vector3(0, 0.085, aabb.position.z - 0.02)
	_arm_r.position = Vector3(0.0, -0.05, 0.02)
	_arm_r.rotation = Vector3(0.75, 0.35, 0)
	var fore := clampf(aabb.position.z * 0.55, -0.55, -0.12)
	_arm_l.position = Vector3(-0.015, -0.02, fore)
	_arm_l.rotation = Vector3(0.6, -0.7, 0.3)
	_arm_l_rest = _arm_l.transform


# =========================================================================
# Input
# =========================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not is_local() or game.hud.menu_open() or not Settings.can_capture_mouse():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		add_look(event.relative * 0.0022 * float(Settings.get_v("gameplay", "sensitivity")))
	elif event.is_action_pressed("weapon_1"):
		_switch_to(0)
	elif event.is_action_pressed("weapon_2"):
		_switch_to(1)
	elif event.is_action_pressed("next_weapon"):
		_switch_to((cur + 1) % maxi(weapons.size(), 1))
	elif event.is_action_pressed("prev_weapon"):
		_switch_to((cur - 1 + weapons.size()) % maxi(weapons.size(), 1))
	elif event.is_action_pressed("reload"):
		_start_reload()
	elif event.is_action_pressed("melee"):
		_melee()
	elif event.is_action_pressed("grenade"):
		_throw_grenade()
	elif event.is_action_pressed("interact"):
		_interact_pressed()


## Look input in radians (mouse, touch and stick all end up here).
func add_look(delta: Vector2) -> void:
	# Aim sensitivity is a multiple of the normal one; scopes zoom further, so
	# they turn a little slower again.
	var zoomed := float(Settings.get_v("gameplay", "aim_sensitivity")) * (0.7 if _vm_def.get("scope", false) else 1.0)
	var ads_slow := lerpf(1.0, zoomed, ads_k)
	yaw -= delta.x * ads_slow
	var inv := -1.0 if Settings.get_v("gameplay", "invert_y") else 1.0
	pitch = clampf(pitch - delta.y * ads_slow * inv, deg_to_rad(-88), deg_to_rad(88))
	_sway += Vector2(delta.x, delta.y) * 0.6


# =========================================================================
# Simulation (owner)
# =========================================================================

func _physics_process(dt: float) -> void:
	var _pt := Time.get_ticks_usec()
	_physics_process_body(dt)
	if Prof.on:
		Prof.add("player", _pt)


func _physics_process_body(dt: float) -> void:
	if not is_local():
		_remote_update(dt)
		return
	# scripted dev runs ignore live input so a test window can't be played by accident
	var menu: bool = game.hud.menu_open() or (not Settings.can_capture_mouse() and not Settings.bot_driving())
	if dead:
		_spectate()
		_send_state(dt)
		return
	since_hurt += dt
	hurt_flash = maxf(hurt_flash - dt * 1.8, 0.0)
	if since_hurt > 3.5 and not downed and hp < max_hp:
		hp = minf(hp + 55.0 * dt, max_hp)

	# stick look
	var stick := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if stick.length() > 0.15 and not menu:
		add_look(stick * stick.length() * dt * 3.2 * float(Settings.get_v("gameplay", "sensitivity")))

	var input := Vector2.ZERO if menu else Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	crouching = not downed and not menu and Input.is_action_pressed("crouch")
	aiming = not menu and Input.is_action_pressed("aim") and swap_t <= 0.0 and not weapon().is_empty() and reload_t < 0.0
	sprinting = not menu and Input.is_action_pressed("sprint") and input.y < -0.3 and not aiming and not crouching and not downed
	if sprinting and reload_t >= 0.0 and not has_perk("fleetfoot"):
		sprinting = false

	var speed := WALK
	if downed:
		speed = CRAWL
	elif sprinting:
		speed = SPRINT
	elif aiming:
		speed = AIM_WALK
	elif crouching:
		speed = CROUCH
	if has_perk("fleetfoot"):
		speed *= 1.15
	rotation.y = yaw
	head.rotation.x = pitch
	var wish := (transform.basis * Vector3(input.x, 0, input.y))
	if wish.length() > 1.0:
		wish = wish.normalized()
	var accel := 12.0 if is_on_floor() else 3.0
	var hv := Vector3(velocity.x, 0, velocity.z).lerp(wish * speed, clampf(accel * dt, 0.0, 1.0))
	velocity.x = hv.x
	velocity.z = hv.z
	if is_on_floor():
		if not menu and not downed and Input.is_action_just_pressed("jump"):
			velocity.y = JUMP
	else:
		velocity.y -= GRAVITY * dt
	move_and_slide()

	var eye := EYE_DOWN if downed else (EYE_CROUCH if crouching else EYE)
	head.position.y = lerpf(head.position.y, eye, clampf(dt * 10.0, 0.0, 1.0))
	_footsteps(dt, hv.length())
	_weapons_tick(dt, menu)
	_hand_tick(dt)
	_interaction_tick(dt, menu)
	_downed_tick(dt)
	_camera_tick(dt)
	_send_state(dt)
	# our own body only casts a shadow, but it may as well walk
	var flags := int(sprinting) | int(crouching) << 1 | int(downed) << 2 | int(aiming) << 4 \
		| int(reload_t >= 0.0) << 5 | int(not is_on_floor()) << 6
	_animate_body(dt, hv.length(), flags)


func _footsteps(dt: float, spd: float) -> void:
	var grounded := is_on_floor()
	if grounded and not _was_grounded and _fall_speed < -4.5:
		Sfx.play("land", -4.0, 0.08)
		_step_t = 0.5
	_was_grounded = grounded
	_fall_speed = velocity.y
	if not grounded or spd < 0.5:
		return
	_step_t -= dt * spd / 2.1
	if _step_t <= 0.0:
		_step_t = 1.0
		var vol := -12.0 if crouching else (-2.0 if sprinting else -5.0)
		Sfx.play("step_%s%d" % [game.arena.surface_at(global_position), _rng.randi_range(0, 2)], vol, 0.1)


## Remote players' footsteps, from their interpolated speed.
func _remote_footsteps(dt: float) -> void:
	if _net_flags & (4 | 8 | 64) != 0 or _remote_speed < 0.6:
		return
	_step_t -= dt * _remote_speed / 2.1
	if _step_t <= 0.0:
		_step_t = 1.0
		var vol := -14.0 if _net_flags & 2 else (-3.0 if _net_flags & 1 else -6.0)
		Sfx.play_at("step_%s%d" % [game.arena.surface_at(global_position), _rng.randi_range(0, 2)], global_position, vol, 0.1)


func _camera_tick(dt: float) -> void:
	var def := _vm_def
	var base_fov := float(Settings.get_v("gameplay", "fov"))
	var ads_speed := 12.0 if has_perk("fleetfoot") else 8.0
	ads_k = move_toward(ads_k, 1.0 if aiming else 0.0, dt * ads_speed * 0.6)
	var target_fov := base_fov * lerpf(1.0, float(def.get("ads_fov", 0.85)), ease(ads_k, -2.0))
	if sprinting:
		target_fov += 6.0
	camera.fov = lerpf(camera.fov, target_fov, clampf(dt * 14.0, 0.0, 1.0))
	if viewmodel == null:
		return
	var hspd := Vector2(velocity.x, velocity.z).length()
	_bob_t += dt * (hspd * 1.9 if is_on_floor() else 0.0)
	var bob_amt := float(def.get("bob", 1.0)) * lerpf(1.0, 0.15, ads_k) * clampf(hspd / WALK, 0.0, 1.6)
	var bob := Vector3(sin(_bob_t) * 0.012, -absf(cos(_bob_t)) * 0.014, 0) * bob_amt
	_sway = _sway.lerp(Vector2.ZERO, clampf(dt * 8.0, 0.0, 1.0))
	var hip: Vector3 = def.get("slot_pos", Vector3(0.16, -0.18, -0.34))
	# Aiming puts this gun's own sight (red dot, front post or scope) on the
	# screen centre, 30 cm from the eye: shots fly along the camera's centre
	# line, so they land exactly where the sight says.
	var sp: Vector3 = _sight.get("point", Vector3(0, 0.12, -0.2)) * viewmodel.scale.x
	var ads := Vector3(-sp.x, -sp.y, -0.3 - sp.z)
	var pos := hip.lerp(ads, ease(ads_k, -2.0)) + bob
	pos += Vector3(-_sway.x * 0.03, _sway.y * 0.03, 0) * lerpf(1.0, 0.1, ads_k)
	pos.z += _kick * 0.06
	pos.y += _kick * 0.01
	if sprinting:
		pos += Vector3(0.04, -0.05, 0.03)
	if swap_t > 0.0:
		pos.y -= swap_t * 0.6
	if reload_t >= 0.0:
		var k := sin(clampf(1.0 - reload_t / reload_total, 0.0, 1.0) * PI)
		pos.y -= k * 0.08
	if downed:
		pos += Vector3(0.0, -0.05, 0.03)
	var hand_k := 0.0
	if _hand_anim != "":
		# the gun drops out of the off hand's way
		hand_k = sin(clampf(_hand_t / (0.42 if _hand_anim == "melee" else 0.55), 0.0, 1.0) * PI)
		pos += Vector3(0.05, -0.15, 0.06) * hand_k
	viewmodel.position = pos
	# reloads: the off hand drops to the magazine and back
	var t_rest := _arm_l_rest
	if reload_t >= 0.0:
		var k := sin(clampf(1.0 - reload_t / reload_total, 0.0, 1.0) * PI)
		t_rest = t_rest.translated_local(Vector3(0.0, -0.1, 0.08) * k).rotated_local(Vector3.RIGHT, -0.5 * k)
	_arm_l.transform = t_rest
	_shake = move_toward(_shake, 0.0, dt * 2.2)
	camera.h_offset = randf_range(-1.0, 1.0) * _shake * 0.05
	camera.v_offset = randf_range(-1.0, 1.0) * _shake * 0.05
	camera.rotation.z = randf_range(-1.0, 1.0) * _shake * 0.025
	var sway_k := lerpf(1.0, 0.15, ads_k)    # steady while aiming, so the sight stays put
	var rot := Vector3(_kick * 0.12 + (k_reload_tilt() if reload_t >= 0.0 else 0.0) - hand_k * 0.35,
		_sway.x * 0.05 * sway_k - hand_k * 0.15, -_sway.x * 0.08 * sway_k + hand_k * 0.25)
	if sprinting:
		rot += Vector3(-0.25, 0.5, 0.15)
	viewmodel.rotation = viewmodel.rotation.lerp(rot, clampf(dt * 14.0, 0.0, 1.0))
	_kick = move_toward(_kick, 0.0, dt * 6.0)
	var scoped: bool = def.get("scope", false) and ads_k > 0.92
	viewmodel.visible = not scoped and not weapon().is_empty()
	_flash_t -= dt
	_muzzle_light.light_energy = 3.0 if _flash_t > 0.0 else 0.0
	_muzzle_flash.visible = _flash_t > 0.0 and not scoped


func k_reload_tilt() -> float:
	return sin(clampf(1.0 - reload_t / reload_total, 0.0, 1.0) * PI) * 0.6


# =========================================================================
# Weapons
# =========================================================================

func _weapons_tick(dt: float, menu: bool) -> void:
	fire_cd -= dt
	swap_t = maxf(swap_t - dt, 0.0)
	melee_t = maxf(melee_t - dt, 0.0)
	bloom = move_toward(bloom, 0.0, dt * 6.0)
	if _melee_hit_t >= 0.0:
		_melee_hit_t -= dt
		if _melee_hit_t < 0.0:
			_melee_strike()     # the blade lands mid-swing
	var w := weapon()
	if w.is_empty() or _hand_anim == "throw":
		return
	var def := weapon_def()
	if reload_t >= 0.0:
		var before := reload_t
		reload_t -= dt
		if before > reload_total * 0.35 and reload_t <= reload_total * 0.35:
			Sfx.play("mag_in", -4.0)
		if reload_t < 0.0:
			var need: int = def.mag - w.mag
			var take := mini(need, w.reserve)
			w.mag += take
			w.reserve -= take
			if def.get("pump", false):
				Sfx.play("rack", -4.0)
	var want := not menu and Input.is_action_pressed("fire")
	if not want:
		_semi_ready = true
		_empty_clicked = false
	if not want or fire_cd > 0.0 or swap_t > 0.0 or melee_t > 0.35:
		return
	if not def.auto and not _semi_ready:
		return
	if reload_t >= 0.0:
		if def.get("pump", false) and w.mag > 0:
			reload_t = -1.0          # shotgun: firing interrupts a reload
		else:
			return
	if w.mag <= 0:
		if w.reserve > 0:
			_start_reload()
		elif not _empty_clicked:
			Sfx.play("empty")
			_empty_clicked = true
		return
	_semi_ready = false
	sprinting = false
	_shoot(def, w)


func _shoot(def: Dictionary, w: Dictionary) -> void:
	w.mag -= 1
	fire_cd = 60.0 / float(def.rpm)
	var origin := camera.global_position
	var fwd := -camera.global_basis.z
	var spread_deg := lerpf(def.spread, def.ads_spread, ads_k) + bloom
	if not is_on_floor():
		spread_deg += 2.5
	elif Vector2(velocity.x, velocity.z).length() > 1.0:
		spread_deg *= 1.35
	if downed:
		spread_deg *= 1.3
	var space := get_world_3d().direct_space_state
	var hits := {}   # enemy_id -> [damage, head]
	var ends := PackedVector3Array()
	var range_m: float = def.range
	for i in int(def.pellets):
		var dir := _cone(fwd, deg_to_rad(spread_deg))
		var exclude: Array[RID] = [get_rid()]
		var pierce := int(def.get("pierce", 1))
		var from := origin
		var end := origin + dir * range_m
		var dmg: float = def.damage
		for _p in pierce:
			var q := PhysicsRayQueryParameters3D.create(from, origin + dir * range_m, MASK_SHOT, exclude)
			var r := space.intersect_ray(q)
			if r.is_empty():
				break
			end = r.position
			var col: Object = r.collider
			if col != null and col.has_method("local_hit"):
				var head_hit := int(r.shape) == 1
				var dist := origin.distance_to(r.position)
				var falloff := 1.0 if dist < range_m * 0.5 else lerpf(1.0, 0.55, (dist - range_m * 0.5) / (range_m * 0.5))
				var mult := (3.0 if def.get("scope", false) else 2.0) if head_hit else 1.0
				var total: float = dmg * falloff * mult
				var key: int = col.enemy_id
				if hits.has(key):
					hits[key][0] += total
					hits[key][1] = hits[key][1] or head_hit
				else:
					hits[key] = [total, head_hit]
				col.local_hit(r.position, head_hit)
				exclude.append(col.get_rid())
				from = r.position
				dmg *= 0.75
			else:
				_impact(r.position, r.normal)
				break
		if i < 4:
			ends.append(end)
		_tracer(_muzzle.global_position, end, def.get("upgraded", false))
	if def.has("chain"):
		_cinder_chain(ends[0] if ends.size() > 0 else origin + fwd * 10.0, hits, def)
	if not hits.is_empty():
		var report := []
		var any_head := false
		for k in hits:
			report.append([k, hits[k][0], hits[k][1], false])
			any_head = any_head or hits[k][1]
		game.report_hits(report)
		game.hud.hitmarker(any_head)
		Sfx.play("headshot" if any_head else "hit", -6.0 if not any_head else -2.0, 0.05)
	Sfx.play(def.sound, -3.0, 0.05)
	if not Net.solo and game.phase != "loading":
		_fx_shot.rpc(_muzzle.global_position, ends, String(def.id))
	_flash_t = 0.05
	_muzzle_flash.rotation.z = _rng.randf() * TAU
	# recoil
	var rec: float = def.recoil * lerpf(1.0, 0.6, ads_k) * (0.7 if crouching else 1.0)
	pitch = clampf(pitch + deg_to_rad(rec * 0.55), deg_to_rad(-88), deg_to_rad(88))
	yaw += deg_to_rad(_rng.randf_range(-rec, rec) * 0.18)
	_kick = minf(_kick + rec * 0.25, 1.4)
	bloom = minf(bloom + rec * 0.4, 6.0)
	if def.get("pump", false):
		get_tree().create_timer(0.32).timeout.connect(func(): Sfx.play("rack", -6.0))
	if w.mag == 0 and w.reserve > 0:
		get_tree().create_timer(0.25).timeout.connect(_start_reload)


## The Cinderbolt arcs from its impact to nearby enemies.
func _cinder_chain(point: Vector3, hits: Dictionary, def: Dictionary) -> void:
	var near := []
	for e in game.enemies.values():
		if e.dying or hits.has(e.enemy_id):
			continue
		var d: float = e.global_position.distance_to(point)
		if d < 7.0:
			near.append([d, e])
	near.sort_custom(func(a, b): return a[0] < b[0])
	var prev := point
	for i in mini(int(def.chain), near.size()):
		var e = near[i][1]
		var tp: Vector3 = e.global_position + Vector3.UP * 1.2
		hits[e.enemy_id] = [def.damage * 0.7, false]
		e.local_hit(tp, false)
		_arc(prev, tp)
		prev = tp
	_impact(point, Vector3.UP, true)


func _cone(fwd: Vector3, half_angle: float) -> Vector3:
	if half_angle <= 0.0001:
		return fwd
	var a := _rng.randf() * TAU
	var r := sqrt(_rng.randf()) * tan(half_angle)
	var right := fwd.cross(Vector3.UP).normalized()
	if right.length() < 0.1:
		right = Vector3.RIGHT
	var up := right.cross(fwd).normalized()
	return (fwd + right * cos(a) * r + up * sin(a) * r).normalized()


func _start_reload() -> void:
	var w := weapon()
	if w.is_empty() or reload_t >= 0.0 or swap_t > 0.0:
		return
	var def := weapon_def()
	if w.mag >= def.mag or w.reserve <= 0:
		return
	reload_total = float(def.reload) * (0.5 if has_perk("quickhands") else 1.0)
	reload_t = reload_total
	Sfx.play("mag_out", -4.0)


func _switch_to(i: int) -> void:
	if i == cur or i < 0 or i >= weapons.size():
		return
	cur = i
	reload_t = -1.0
	swap_t = 0.25 if has_perk("quickhands") else 0.45
	_refresh_viewmodel()
	Sfx.play("mag_in", -10.0)


func _melee() -> void:
	if melee_t > 0.0 or dead or downed or _hand_anim == "throw":
		return
	melee_t = 0.6
	_melee_hit_t = 0.15
	_start_hand("melee")
	_tp_melee = 1.0
	Sfx.play("melee", -4.0)
	if not Net.solo and game.phase != "loading":
		_fx_melee.rpc()


## The knife reaches its target: hit the nearest Husk in front of us.
func _melee_strike() -> void:
	if dead or downed:
		return
	var fwd := -camera.global_basis.z
	var best = null
	var best_d := 2.2
	for e in game.enemies.values():
		if e.dying:
			continue
		var to: Vector3 = e.global_position + Vector3.UP - camera.global_position
		var d := to.length()
		if d < best_d and fwd.dot(to.normalized()) > 0.45:
			best = e
			best_d = d
	if best:
		Sfx.play("melee_hit", -2.0)
		best.local_hit(best.global_position + Vector3.UP * 1.2, false)
		game.report_hits([[best.enemy_id, 160.0, false, true]])
		game.hud.hitmarker(false)


func refill_ammo() -> void:
	grenades = MAX_GRENADES
	for w in weapons:
		var d := W.get_def(w.id, w.upgraded)
		w.reserve = d.reserve
		w.mag = maxi(w.mag, d.mag)


func receive_weapon(id: String, upgraded: bool, ammo_only: bool) -> void:
	for i in weapons.size():
		if weapons[i].id == id and (ammo_only or weapons[i].upgraded == upgraded):
			var d := W.get_def(id, weapons[i].upgraded)
			weapons[i].reserve = d.reserve
			weapons[i].mag = d.mag
			game.hud.toast("Ammo restocked", Color("e0d0a0"))
			return
	var slot := _new_slot(id, upgraded)
	# A weapon in the forge keeps its slot reserved until it comes back.
	var reserved := 1 if forge_pending != "" else 0
	if forge_pending == id and upgraded:
		forge_pending = ""
		reserved = 0
	if weapons.size() + reserved < MAX_SLOTS:
		weapons.append(slot)
		cur = weapons.size() - 1
	else:
		weapons[cur] = slot
	reload_t = -1.0
	swap_t = 0.45
	_vm_id = ""
	_refresh_viewmodel()
	game.hud.toast("Picked up the %s" % W.get_def(id, upgraded).name, Color("ffe2b8"))


func surrender_weapon_to_forge(id: String) -> void:
	for i in weapons.size():
		if weapons[i].id == id and not weapons[i].upgraded:
			weapons.remove_at(i)
			forge_pending = id
			cur = clampi(cur, 0, maxi(weapons.size() - 1, 0))
			_vm_id = ""
			_refresh_viewmodel()
			return


func receive_perk(key: String) -> void:
	if has_perk(key):
		return
	perks.append(key)
	Sfx.play("drink", 0.0, 0.0)
	if key == "ironhide":
		max_hp = P.IRONHIDE_HEALTH
		hp = max_hp
	game.hud.toast("%s: %s" % [P.PERKS[key].name, P.PERKS[key].desc], P.PERKS[key].color.lightened(0.3))


# =========================================================================
# Effects
# =========================================================================

func _tracer(from: Vector3, to: Vector3, hot: bool) -> void:
	game.fx_root.tracer(from, to, hot)


func _arc(from: Vector3, to: Vector3) -> void:
	game.fx_root.arc(from, to, _rng)


func _impact(pos: Vector3, normal: Vector3, big := false) -> void:
	game.fx_root.impact(pos, normal, big)


@rpc("authority", "unreliable", "call_remote")
func _fx_shot(origin: Vector3, ends: PackedVector3Array, wid: String) -> void:
	_tp_kick = 1.0
	var def := W.get_def(wid)
	Sfx.play_at(def.sound, origin, 0.0)
	for e in ends:
		_tracer(origin, e, false)
	_net_weapon = wid


@rpc("authority", "unreliable", "call_remote")
func _fx_melee() -> void:
	_tp_melee = 1.0
	Sfx.play_at("melee", global_position + Vector3.UP * 1.4, -6.0)


## Another player threw a grenade (shown on their body).
func on_remote_throw() -> void:
	_tp_throw = 1.0


# =========================================================================
# Grenades and the off hand
# =========================================================================

func _throw_grenade() -> void:
	if dead or downed or _hand_anim != "" or game.phase == "loading":
		return
	if grenades <= 0:
		Sfx.play("empty")
		game.hud.toast("No grenades", Color("ff9a5a"))
		return
	grenades -= 1
	reload_t = -1.0
	_release_t = 0.27
	_start_hand("throw")
	_tp_throw = 1.0
	Sfx.play("pin", -6.0)


func _start_hand(kind: String) -> void:
	_hand_anim = kind
	_hand_t = 0.0
	_hand_knife.visible = kind == "melee"
	_hand_nade.visible = kind == "throw"


## Off-hand keyframes in camera space: [time, position, rotation].
const MELEE_KEYS := [
	[0.0, Vector3(-0.1, -0.42, -0.25), Vector3(-0.3, 0.0, 0.0)],
	[0.13, Vector3(0.2, 0.05, -0.36), Vector3(0.35, -0.55, 0.9)],
	[0.25, Vector3(-0.22, -0.14, -0.4), Vector3(-0.15, 0.75, -0.5)],
	[0.42, Vector3(-0.26, -0.5, -0.25), Vector3(-0.4, 0.6, -0.6)],
]
const THROW_KEYS := [
	[0.0, Vector3(-0.12, -0.45, -0.25), Vector3(-0.2, 0.2, 0.0)],
	[0.2, Vector3(-0.17, 0.04, -0.1), Vector3(0.9, 0.25, 0.3)],
	[0.32, Vector3(-0.05, 0.06, -0.5), Vector3(-0.55, 0.0, 0.0)],
	[0.55, Vector3(-0.12, -0.48, -0.3), Vector3(-0.4, 0.1, 0.0)],
]


func _hand_tick(dt: float) -> void:
	if _release_t >= 0.0:
		_release_t -= dt
		if _release_t < 0.0:
			_release_grenade()
	if _hand_anim == "":
		_hand_rig.visible = false
		_arm_l.visible = true
		return
	_hand_t += dt
	var keys: Array = MELEE_KEYS if _hand_anim == "melee" else THROW_KEYS
	var last: Array = keys[keys.size() - 1]
	if _hand_t >= last[0]:
		_hand_anim = ""
		_hand_rig.visible = false
		_arm_l.visible = true
		return
	var i := 0
	while i < keys.size() - 2 and _hand_t >= keys[i + 1][0]:
		i += 1
	var a: Array = keys[i]
	var b: Array = keys[i + 1]
	var f := smoothstep(0.0, 1.0, (_hand_t - a[0]) / (b[0] - a[0]))
	var qa := Quaternion.from_euler(a[2])
	var qb := Quaternion.from_euler(b[2])
	_hand_rig.transform = Transform3D(Basis(qa.slerp(qb, f)).scaled(Vector3.ONE * 0.6), (a[1] as Vector3).lerp(b[1], f))
	_hand_rig.visible = true
	_arm_l.visible = false


func _release_grenade() -> void:
	_hand_nade.visible = false
	var fwd := -camera.global_basis.z
	var origin := camera.global_position + fwd * 0.5 - camera.global_basis.x * 0.12 - Vector3.UP * 0.05
	# never start inside a wall we're hugging
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(camera.global_position, origin, 1))
	if not hit.is_empty():
		origin = hit.position - fwd * 0.15
	var vel := fwd * 12.0 + Vector3.UP * 3.2 + Vector3(velocity.x, 0, velocity.z) * 0.6
	game.throw_grenade(origin, vel)
	Sfx.play("throw", -4.0)


## Rattle the camera (grenade blasts nearby).
func shake(amount: float) -> void:
	_shake = maxf(_shake, amount)


# =========================================================================
# Interaction
# =========================================================================

func _interaction_tick(dt: float, menu: bool) -> void:
	prompt = ""
	prompt_cost = 0
	if downed:
		revive_progress = 0.0
		return
	var my_pos := global_position
	# reviving takes priority
	var target = null
	for p in game.player_nodes():
		if p != self and p.is_downed() and p.global_position.distance_to(my_pos) < 2.3:
			target = p
			break
	if target:
		var need := REVIVE_TIME * (0.5 if has_perk("secondwind") else 1.0)
		prompt = "Hold [%s] to revive %s" % [Settings.bind_label("interact"), target.display_name]
		if not menu and Input.is_action_pressed("interact"):
			revive_progress += dt / need
			if revive_progress >= 1.0:
				revive_progress = 0.0
				game.request("revive", str(target.peer_id))
		else:
			revive_progress = 0.0
		return
	revive_progress = 0.0
	var it := _focus()
	if it.is_empty():
		return
	var key := Settings.bind_label("interact")
	var cash := int(game.points.get(peer_id, 0))
	match it.kind:
		"door":
			prompt = "Press [%s] to %s" % [key, it.label]
			prompt_cost = it.cost
		"wallbuy":
			var wd := W.get_def(it.key)
			if _owns(it.key):
				prompt = "Press [%s] to buy %s ammo" % [key, wd.name]
				prompt_cost = wd.ammo_cost
			else:
				prompt = "Press [%s] to %s" % [key, it.label]
				prompt_cost = it.cost
		"tonic":
			var pd: Dictionary = P.PERKS[it.key]
			if has_perk(it.key):
				prompt = "You already carry %s" % pd.name
			else:
				prompt = "Press [%s] to %s" % [key, it.label]
				prompt_cost = it.cost
		"forge":
			var w := weapon()
			if forge_pending != "":
				prompt = "The forge is working…"
			elif w.is_empty() or w.upgraded:
				prompt = "This weapon is already reforged"
			else:
				prompt = "Press [%s] to reforge the %s" % [key, W.get_def(w.id).name]
				prompt_cost = 5000
		"cache":
			var offer: String = game.cache_offer_for(peer_id)
			if offer != "":
				prompt = "Press [%s] to take the %s" % [key, W.get_def(offer).name]
			elif game._client_cache_owner != 0:
				prompt = "The cache is stirring…"
			else:
				prompt = "Press [%s] to %s" % [key, it.label]
				prompt_cost = it.cost
	if prompt_cost > cash:
		prompt += "  (%d needed)" % prompt_cost


func _focus() -> Dictionary:
	var best := {}
	var best_d := INF
	var eye := camera.global_position
	var fwd := -camera.global_basis.z
	for it in game.arena.interactables:
		var to: Vector3 = it.pos - eye
		var d := to.length()
		if d > it.radius:
			continue
		var facing := fwd.dot(to.normalized())
		if facing < 0.25 and d > 1.0:
			continue
		var score := d - facing
		if score < best_d:
			best_d = score
			best = it
	return best


func _owns(id: String) -> bool:
	for w in weapons:
		if w.id == id:
			return true
	return false


func _interact_pressed() -> void:
	if downed or dead:
		return
	var it := _focus()
	if it.is_empty():
		return
	match it.kind:
		"door":
			game.request("door", it.key)
		"wallbuy":
			game.request("wallbuy", it.key, _owns(it.key))
		"tonic":
			if has_perk(it.key):
				return
			game.request("tonic", it.key, false)
		"forge":
			var w := weapon()
			if w.is_empty() or forge_pending != "":
				return
			game.request("forge", "forge", [w.id, w.upgraded])
		"cache":
			var owned := []
			for w in weapons:
				owned.append(w.id)
			game.request("cache", "cache", owned)


# =========================================================================
# Health, downs and revives
# =========================================================================

@rpc("any_peer", "reliable", "call_local")
func hurt(amount: float, from: Vector3) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if not is_local() or downed or dead:
		return
	if "--godmode" in OS.get_cmdline_user_args():
		return
	hp -= amount
	since_hurt = 0.0
	hurt_flash = 1.0
	hurt_dir = (from - global_position).normalized()
	Sfx.play("hurt", -2.0)
	_kick = 0.8
	if hp <= 0.0:
		_go_down()


func _go_down() -> void:
	hp = 0.0
	downed = true
	aiming = false
	reload_t = -1.0
	var had_second_wind := has_perk("secondwind")
	perks.clear()
	max_hp = P.MAX_HEALTH
	Sfx.play("downed", 0.0, 0.0)
	if Net.solo and had_second_wind:
		self_revive_t = 5.0
	else:
		self_revive_t = -1.0
	bleed_t = BLEED_TIME
	game.notify_downed()
	_send_state(1.0)


func _downed_tick(dt: float) -> void:
	if not downed:
		return
	if self_revive_t >= 0.0:
		self_revive_t -= dt
		if self_revive_t <= 0.0:
			self_revive_t = -1.0
			revive()
		return
	if Net.solo:
		return
	bleed_t -= dt
	if bleed_t <= 0.0:
		downed = false
		dead = true
		weapons = [_new_slot("tinder", false)]
		cur = 0
		_send_state(1.0)
		game.hud.toast("You bled out. You'll return next round.", Color("ff8a7a"))


func revive() -> void:
	downed = false
	hp = max_hp * 0.6
	since_hurt = 0.0
	_send_state(1.0)


func on_round_start() -> void:
	grenades = maxi(grenades, 2)
	if dead:
		dead = false
		downed = false
		hp = max_hp
		global_position = game.arena.player_spawns[0] + Vector3(0, 0.2, 0)
		velocity = Vector3.ZERO
		# Spectating turned the head to face a teammate; without a full reset
		# the view keeps that turn and movement no longer matches the camera.
		head.top_level = false
		head.transform = Transform3D(Basis(), Vector3(0, EYE, 0))
		pitch = 0.0
		weapons = [_new_slot("tinder", false)]
		cur = 0
		_vm_id = ""
		_refresh_viewmodel()
		game.hud.toast("You return to the fight.", Color("b8f0a8"))


func _spectate() -> void:
	var others: Array = game.player_nodes().filter(func(p): return p != self and p.alive())
	if others.is_empty():
		return
	var t: Node3D = others[0]
	camera.h_offset = 0.0
	camera.v_offset = 0.0
	camera.rotation.z = 0.0
	head.top_level = true
	var back: Vector3 = t.global_basis.z * 2.6 + Vector3.UP * 1.9
	head.global_position = head.global_position.lerp(t.global_position + back, 0.1)
	head.look_at(t.global_position + Vector3.UP * 1.2)
	if viewmodel:
		viewmodel.visible = false


# =========================================================================
# Network state
# =========================================================================

func _send_state(dt: float) -> void:
	_state_t -= dt
	# no state until the match starts: clients may still be loading the map
	if _state_t > 0.0 or Net.solo or game.phase == "loading":
		return
	_state_t = 1.0 / STATE_RATE
	var flags := int(sprinting) | int(crouching) << 1 | int(downed) << 2 | int(dead) << 3 | int(aiming) << 4 \
		| int(reload_t >= 0.0) << 5 | int(not is_on_floor()) << 6
	var w := weapon()
	_net_state.rpc(global_position, yaw, pitch, flags, w.get("id", ""), w.get("upgraded", false))


@rpc("authority", "unreliable_ordered", "call_remote")
func _net_state(pos: Vector3, y: float, p: float, flags: int, wid: String, upg: bool) -> void:
	_net_buf.append([Time.get_ticks_msec() / 1000.0, pos, y, p])
	if _net_buf.size() > 6:
		_net_buf.pop_front()
	_net_flags = flags
	if wid != _net_weapon or upg != _net_upgraded:
		_net_weapon = wid
		_net_upgraded = upg
		_tp_gun.mesh = M.gun(wid, upg) if wid != "" else null


func _remote_update(dt: float) -> void:
	var render_t := Time.get_ticks_msec() / 1000.0 - 0.1
	if _net_buf.size() >= 2:
		var a: Array = _net_buf[0]
		var b: Array = _net_buf[_net_buf.size() - 1]
		for i in range(_net_buf.size() - 1):
			if _net_buf[i][0] <= render_t and _net_buf[i + 1][0] >= render_t:
				a = _net_buf[i]
				b = _net_buf[i + 1]
				break
		var span: float = b[0] - a[0]
		var k := clampf((render_t - a[0]) / span, 0.0, 1.0) if span > 0.0001 else 1.0
		var np: Vector3 = (a[1] as Vector3).lerp(b[1], k)
		_remote_speed = lerpf(_remote_speed, Vector2(np.x - global_position.x, np.z - global_position.z).length() / maxf(dt, 0.001), 0.2)
		global_position = np
		rotation.y = lerp_angle(a[2], b[2], k)
		pitch = lerpf(a[3], b[3], k)
	elif _net_buf.size() == 1:
		global_position = _net_buf[0][1]
	var is_dead := _net_flags & 8 != 0
	var is_down := _net_flags & 4 != 0
	visible = not is_dead
	$Shape.disabled = is_dead
	_animate_body(dt, _remote_speed, _net_flags)
	_remote_footsteps(dt)
	_name_label.text = display_name + ("  ⚠ DOWN" if is_down else "")


## Pose the third-person body from movement speed and state flags (the
## network flags for remote players, our own state for our shadow).
func _animate_body(dt: float, spd: float, flags: int) -> void:
	_tp_phase += dt * (1.2 + spd * (2.6 if flags & 1 else 2.9))
	_tp_kick = maxf(_tp_kick - dt * 6.0, 0.0)
	_tp_melee = maxf(_tp_melee - dt / 0.38, 0.0)
	_tp_throw = maxf(_tp_throw - dt / 0.5, 0.0)
	A.survivor_pose(_parts, _body, {
		"phase": _tp_phase, "speed": spd, "pitch": pitch,
		"sprint": flags & 1 != 0, "crouch": flags & 2 != 0, "down": flags & 4 != 0, "aim": flags & 16 != 0,
		"reload": flags & 32 != 0, "air": flags & 64 != 0,
		"kick": _tp_kick, "melee": _tp_melee, "throw": _tp_throw}, dt)
