// Rounded voxel models (see scripts/voxel/smooth_mesher.gd). The surface is a
// smoothed shell around the voxels; colours come from a 3D texture holding
// one texel per fine voxel, so painted detail stays crisp on the curves.
// Texel alpha (as a byte): 255 = glowing, otherwise surface class * 32 plus
// the per-voxel variation amount (0..0.5 as 0..25); classes are VB.MAT_*:
// 0 plain paint, 1 metal, 2 wood, 3 cloth, 4 skin, 5 leather, 6 gloss.
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
	// glow and the surface class are read from the exact voxel, so a one-voxel
	// eye still burns and classes don't blend into each other
	vec4 cell_t = texelFetch(albedo_tex, clamp(ivec3(floor(g)), ivec3(0), ivec3(grid_size) - 1), 0);
	int code = int(cell_t.a * 255.0 + 0.5);
	bool cell_glow = code >= 250;
	float glow_k = max(smoothstep(0.93, 0.995, t.a), cell_glow ? 1.0 : 0.0);
	if (cell_glow) {
		t.rgb = mix(t.rgb, cell_t.rgb, 0.7);
	}
	int cls = cell_glow ? 0 : code / 32;
	float amt = cell_glow ? 0.0 : float(code % 32) / 25.0 * 0.5;
	vec3 q = local_pos / voxel_size;
	float h = vnoise(q * 0.45) * 0.65 + vnoise(q * 1.3 + 7.0) * 0.35 - 0.5;
	vec3 c = t.rgb * max(1.0 + h * amt * 3.0, 0.0);
	// a soft sheen on rounded forms, like painted or waxed surfaces
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	float rough = roughness_base - rim * 0.25;
	float spec = 0.35;
	float metal = 0.0;
	if (cls == 1) {
		// metal: blued or worn steel, brass; brushed along the part, scuffed
		float brushed = vnoise(q * vec3(5.0, 5.0, 0.4)) * 0.6 + vnoise(q * vec3(0.4, 9.0, 0.4)) * 0.4;
		float scuff = smoothstep(0.72, 0.9, vnoise(q * 0.7 + 3.0));
		c = c * 1.4 * (0.88 + brushed * 0.24);
		c = mix(c, c * 1.2 + 0.015, scuff * 0.35);         // worn, polished patches
		metal = 0.82;
		rough = mix(0.42, 0.24, scuff) + (brushed - 0.5) * 0.12;
		spec = 0.5;
	} else if (cls == 2) {
		// wood: grain running along the part, darker late rings, oiled
		float grain = vnoise(q * vec3(2.5, 2.5, 0.25)) * 0.55 + vnoise(q * vec3(0.25, 2.5, 2.5)) * 0.25 + vnoise(q * 9.0) * 0.2;
		float ring = smoothstep(0.35, 0.65, fract(grain * 5.0));
		c *= 0.82 + grain * 0.28 - ring * 0.08;
		rough = 0.58 - ring * 0.08 - rim * 0.2;
		spec = 0.42;
	} else if (cls == 3) {
		// cloth: fibrous, matte, with a fuzzy sheen at grazing angles
		float weave = vnoise(q * 3.2) * 0.5 + vnoise(q * vec3(7.0, 1.2, 7.0)) * 0.5;
		c *= 0.9 + weave * 0.18;
		c += c * rim * 0.35;
		rough = 0.97;
		spec = 0.18;
	} else if (cls == 4) {
		// skin: blotchy, a little clammy, light bleeding through thin parts
		float blotch = vnoise(q * 0.55 + 11.0);
		c *= mix(vec3(1.0), vec3(1.08, 0.9, 0.92), smoothstep(0.45, 0.8, blotch));
		c *= 0.94 + vnoise(q * 4.0) * 0.1;
		rough = 0.52 - rim * 0.15;
		spec = 0.42;
		BACKLIGHT = c * vec3(0.55, 0.22, 0.16);
	} else if (cls == 5) {
		// leather: creased, waxy
		float crease = smoothstep(0.42, 0.5, vnoise(q * vec3(1.5, 3.5, 1.5)));
		c *= 0.88 + crease * 0.16;
		rough = 0.5 + crease * 0.15 - rim * 0.15;
		spec = 0.45;
	} else if (cls == 6) {
		// glass, lenses, wet surfaces
		rough = 0.1;
		spec = 0.8;
	}
	vec3 lit = mix(c * COLOR.rgb, c, glow_k);
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
	ROUGHNESS = mix(clamp(rough, 0.05, 1.0), 0.6, glow_k);
	SPECULAR = spec;
	METALLIC = metal * (1.0 - glow_k);
	EMISSION += c * emission_strength * glow_k;
}
