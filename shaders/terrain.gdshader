shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// The outpost's rounded terrain (scripts/world/terrain.gd smooth_chunk).
// The mesh only carries the big shapes; the stones, tiles, cobbles and
// planks are drawn here from the world position, with soft bevels bent into
// the normal, so nothing reads as a grid of cubes.
// Vertex colour: rgb = baked occlusion, alpha = surface id / 32 (see M_* in terrain.gd).

uniform bool detail = true;          // bevels and fine noise (off on Low)

varying vec3 wpos;
varying vec3 wnrm;

float h11(float p) { return fract(sin(p * 127.1) * 43758.5453); }
float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec2 h22(vec2 p) {
	return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y);
}

float fbm(vec2 p) {
	return vnoise(p) * 0.6 + vnoise(p * 2.7 + 13.1) * 0.4;
}

// rounded profile: 0 in the joint, rising to 1 over `bevel` past it
float pillow(float d, float joint, float bevel) {
	float e = clamp((d - joint) / bevel, 0.0, 1.0);
	return sqrt(e * (2.0 - e));
}

// Coursed stone: p = (along, up) in metres. Returns the stone's id in id,
// its distance to the nearest joint in d.
void courses(vec2 p, float y0, float ch, float len, out vec2 id, out float d) {
	float yy = p.y - y0;
	float c = floor(yy / ch);
	float fy = yy - c * ch;
	float a = p.x + h11(c * 7.13) * len;
	float k = floor(a / len);
	float b0 = k * len + (h11(k * 3.7 + c * 11.1) - 0.5) * len * 0.35;
	float b1;
	if (a < b0) {
		b1 = b0;
		k -= 1.0;
		b0 = k * len + (h11(k * 3.7 + c * 11.1) - 0.5) * len * 0.35;
	} else {
		b1 = (k + 1.0) * len + (h11((k + 1.0) * 3.7 + c * 11.1) - 0.5) * len * 0.35;
		if (a >= b1) {
			k += 1.0;
			b0 = b1;
			b1 = (k + 1.0) * len + (h11((k + 1.0) * 3.7 + c * 11.1) - 0.5) * len * 0.35;
		}
	}
	id = vec2(k, c);
	d = min(min(a - b0, b1 - a), min(fy, ch - fy));
}

// Cobbles: distance to the nearest cell border, and the cell
float cobbles(vec2 p, out vec2 cell) {
	vec2 ip = floor(p);
	vec2 fp = fract(p);
	float f1 = 8.0;
	float f2 = 8.0;
	vec2 best = vec2(0.0);
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 g = vec2(float(i), float(j));
			vec2 o = 0.2 + 0.6 * h22(ip + g);
			vec2 r = g + o - fp;
			float dd = dot(r, r);
			if (dd < f1) {
				f2 = f1;
				f1 = dd;
				best = ip + g;
			} else if (dd < f2) {
				f2 = dd;
			}
		}
	}
	cell = best;
	return sqrt(f2) - sqrt(f1);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	int mat = int(COLOR.a * 32.0);
	vec3 n = normalize(wnrm);
	bool up = abs(n.y) > 0.7;
	// along a wall: x on walls facing ±z, z on walls facing ±x
	float along = abs(n.x) > abs(n.z) ? wpos.z : wpos.x;
	vec2 wall = vec2(along, wpos.y);
	vec2 fl = wpos.xz;
	vec3 col = vec3(0.4);
	float h = 0.0;            // bevel height, metres
	float rough = 0.88;
	float grain = vnoise(wpos.xz * 9.0 + wpos.y * 7.0) * 0.5 + vnoise(vec2(along, wpos.y) * 23.0) * 0.5;

	if (mat <= 3 || mat == 10) {
		// masonry
		vec2 id;
		float d;
		if (mat == 2) {
			courses(up ? fl : wall, 0.0, 0.375, 1.1, id, d);
		} else if (mat == 3 || mat == 10) {
			courses(up ? fl : vec2(along, wpos.y * 0.25), 0.0, 0.5, 0.55, id, d);
		} else {
			courses(up ? fl * vec2(1.0, 3.0) : wall, 0.375, 0.3125, 0.72, id, d);
		}
		float hs = h21(id);
		vec3 base = mat == 2 ? vec3(0.27, 0.245, 0.25) : (mat == 3 ? vec3(0.42, 0.39, 0.38) : vec3(0.36, 0.33, 0.325));
		if (mat == 10) base = vec3(0.3, 0.28, 0.29);
		base *= 0.82 + hs * 0.32;
		base = mix(base, base * vec3(1.06, 0.98, 0.9), h21(id + 7.3));      // warm and cool stones
		float joint = 0.014;
		float p = pillow(d, joint, 0.06);
		h = p * 0.035 + (grain - 0.5) * 0.006;
		vec3 mortar = vec3(0.17, 0.155, 0.16);
		col = mix(mortar, base * (0.9 + grain * 0.2), smoothstep(joint * 0.5, joint * 1.6, d));
		if (mat == 1) {
			// moss creeping up the outdoor walls, thickest in the joints
			float mo = smoothstep(0.55, 0.85, fbm(wall * vec2(1.2, 2.5)) + (1.2 - wpos.y) * 0.25 + (1.0 - p) * 0.25);
			col = mix(col, vec3(0.2, 0.25, 0.12) * (0.8 + grain * 0.4), mo);
		}
		if (!up && mat <= 1) {
			// soot and grime: darker near the floor, streaks under the coping
			col *= mix(0.72, 1.0, smoothstep(0.0, 0.9, wpos.y));
			col *= 1.0 - 0.18 * smoothstep(0.55, 0.9, vnoise(vec2(along * 2.3, wpos.y * 0.35)));
		}
		rough = mix(0.97, 0.82, p);
	} else if (mat == 4) {
		// hall tiles: metre squares, checkered, bevelled
		vec2 f = fract(fl);
		vec2 t = floor(fl);
		float d = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
		float p = pillow(d, 0.012, 0.05);
		h = p * 0.02;
		float hs = h21(t);
		vec3 base = mod(t.x + t.y, 2.0) < 1.0 ? vec3(0.27, 0.25, 0.27) : vec3(0.34, 0.32, 0.33);
		base *= 0.9 + hs * 0.2;
		// polished, with faint veins
		float vein = smoothstep(0.03, 0.0, abs(vnoise(fl * 3.0 + hs * 10.0) - 0.5));
		base = mix(base, base * 1.35, vein * 0.5);
		col = mix(vec3(0.14, 0.13, 0.14), base, smoothstep(0.006, 0.02, d));
		rough = mix(0.9, 0.42, p);
	} else if (mat == 5) {
		// the great hall's runner: red, gold border, diamonds
		float e = wpos.z - 6.0;
		float m = abs(fract(wpos.x) - 0.5) + abs(e - 1.0) * 0.5;
		vec3 red = vec3(0.3, 0.07, 0.08);
		vec3 dark = vec3(0.2, 0.05, 0.06);
		vec3 gold = vec3(0.55, 0.4, 0.15);
		col = red;
		if (abs(m - 0.36) < 0.03) col = gold;
		else if (m < 0.18) col = dark;
		float edge = min(e, 2.0 - e);
		if (edge < 0.07) col = dark;
		else if (abs(edge - 0.14) < 0.025) col = gold;
		col *= 0.88 + vnoise(fl * 60.0) * 0.24;
		h = vnoise(fl * 80.0) * 0.002;
		rough = 1.0;
	} else if (mat == 6) {
		// courtyard cobbles
		vec2 cell;
		float d = cobbles(fl * vec2(2.6, 3.0), cell);
		float hs = h21(cell);
		float p = pillow(d, 0.05, 0.35);
		h = p * 0.03;
		vec3 base = vec3(0.25, 0.235, 0.22) * (0.65 + hs * 0.55) * (0.8 + fbm(fl * 0.7) * 0.4);
		if (hs > 0.9) base = vec3(0.26, 0.3, 0.18);
		vec3 gap = vec3(0.13, 0.115, 0.1);
		float wet = smoothstep(0.6, 0.8, fbm(fl * 0.4));
		col = mix(gap, base * (0.9 + grain * 0.2), smoothstep(0.03, 0.12, d));
		col *= mix(1.0, 0.7, wet);
		rough = mix(0.95, mix(0.8, 0.35, wet), p);
	} else if (mat == 7) {
		// garden earth: soil, mud pools, grass and pebbles
		float n1 = fbm(fl * 2.2);
		float mud = smoothstep(0.62, 0.72, fbm(fl * 0.55 + 4.0));
		col = mix(vec3(0.17, 0.13, 0.09), vec3(0.24, 0.19, 0.13), n1);
		float grass = smoothstep(0.55, 0.75, vnoise(fl * 1.4 + 9.0) * 0.7 + vnoise(fl * 30.0) * 0.45) * (1.0 - mud);
		col = mix(col, mix(vec3(0.17, 0.21, 0.08), vec3(0.3, 0.3, 0.14), vnoise(fl * 40.0)), grass);
		vec2 cell;
		float pd = cobbles(fl * 7.0, cell);
		float pebble = step(0.93, h21(cell)) * smoothstep(0.08, 0.25, pd) * (1.0 - grass);
		col = mix(col, vec3(0.33, 0.31, 0.3) * (0.8 + h21(cell + 3.0) * 0.4), pebble);
		col = mix(col, vec3(0.09, 0.07, 0.05), mud);
		h = n1 * 0.012 + grass * vnoise(fl * 45.0) * 0.01 + pebble * 0.012;
		rough = mix(0.95, 0.3, mud);
	} else if (mat == 8 || mat == 9 || mat == 11) {
		// timber: barracks boards, roof beams, door lintels
		vec2 q = up ? fl : wall;
		float w = 0.25;
		float row = floor(q.y / w);
		float plen = 2.0 + mod(row, 3.0) * 0.5;
		float t = q.x + h11(row * 1.7) * plen;
		float board = floor(t / plen);
		float fx = t - board * plen;
		float fy = q.y - row * w;
		float d = min(min(fx, plen - fx), min(fy, w - fy));
		if (mat != 8) d = min(fy, w - fy) + 1.0;     // beams: one long piece
		float p = pillow(d, 0.006, 0.03);
		float hs = h21(vec2(board, row));
		vec3 base = mat == 11 ? vec3(0.17, 0.11, 0.07) : (mat == 9 ? vec3(0.22, 0.14, 0.08) : vec3(0.3, 0.2, 0.12));
		base *= 0.8 + hs * 0.35;
		float rings = sin((fy * 40.0 + vnoise(vec2(t * 1.5, fy * 8.0 + hs * 9.0)) * 6.0) * 3.14159);
		base *= 0.9 + rings * 0.07 + vnoise(vec2(t * 0.8, fy * 60.0)) * 0.12;
		col = mix(vec3(0.07, 0.045, 0.03), base, smoothstep(0.002, 0.01, d));
		if (mat == 8) {
			// a pair of nails at each board end
			vec2 nail = vec2(min(fx, plen - fx) - 0.06, abs(fy - w * 0.5) - 0.07);
			float nd = length(nail);
			col = mix(vec3(0.1, 0.1, 0.11), col, smoothstep(0.008, 0.014, nd));
		}
		h = p * 0.012 + rings * 0.0008;
		rough = 0.8;
	}

	vec3 ao = COLOR.rgb;
	ALBEDO = col * ao;
	ROUGHNESS = rough;
	SPECULAR = 0.35;
	AO = ao.r;
	if (detail) {
		// bump from the screen-space slope of the bevel height
		vec3 dpdx = dFdx(VERTEX);
		vec3 dpdy = dFdy(VERTEX);
		float dhx = dFdx(h);
		float dhy = dFdy(h);
		vec3 nv = normalize(NORMAL);
		vec3 r1 = cross(dpdy, nv);
		vec3 r2 = cross(nv, dpdx);
		float det = dot(dpdx, r1);
		vec3 g = sign(det) * (dhx * r1 + dhy * r2);
		NORMAL = normalize(abs(det) * nv - g * 1.6);
	}
}
