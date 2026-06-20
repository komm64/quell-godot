shader_type canvas_item;

uniform float time_seconds = 0.0;
uniform int mode = 0;
uniform float flash_hz = 8.0;
uniform float red_hz = 6.0;
uniform float stripe_cycles = 12.0;
uniform float unsafe_area = 0.75;
uniform float risk_envelope = 1.0;

float square_wave(float hz) {
	return step(0.5, fract(time_seconds * hz));
}

float centered_mask(vec2 uv, float area_fraction) {
	float side = sqrt(clamp(area_fraction, 0.0, 1.0));
	vec2 min_uv = vec2(0.5) - vec2(side * 0.5);
	vec2 max_uv = vec2(0.5) + vec2(side * 0.5);
	vec2 inside = step(min_uv, uv) * step(uv, max_uv);
	return inside.x * inside.y;
}

void fragment() {
	vec2 uv = UV;
	float flash = square_wave(flash_hz);
	float red_flash = square_wave(red_hz);
	float mask = centered_mask(uv, unsafe_area * mix(0.72, 1.0, risk_envelope));
	float stripe_phase = time_seconds * 0.42;
	float stripe = step(0.5, fract(uv.x * stripe_cycles + stripe_phase));
	float fine_grid = step(0.985, sin((uv.x + uv.y) * 95.0) * 0.5 + 0.5);

	vec3 calm = mix(vec3(0.02, 0.035, 0.05), vec3(0.06, 0.08, 0.10), uv.y);
	vec3 color = calm;

	if (mode == 0) {
		vec3 flash_color = mix(vec3(0.01), vec3(1.0), flash);
		color = mix(calm, flash_color, mask * mix(0.70, 1.0, risk_envelope));
	} else if (mode == 1) {
		vec3 red_a = vec3(1.0, 0.02, 0.0);
		vec3 red_b = vec3(0.02, 0.0, 0.0);
		color = mix(calm, mix(red_b, red_a, red_flash), mask * mix(0.65, 1.0, risk_envelope));
	} else if (mode == 2) {
		vec3 stripe_color = mix(vec3(0.0), vec3(1.0), stripe);
		color = mix(calm, stripe_color, mix(0.45, 0.88, risk_envelope));
	} else {
		vec3 stripes = mix(vec3(0.0), vec3(1.0, 0.92, 0.86), stripe);
		vec3 red_layer = mix(vec3(0.05, 0.0, 0.0), vec3(1.0, 0.02, 0.0), red_flash);
		vec3 flash_layer = mix(vec3(0.02), vec3(1.0), flash);
		color = mix(calm, mix(stripes, flash_layer, 0.45), mix(0.48, 0.82, risk_envelope));
		color = mix(color, red_layer, mask * mix(0.22, 0.45, risk_envelope));
	}

	color += fine_grid * 0.08;
	COLOR = vec4(clamp(color, vec3(0.0), vec3(1.0)), 1.0);
}
