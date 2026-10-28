## Weapon definitions. Damage is per pellet; rpm 0 = semi-auto handled by
## `auto`. Upgraded (reforged) weapons use the multipliers in `upgrade()`.

const DEFS := {
	"tinder": {"name": "Tinder M3", "class": "Sidearm", "cost": 500, "ammo_cost": 250,
		"damage": 34.0, "pellets": 1, "rpm": 380.0, "auto": false, "mag": 9, "reserve": 72,
		"reload": 1.4, "spread": 0.8, "ads_spread": 0.15, "recoil": 1.6, "range": 60.0,
		"sound": "pistol", "ads_fov": 0.85, "bob": 0.6, "slot_pos": Vector3(0.17, -0.17, -0.38)},
	"kestrel": {"name": "Kestrel SMG", "class": "Submachine gun", "cost": 1000, "ammo_cost": 500,
		"damage": 26.0, "pellets": 1, "rpm": 780.0, "auto": true, "mag": 32, "reserve": 192,
		"reload": 2.0, "spread": 2.4, "ads_spread": 0.8, "recoil": 0.9, "range": 45.0,
		"sound": "smg", "ads_fov": 0.82, "bob": 0.8, "slot_pos": Vector3(0.16, -0.18, -0.34)},
	"warden": {"name": "Warden Rifle", "class": "Battle rifle", "cost": 1200, "ammo_cost": 600,
		"damage": 52.0, "pellets": 1, "rpm": 520.0, "auto": true, "mag": 25, "reserve": 150,
		"reload": 2.3, "spread": 1.8, "ads_spread": 0.25, "recoil": 1.5, "range": 90.0,
		"sound": "rifle", "ads_fov": 0.72, "bob": 1.0, "slot_pos": Vector3(0.16, -0.19, -0.32)},
	"breacher": {"name": "Breacher", "class": "Pump shotgun", "cost": 1500, "ammo_cost": 750,
		"damage": 34.0, "pellets": 8, "rpm": 72.0, "auto": false, "mag": 6, "reserve": 48,
		"reload": 2.8, "spread": 5.5, "ads_spread": 4.0, "recoil": 4.5, "range": 22.0,
		"sound": "shotgun", "ads_fov": 0.88, "bob": 1.1, "pump": true, "slot_pos": Vector3(0.16, -0.19, -0.3)},
	"maul": {"name": "Maul LMG", "class": "Light machine gun", "cost": 0,
		"damage": 48.0, "pellets": 1, "rpm": 640.0, "auto": true, "mag": 80, "reserve": 320,
		"reload": 4.2, "spread": 2.8, "ads_spread": 0.9, "recoil": 1.2, "range": 80.0,
		"sound": "lmg", "ads_fov": 0.78, "bob": 1.4, "slot_pos": Vector3(0.17, -0.21, -0.3)},
	"longshot": {"name": "Longshot", "class": "Marksman rifle", "cost": 0,
		"damage": 260.0, "pellets": 1, "rpm": 55.0, "auto": false, "mag": 5, "reserve": 40,
		"reload": 3.2, "spread": 3.5, "ads_spread": 0.0, "recoil": 6.0, "range": 160.0, "pierce": 4,
		"sound": "sniper", "ads_fov": 0.35, "bob": 1.2, "scope": true, "slot_pos": Vector3(0.16, -0.2, -0.3)},
	"cinderbolt": {"name": "Cinderbolt", "class": "Relic weapon", "cost": 0,
		"damage": 900.0, "pellets": 1, "rpm": 110.0, "auto": false, "mag": 4, "reserve": 24,
		"reload": 2.6, "spread": 0.6, "ads_spread": 0.2, "recoil": 3.0, "range": 70.0, "chain": 6,
		"sound": "bolt", "ads_fov": 0.85, "bob": 1.0, "slot_pos": Vector3(0.17, -0.2, -0.34)},
}

## What the Relic Cache can roll, with weights.
const CACHE_POOL := {"kestrel": 8, "warden": 8, "breacher": 8, "maul": 7, "longshot": 6, "cinderbolt": 2}

const UPGRADED_NAMES := {
	"tinder": "Hearthfire", "kestrel": "Ember Hawk", "warden": "Ashen Warden", "breacher": "Pyre Breaker",
	"maul": "Molten Maul", "longshot": "Dusk Piercer", "cinderbolt": "Sunforge Bolt",
}


static func get_def(id: String, upgraded := false) -> Dictionary:
	var d: Dictionary = DEFS[id].duplicate()
	d.id = id
	d.upgraded = upgraded
	if upgraded:
		d.name = UPGRADED_NAMES[id]
		d.damage *= 2.2
		d.mag = int(ceil(d.mag * 1.5))
		d.reserve = int(d.reserve * 1.6)
		d.reload *= 0.85
		d.spread *= 0.8
	return d


static func roll_cache(exclude: Array, rng: RandomNumberGenerator) -> String:
	var total := 0
	for id in CACHE_POOL:
		if not id in exclude:
			total += CACHE_POOL[id]
	var r := rng.randi_range(1, maxi(total, 1))
	for id in CACHE_POOL:
		if id in exclude:
			continue
		r -= CACHE_POOL[id]
		if r <= 0:
			return id
	return "maul"
