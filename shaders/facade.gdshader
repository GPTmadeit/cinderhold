shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_schlick_ggx;

// Building facades above the storefronts. UV is (metres along the wall,
// height in metres); UV2 is (building height, building seed). COLOR is the
// wall colour, with alpha picking the style: 0 brick, 1 limestone,
// 2 dark stone, 3 glass tower, 4 theatre, 7 roof. Windows are drawn on the
// voxel grid (8 per metre), and some are lit. Far away (or at a glancing
// angle) the windows shrink below a few pixels and their hard edges and lit
// panes shimmer as the camera moves, so the pattern melts into its average
// colour and glow before that.

global uniform float wetness;    // rain (scripts/world/weather.gd)

varying vec2 wall;
varying vec2 info;

// hash without sin(): sin() of large arguments differs (and jitters) between GPUs
float h21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
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
		vec2 fw = fwidth(g);
		float px = max(fw.x, fw.y);                // window bays per pixel
		float melt = smoothstep(0.07, 0.25, px);  // edges start to crawl
		float blur = smoothstep(0.35, 1.0, px);   // whole bays under a pixel
		vec2 cell = floor(g);
		vec2 f = fract(g);
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
		float lit_p = st == 3 ? 0.16 : 0.2;
		bool lit_bay = !cornice && r > 1.0 - lit_p;
		bool lit = win && lit_bay;
		vec3 glass = st == 3 ? vec3(0.07, 0.09, 0.11) : vec3(0.035, 0.035, 0.04);
		// glass picks up the sky more at a glancing angle
		float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);
		glass = mix(glass, vec3(0.16, 0.12, 0.2), fres * 0.7);
		// window frames: a mullion down the middle, a transom near the top
		vec2 fw8 = fract(g);
		bool mullion = win && st != 3 && (abs(fw8.x - 0.5) < 0.03 || abs(fw8.y - 0.66) < 0.025);
		bool ledge = st != 3 && fract(g.y) < 0.06;                       // a sill course under each floor
		// share of each bay that is glass (the masks above, on the 8-step grid)
		float pane = st == 3 ? 0.77 : (st == 4 ? 0.14 : 0.39);
		vec3 col = base * grain;
		if (cornice || band) {
			col = base * 1.25 * grain;
		} else if (mullion) {
			col = base * 0.55;
		} else if (win) {
			col = glass;
		} else if (ledge) {
			col = base * 1.12 * grain;
		}
		// soot and rain streaks running down from the sills
		float streak = h21(vec2(floor(wall.x * 6.0), info.y)) ;
		col *= 1.0 - (0.08 + 0.12 * wetness) * smoothstep(0.6, 1.0, streak) * (win ? 0.0 : 1.0);
		vec3 wall_avg = cornice ? base * 1.21 : mix(base * 0.96, glass, pane);
		ALBEDO = mix(col, wall_avg, melt);
		vec3 warm = vec3(1.0, 0.7, 0.38);
		vec3 cool = vec3(0.55, 0.75, 1.0);
		vec3 light = mix(warm, cool, step(0.95, r)) * (1.2 + 0.8 * h21(cell * 3.1));
		// rooms differ: ceiling light falls off down the pane, some blinds are half down
		float room = h21(cell * 7.3 + 1.7);
		float pane_y = fract(g.y);
		light *= mix(0.65, 1.15, smoothstep(0.24, 0.8, pane_y));
		if (room > 0.6 && pane_y > 0.55) {
			light *= 0.35 + 0.25 * step(0.5, fract(pane_y * 24.0));
		}
		if (mullion) {
			light = vec3(0.0);
		}
		vec3 sharp = lit ? light : vec3(0.0);
		vec3 bay_avg = lit_bay ? light * pane : vec3(0.0);       // this bay's glow, spread over it
		vec3 street_avg = cornice ? vec3(0.0) : warm * 1.55 * lit_p * pane;   // the facade's average glow
		EMISSION = mix(mix(sharp, bay_avg, melt), street_avg, blur);
		ROUGHNESS = mix(win && !mullion ? 0.06 : mix(0.9, 0.45, wetness), 0.85, melt);
		SPECULAR = win && !mullion ? 0.8 : 0.3;
	}
}
