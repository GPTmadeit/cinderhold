shader_type sky;

// Night sky: a gradient with fire or city glow on the horizon, stars and a
// cratered moon with a halo. It never changes, so Godot renders the reflected
// sky (and SDFGI's sky light) once; the drifting clouds are a separate dome
// in front of it (shaders/clouds.gdshader).

uniform vec3 zenith : source_color = vec3(0.012, 0.014, 0.035);
uniform vec3 horizon : source_color = vec3(0.09, 0.05, 0.06);
uniform vec3 ember : source_color = vec3(0.55, 0.16, 0.04);
uniform vec3 moon_dir = vec3(-0.45, 0.42, -0.78);
uniform float star_density = 0.0025;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

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

void sky() {
	vec3 d = EYEDIR;
	vec3 md = normalize(moon_dir);
	float m = dot(d, md);
	float h = clamp(d.y, -1.0, 1.0);
	vec3 col = mix(horizon, zenith, pow(clamp(h, 0.0, 1.0), 0.45));
	// the horizon glows with the fires (or the city) beyond the walls
	col += ember * pow(1.0 - abs(h), 14.0) * (0.6 + 0.4 * sin(atan(d.x, d.z) * 3.0));
	// stars
	vec3 cell = floor(d * 520.0);
	float s = hash(cell);
	if (s < star_density && h > 0.05) {
		float tw = 0.6 + 0.4 * sin(s * 7919.0);
		col += vec3(0.8, 0.85, 1.0) * tw * smoothstep(0.05, 0.3, h) * (0.5 + s / star_density);
	}
	// the moon: a cratered disc and a halo in the air around it
	float disc = smoothstep(0.999935, 0.999955, m);
	if (disc > 0.0) {
		vec3 t1 = normalize(cross(md, vec3(0.0, 1.0, 0.0)));
		vec3 t2 = cross(t1, md);
		vec2 mp = vec2(dot(d, t1), dot(d, t2)) * 120.0;
		float maria = smoothstep(0.4, 0.7, vn(mp * 1.3 + 4.0) * 0.7 + vn(mp * 3.0) * 0.3);
		float crater = vn(mp * 7.0);
		vec3 mc = vec3(0.95, 0.94, 0.9) * (1.0 - maria * 0.35) * (0.88 + crater * 0.2);
		col = mix(col, mc * 2.4, disc);
	}
	col += vec3(0.3, 0.34, 0.45) * pow(max(m, 0.0), 900.0) * 0.5;
	col += vec3(0.1, 0.12, 0.18) * pow(max(m, 0.0), 40.0) * 0.35;
	if (h < 0.0) col = mix(horizon * 0.6, vec3(0.01), clamp(-h * 4.0, 0.0, 1.0));
	COLOR = col;
}
