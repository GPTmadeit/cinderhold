shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

// A reflex sight's reticle: a bright dot with a soft halo in the middle of
// the quad, over a faint tint of coated glass. Additive, so it only ever
// brightens what's behind it.

uniform vec3 dot_color : source_color = vec3(1.0, 0.16, 0.1);
uniform float dot_radius = 0.07;   // in UV units of the (square) quad
uniform float tint = 0.035;

void fragment() {
	float r = length(UV - vec2(0.5));
	float core = 1.0 - smoothstep(dot_radius * 0.55, dot_radius, r);
	float halo = (1.0 - smoothstep(dot_radius, dot_radius * 3.0, r)) * 0.22;
	float glass = (1.0 - smoothstep(0.42, 0.5, r)) * tint;
	ALBEDO = dot_color * (core * 3.5 + halo) + vec3(0.25, 0.55, 0.45) * glass;
}
