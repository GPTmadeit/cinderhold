shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Grass clumps (arena.gd _build_grass): each blade bends with the wind
// (the `wind` global from scripts/world/weather.gd), more toward its tip,
// with a ripple that runs across the field in the wind's direction.
// UV.y is 0 at the root and 1 at the tip.

global uniform vec4 wind;
uniform vec3 root_color : source_color = vec3(0.2, 0.22, 0.09);
uniform vec3 tip_color : source_color = vec3(0.55, 0.53, 0.27);

varying float tip;
varying float shade;

void vertex() {
	tip = UV.y;
	vec3 org = MODEL_MATRIX[3].xyz;
	shade = fract(sin(dot(org.xz, vec2(12.9898, 78.233))) * 43758.5453);
	vec2 dir = wind.xy;
	float along = dot(org.xz, dir);
	float wave = sin(along * 0.9 - TIME * (1.4 + wind.z * 2.0)) * 0.5 + 0.5;
	float bend = (0.12 + wind.z * 0.55 * (0.4 + 0.6 * wave)) * tip * tip;
	float flutter = sin(TIME * 7.0 + shade * 30.0 + VERTEX.x * 9.0) * 0.03 * tip * (0.3 + wind.z);
	vec3 local_wind = (inverse(MODEL_MATRIX) * vec4(dir.x, 0.0, dir.y, 0.0)).xyz;
	VERTEX += local_wind * bend * 0.35 + vec3(flutter, -bend * 0.08, flutter);
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;      // both sides of a blade face the light the same way
	}
	vec3 c = mix(root_color, tip_color, smoothstep(0.0, 1.0, tip)) * (0.75 + shade * 0.45);
	ALBEDO = c;
	ROUGHNESS = 0.75;
	SPECULAR = 0.25;
	BACKLIGHT = c * 0.6;
	AO = mix(0.45, 1.0, tip);
}
