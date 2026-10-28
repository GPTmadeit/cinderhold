shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled, shadows_disabled;

// Per-voxel colour variation is computed here from the voxel grid cell
// rather than baked into vertices, so flat faces can be greedily merged.
// Vertex colour alpha carries the variation amount (1.0 means "default").

uniform float roughness_base : hint_range(0.0, 1.0) = 0.85;
uniform float emission_strength = 0.0;
uniform float voxel_size = 0.0625;
uniform vec3 pivot_frac = vec3(0.5, 0.0, 0.5);
uniform vec3 tint : source_color = vec3(1.0);
instance uniform float flash = 0.0;
instance uniform float dissolve = 0.0;

varying vec3 local_pos;
varying vec3 local_n;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
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
	if (dissolve > 0.0) {
		float n = hash(floor(local_pos * 8.0) + 0.37);
		if (n < dissolve) discard;
		if (n < dissolve + 0.08) { EMISSION += vec3(1.0, 0.45, 0.1) * 4.0; }
	}
	ALBEDO = mix(c, vec3(1.0), flash);
	ROUGHNESS = roughness_base;
	METALLIC = 0.0;
	EMISSION += c * emission_strength + vec3(1.0, 0.85, 0.7) * flash * 0.6;
}
