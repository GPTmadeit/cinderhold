// Rounded voxel models (see scripts/voxel/smooth_mesher.gd). The surface is a
// smoothed shell around the voxels; colours come from a 3D texture holding
// one texel per fine voxel, so painted detail stays crisp on the curves.
// Texel alpha: 1 = glowing, otherwise the per-voxel variation amount / 0.5 * 0.4.
// Vertex colour carries baked ambient occlusion.

uniform sampler3D albedo_tex : source_color, filter_linear, repeat_disable;
uniform vec3 grid_origin;        // fine-grid index of the mesh origin, minus the texture's first cell
uniform vec3 grid_size;          // texture size in cells
uniform float voxel_size = 0.03125;
uniform float emission_strength = 2.5;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.86;
#ifdef DYNAMIC
instance uniform float flash = 0.0;
instance uniform float dissolve = 0.0;
#endif

#ifndef DYNAMIC
global uniform vec4 wind;        // xy direction, z strength 0..1 (scripts/world/weather.gd)
uniform float sway = 0.0;        // how far it bends in the wind, per metre² of height
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
#ifndef DYNAMIC
	if (sway > 0.0) {
		// lean with the wind, more the higher up, with a flutter on top
		float h = max(VERTEX.y, 0.0);
		vec3 org = MODEL_MATRIX[3].xyz;
		vec3 wl = (inverse(MODEL_MATRIX) * vec4(wind.x, 0.0, wind.y, 0.0)).xyz;
		float flutter = 0.7 + 0.3 * sin(TIME * 3.3 + org.x * 1.7 + org.z * 1.3 + h * 2.5);
		VERTEX += wl * (wind.z * sway * h * h * flutter);
	}
#endif
}

void fragment() {
	// the colour just inside the surface, blended between voxels, so painted
	// detail has soft edges rather than square pixels
	vec3 g = local_pos / voxel_size + grid_origin - normalize(local_n) * 0.45;
	vec4 t = texture(albedo_tex, g / grid_size);
	// glow is read from the exact voxel, so a one-voxel eye still burns
	vec4 cell_t = texelFetch(albedo_tex, clamp(ivec3(floor(g)), ivec3(0), ivec3(grid_size) - 1), 0);
	float glow_k = max(smoothstep(0.45, 0.8, t.a), step(0.95, cell_t.a));   // plain voxels are encoded at 0.4 or less
	if (cell_t.a > 0.95) {
		t.rgb = mix(t.rgb, cell_t.rgb, 0.7);
	}
	float amt = (1.0 - glow_k) * min(t.a, 0.4) / 0.4 * 0.5;
	vec3 q = local_pos / voxel_size;
	float h = vnoise(q * 0.45) * 0.65 + vnoise(q * 1.3 + 7.0) * 0.35 - 0.5;
	vec3 c = t.rgb * max(1.0 + h * amt * 3.0, 0.0);
	vec3 lit = mix(c * COLOR.rgb, c, glow_k);
	// a soft sheen on rounded forms, like painted or waxed surfaces
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
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
	ROUGHNESS = mix(roughness_base - rim * 0.25, 0.6, glow_k);
	SPECULAR = 0.35;
	METALLIC = 0.0;
	EMISSION += c * emission_strength * glow_k;
}
