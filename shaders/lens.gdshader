shader_type canvas_item;
render_mode blend_mul;

// The camera lens, multiplied over the 3D view (no screen copy needed):
// corners darken like a real lens's, and a fine moving film grain breaks up
// the clean computer-graphics gradients in the dark.

uniform float vignette = 0.32;
uniform float grain = 0.06;

void fragment() {
	vec2 uv = SCREEN_UV - 0.5;
	uv.x *= SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	float v = 1.0 - vignette * smoothstep(0.3, 0.95, length(uv));
	vec2 px = floor(FRAGCOORD.xy) + floor(fract(TIME * 0.37) * 97.0) * vec2(17.0, 31.0);
	vec3 p3 = fract(vec3(px.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	float n = fract((p3.x + p3.y) * p3.z);
	COLOR = vec4(vec3(v * (1.0 - grain * n)), 1.0);
}
