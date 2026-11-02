shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_schlick_ggx;

// Per-voxel colour variation is computed here from the voxel grid cell
// rather than baked into vertices, so flat faces can be greedily merged.
// Static world variant: no hit flash or dissolve, so no discard and early-z
// stays effective.
// Vertex colour alpha carries the variation amount (1.0 means "default").

uniform float roughness_base : hint_range(0.0, 1.0) = 0.85;
uniform float emission_strength = 0.0;
uniform float voxel_size = 0.0625;
uniform vec3 pivot_frac = vec3(0.5, 0.0, 0.5);
uniform vec3 tint : source_color = vec3(1.0);

global uniform float wetness;    // rain on the streets (scripts/world/weather.gd)

varying vec3 local_pos;
varying vec3 local_n;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

float vnoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(vec3(i, 0.0));
	float b = hash(vec3(i + vec2(1, 0), 0.0));
	float c = hash(vec3(i + vec2(0, 1), 0.0));
	float d = hash(vec3(i + vec2(1, 1), 0.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	local_pos = VERTEX;
	local_n = NORMAL;
}

void fragment() {
	vec3 cell = floor(local_pos / voxel_size + pivot_frac - local_n * 0.5);
	float amt = COLOR.a > 0.99 ? 0.03 : COLOR.a;
	float h = hash(cell) - 0.5;
	vec3 c = COLOR.rgb * tint * max(1.0 + h * amt * 4.0, 0.0);
	float rough = roughness_base;
	SPECULAR = 0.2;
	if (wetness > 0.0) {
		// rain: everything darker and slicker, standing water in the dips of the ground
		float n = vnoise2(local_pos.xz * 0.9) * 0.6 + vnoise2(local_pos.xz * 2.7 + 5.3) * 0.4;
		float puddle = local_n.y > 0.7 ? smoothstep(0.55, 0.7, n) * wetness : 0.0;
		c *= mix(1.0, 0.62, wetness) * mix(1.0, 0.7, puddle);
		rough = mix(rough, local_n.y > 0.7 ? 0.22 : 0.45, wetness) * (1.0 - puddle * 0.85);
		METALLIC = 0.0;
		SPECULAR = mix(0.5, 0.9, wetness);
	}
	ALBEDO = c;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	EMISSION += c * emission_strength;
}
