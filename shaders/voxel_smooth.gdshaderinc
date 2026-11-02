// Rounded voxel models (see scripts/voxel/smooth_mesher.gd). The surface is a
// smoothed shell around the voxels; colours come from a 3D texture holding
// one texel per fine voxel, so painted detail stays crisp on the curves.
// Texel alpha: 1 = glowing, otherwise the per-voxel variation amount / 0.5 * 0.9.
// Vertex colour carries baked ambient occlusion.

uniform sampler3D albedo_tex : source_color, filter_nearest, repeat_disable;
uniform vec3 grid_origin;        // fine-grid index of the mesh origin, minus the texture's first cell
uniform vec3 grid_size;          // texture size in cells
uniform float voxel_size = 0.03125;
uniform float emission_strength = 2.5;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.86;
#ifdef DYNAMIC
instance uniform float flash = 0.0;
instance uniform float dissolve = 0.0;
#endif

varying vec3 local_pos;
varying vec3 local_n;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

// smooth value noise, so colour varies like paint and grime, not per cube
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	local_pos = VERTEX;
	local_n = NORMAL;
}

void fragment() {
	// the voxel just inside the surface
	vec3 cell = floor(local_pos / voxel_size + grid_origin - normalize(local_n) * 0.45);
	vec4 t = texture(albedo_tex, (cell + 0.5) / grid_size);
	bool glowing = t.a > 0.95;
	float amt = glowing ? 0.0 : t.a / 0.9 * 0.5;
	vec3 q = local_pos / voxel_size;
	float h = vnoise(q * 0.45) * 0.65 + vnoise(q * 1.3 + 7.0) * 0.35 - 0.5;
	vec3 c = t.rgb * max(1.0 + h * amt * 3.0, 0.0);
	vec3 lit = glowing ? c : c * COLOR.rgb;
#ifdef DYNAMIC
	if (dissolve > 0.0) {
		float n = vnoise(local_pos * 14.0 + 0.37);
		if (n < dissolve) discard;
		if (n < dissolve + 0.08) { EMISSION += vec3(1.0, 0.45, 0.1) * 4.0; }
	}
	ALBEDO = mix(lit, vec3(1.0), flash);
	EMISSION += vec3(1.0, 0.85, 0.7) * flash * 0.6;
#else
	ALBEDO = lit;
#endif
	ROUGHNESS = glowing ? 0.6 : roughness_base;
	METALLIC = 0.0;
	EMISSION += glowing ? c * emission_strength : vec3(0.0);
}
