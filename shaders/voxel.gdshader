shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform float roughness_base : hint_range(0.0, 1.0) = 0.85;
uniform float emission_strength = 0.0;
uniform vec3 tint : source_color = vec3(1.0);
instance uniform float flash = 0.0;
instance uniform float dissolve = 0.0;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

void fragment() {
	vec3 c = COLOR.rgb * tint;
	if (dissolve > 0.0) {
		float n = hash(floor(VERTEX * 8.0 + NODE_POSITION_WORLD * 3.0));
		if (n < dissolve) discard;
		if (n < dissolve + 0.08) { EMISSION += vec3(1.0, 0.45, 0.1) * 4.0; }
	}
	ALBEDO = mix(c, vec3(1.0), flash);
	ROUGHNESS = roughness_base;
	METALLIC = 0.0;
	EMISSION += c * emission_strength + vec3(1.0, 0.85, 0.7) * flash * 0.6;
}
