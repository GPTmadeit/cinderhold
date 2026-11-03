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

// The room behind a lit window (interior mapping): the view ray `r`
// (x along the wall, y up, z into the building) enters at `p0` on the glass
// of a box `size` metres; returns the colour of whatever it hits, lit by a
// ceiling lamp.
vec3 room(vec3 p0, vec3 r, vec3 size, float seed) {
	vec3 tt = vec3(1e5);
	if (abs(r.x) > 1e-4) tt.x = ((r.x > 0.0 ? size.x : 0.0) - p0.x) / r.x;
	if (abs(r.y) > 1e-4) tt.y = ((r.y > 0.0 ? size.y : 0.0) - p0.y) / r.y;
	tt.z = size.z / max(r.z, 1e-4);
	float t = min(tt.x, min(tt.y, tt.z));
	vec3 hp = p0 + r * t;
	vec3 wall_c = mix(vec3(0.78, 0.72, 0.62), vec3(0.58, 0.64, 0.7), h21(vec2(seed, 2.0)));
	wall_c = mix(wall_c, vec3(0.75, 0.55, 0.45), step(0.8, h21(vec2(seed, 9.0))));
	vec3 c;
	if (t == tt.z) {
		c = wall_c;
		// a cabinet or shelf against the back wall, and a picture above
		float cx = size.x * (0.25 + 0.5 * h21(vec2(seed, 3.0)));
		if (hp.y < size.y * 0.42 && abs(hp.x - cx) < size.x * 0.22) {
			c = vec3(0.2, 0.14, 0.1) * (0.8 + 0.2 * step(0.5, fract(hp.y * 6.0)));
		} else if (abs(hp.y - size.y * 0.62) < 0.18 && abs(hp.x - (size.x - cx)) < 0.25) {
			c = mix(vec3(0.3, 0.35, 0.5), vec3(0.6, 0.4, 0.3), h21(vec2(seed, 5.0)));
		}
	} else if (t == tt.x) {
		c = wall_c * 0.78;
		// a door in one side wall
		if (hp.z > size.z * 0.55 && hp.z < size.z * 0.85 && hp.y < size.y * 0.75 && (r.x > 0.0) == (h21(vec2(seed, 4.0)) > 0.5)) {
			c = vec3(0.32, 0.22, 0.15);
		}
	} else if (r.y < 0.0) {
		// floor: carpet or boards, darker toward the back
		c = mix(vec3(0.24, 0.2, 0.17), vec3(0.32, 0.22, 0.14), h21(vec2(seed, 6.0)));
		c *= 0.9 + 0.1 * step(0.5, fract(hp.x * 4.0 + hp.z * 0.2));
		// a desk or table in the middle of the room
		if (abs(hp.x - size.x * 0.5) < size.x * 0.25 && abs(hp.z - size.z * 0.45) < 0.4) c *= 0.45;
	} else {
		c = vec3(0.85, 0.83, 0.8);
	}
	// the ceiling lamp lights the room from above and the middle
	vec3 lamp = vec3(size.x * 0.5, size.y - 0.05, size.z * 0.5);
	float dl = length(hp - lamp);
	float lit = 0.35 + 0.9 / (1.0 + dl * dl * 0.8);
	if (t != tt.y || r.y < 0.0) lit *= mix(1.0, 0.75, hp.z / size.z);
	if (t == tt.y && r.y > 0.0) lit += 3.0 * exp(-dl * dl * 9.0);     // the lamp itself
	return c * lit;
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
		// view ray in the wall's frame (x along it, y up, z into the building)
		vec3 nv = normalize(NORMAL);
		vec3 dp1 = dFdx(VERTEX);
		vec3 dp2 = dFdy(VERTEX);
		vec2 du1 = dFdx(wall);
		vec2 du2 = dFdy(wall);
		vec3 tan_u = cross(dp2, nv) * du1.x + cross(nv, dp1) * du2.x;
		vec3 tan_v = cross(dp2, nv) * du1.y + cross(nv, dp1) * du2.y;
		vec3 vd = normalize(VERTEX);
		vec3 ray = vec3(dot(vd, normalize(tan_u)), dot(vd, normalize(tan_v)), max(-dot(vd, nv), 0.05));
		ray = normalize(ray);
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
		// some blinds are half down
		float blinds = h21(cell * 7.3 + 1.7);
		float pane_y = fract(g.y);
		if (mullion) {
			light = vec3(0.0);
		}
		vec3 interior = room(vec3(f.x * bay, f.y * floor_h, 0.0), ray, vec3(bay, floor_h, st == 3 ? 4.5 : 3.2), h21(cell + info.y * 3.3));
		if (blinds > 0.6 && pane_y > 0.55) {
			interior = vec3(0.7, 0.66, 0.6) * (0.45 + 0.3 * step(0.5, fract(pane_y * 24.0)));   // slats, lit from behind
		}
		vec3 sharp = lit ? light * interior : vec3(0.0);
		vec3 bay_avg = lit_bay ? light * pane : vec3(0.0);       // this bay's glow, spread over it
		vec3 street_avg = cornice ? vec3(0.0) : warm * 1.55 * lit_p * pane;   // the facade's average glow
		EMISSION = mix(mix(sharp, bay_avg, melt), street_avg, blur);
		ROUGHNESS = mix(win && !mullion ? 0.06 : mix(0.9, 0.45, wetness), 0.85, melt);
		SPECULAR = win && !mullion ? 0.8 : 0.3;
	}
}
