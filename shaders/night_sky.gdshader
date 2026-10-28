shader_type sky;

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

void sky() {
	vec3 d = EYEDIR;
	float h = clamp(d.y, -1.0, 1.0);
	vec3 col = mix(horizon, zenith, pow(clamp(h, 0.0, 1.0), 0.45));
	// burning horizon: the ash wastes glow from the fires beyond the walls
	col += ember * pow(1.0 - abs(h), 14.0) * (0.6 + 0.4 * sin(atan(d.x, d.z) * 3.0 + TIME * 0.05));
	// stars
	vec3 cell = floor(d * 520.0);
	float s = hash(cell);
	if (s < star_density && h > 0.05) {
		float tw = 0.6 + 0.4 * sin(TIME * (2.0 + s * 40.0) + s * 100.0);
		col += vec3(0.8, 0.85, 1.0) * tw * smoothstep(0.05, 0.3, h) * (0.5 + s / star_density);
	}
	// moon with a soft halo
	vec3 md = normalize(moon_dir);
	float m = dot(d, md);
	col += vec3(0.85, 0.88, 1.0) * smoothstep(0.99955, 0.99975, m) * 2.0;
	col += vec3(0.25, 0.3, 0.45) * pow(max(m, 0.0), 120.0) * 0.6;
	if (h < 0.0) col = mix(horizon * 0.6, vec3(0.01), clamp(-h * 4.0, 0.0, 1.0));
	COLOR = col;
}
