shader_type spatial;
render_mode unshaded, cull_back;

// Times Square's screens, still running after the end of the world: chunky
// LED pixels, scrolling bands and a drifting logo, with dead rows and
// flicker. Each screen gets its own seed and colour.

instance uniform float seed = 0.0;
instance uniform vec3 tint : source_color = vec3(1.0, 0.4, 0.2);
uniform vec2 pixels = vec2(40.0, 22.0);

float h11(float x) {
	return fract(sin(x * 91.7) * 43758.5453);
}

void fragment() {
	vec2 px = floor(UV * pixels) / pixels;
	float t = TIME * 0.5 + seed * 17.0;
	float scene = floor(t / 6.0);                        // the ad changes every few seconds
	float kind = h11(scene + seed);
	vec3 c2 = vec3(h11(scene * 1.3 + seed), h11(scene * 2.1 + seed), h11(scene * 3.7 + seed));
	vec3 col;
	if (kind < 0.4) {
		float band = step(0.5, fract(px.x * 3.0 + t * 0.3 + sin(px.y * 7.0 + t) * 0.12));
		col = mix(tint * 0.3, tint, band);
	} else if (kind < 0.75) {
		vec2 c = vec2(0.5 + 0.28 * sin(t * 0.8), 0.5 + 0.2 * cos(t * 1.1));
		float d = length((px - c) * vec2(1.8, 1.0));
		col = mix(c2 * 0.25, mix(tint, c2, 0.5), smoothstep(0.32, 0.22, d)) + tint * step(0.92, fract(px.y * 4.0 - t));
	} else {
		col = tint * step(0.5, h11(floor(px.x * 20.0) + floor(px.y * 11.0) * 31.0 + floor(t * 8.0)));  // static
	}
	vec2 grid = fract(UV * pixels);
	float led = step(0.14, grid.x) * step(0.14, grid.y);
	float dead = step(0.93, h11(floor(px.y * pixels.y) + seed * 3.0 + floor(t * 0.5)));
	float flicker = 0.85 + 0.15 * h11(floor(TIME * 12.0) + seed);
	col *= led * (1.0 - dead) * flicker;
	ALBEDO = col * 0.25;
	EMISSION = col * 2.4;
}
