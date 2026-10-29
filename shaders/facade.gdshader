shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// Building facades above the storefronts. UV is (metres along the wall,
// height in metres); UV2 is (building height, building seed). COLOR is the
// wall colour, with alpha picking the style: 0 brick, 1 limestone,
// 2 dark stone, 3 glass tower, 4 theatre, 7 roof. Windows are drawn on the
// voxel grid (8 per metre), and some are lit.

varying vec2 wall;
varying vec2 info;

float h21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	wall = UV;
	info = UV2;
}

void fragment() {
	int st = int(COLOR.a * 8.0 + 0.5);
	vec3 base = COLOR.rgb;
	vec2 vox = floor(wall * 8.0);
	float grain = 0.9 + 0.12 * h21(vox + info.y);
	if (st >= 7) {
		// roofs: tar and gravel with the odd vent
		ALBEDO = base * grain;
		ROUGHNESS = 0.95;
	} else {
		float floor_h = st == 3 ? 1.05 : 1.3;
		float bay = st == 3 ? 0.62 : (st == 4 ? 1.6 : 1.0);
		vec2 g = vec2(wall.x / bay, (wall.y - 0.2) / floor_h);
		vec2 cell = floor(g);
		vec2 f = floor(fract(g) * 8.0) / 8.0;
		bool win;
		if (st == 3) {
			win = f.x > 0.1 && f.y > 0.1;                       // curtain wall
		} else if (st == 4) {
			win = f.x > 0.35 && f.x < 0.65 && f.y > 0.3 && f.y < 0.75;  // theatres: few, tall
		} else {
			win = f.x > 0.24 && f.x < 0.76 && f.y > 0.24 && f.y < 0.8;
		}
		bool cornice = wall.y > info.x - 0.35;
		bool band = st == 1 && f.y < 0.13;                     // limestone string courses
		float r = h21(cell + vec2(info.y * 13.1, info.y * 7.7));
		bool lit = win && !cornice && r > (st == 3 ? 0.84 : 0.8);
		vec3 glass = st == 3 ? vec3(0.07, 0.09, 0.11) : vec3(0.035, 0.035, 0.04);
		vec3 col = base * grain;
		if (cornice || band) {
			col = base * 1.25 * grain;
		} else if (win) {
			col = glass;
		}
		ALBEDO = col;
		vec3 warm = vec3(1.0, 0.7, 0.38);
		vec3 cool = vec3(0.55, 0.75, 1.0);
		EMISSION = lit ? mix(warm, cool, step(0.95, r)) * (1.2 + 0.8 * h21(cell * 3.1)) : vec3(0.0);
		ROUGHNESS = win ? 0.3 : 0.9;
	}
}
