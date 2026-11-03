shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, fog_disabled, shadows_disabled, blend_mix;

// Drifting night cloud on a dome around the camera (scripts/world/arena.gd
// _build_clouds), drawn over the static sky so the sky itself never has to
// re-render. Lit by the moon from above, by the fires or the city from
// below, and by lightning (`flash`, set by scripts/world/weather.gd).

uniform vec3 moon_dir = vec3(-0.45, 0.42, -0.78);
uniform vec3 horizon : source_color = vec3(0.09, 0.05, 0.06);
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.45;
uniform vec3 cloud_glow : source_color = vec3(0.22, 0.08, 0.03);
uniform vec2 cloud_drift = vec2(0.006, 0.002);
uniform float flash = 0.0;

varying vec3 dir;

float h2(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vn(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h2(i), h2(i + vec2(1, 0)), f.x), mix(h2(i + vec2(0, 1)), h2(i + vec2(1, 1)), f.x), f.y);
}

float fbm(vec2 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 5; i++) {
		s += vn(p) * a;
		p = p * 2.03 + vec2(1.7, 9.2);
		a *= 0.5;
	}
	return s;
}

void vertex() {
	dir = VERTEX;
}

void fragment() {
	vec3 d = normalize(dir);
	if (d.y <= 0.0) discard;
	vec3 md = normalize(moon_dir);
	vec2 uv = d.xz / (d.y + 0.12) * 1.6 + TIME * cloud_drift;
	vec2 warp = vec2(fbm(uv * 0.5 + 3.0), fbm(uv * 0.5 + 8.0)) - 0.5;
	float n = fbm(uv + warp * 0.8);
	float edge = 1.0 - cloud_cover;
	float c = smoothstep(edge - 0.08, edge + 0.22, n) * smoothstep(0.0, 0.14, d.y);
	// a step toward the moon: thicker there means this side is in shadow
	vec2 toward = normalize(md.xz + vec2(1e-4)) * 0.12;
	float shade = smoothstep(edge - 0.08, edge + 0.3, fbm(uv + toward + warp * 0.8));
	float near_moon = pow(max(dot(d, md), 0.0), 10.0);
	vec3 col = vec3(0.05, 0.055, 0.075) * (1.0 - shade * 0.6) + vec3(0.35, 0.38, 0.48) * near_moon * (1.0 - c * 0.7);
	col += cloud_glow * (0.4 + 0.6 * pow(1.0 - d.y, 3.0)) * c;
	col += vec3(0.55, 0.6, 0.85) * flash * (0.4 + c * 1.2);
	col = mix(col, horizon * 1.1, pow(1.0 - d.y, 6.0) * 0.8);
	ALBEDO = col;
	ALPHA = c * 0.96;
}
