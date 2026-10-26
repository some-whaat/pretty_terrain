shader_type canvas_item;

uniform sampler2D world_mask : filter_linear, repeat_disable;

uniform float alfa_cutoff = 0.6;
uniform float land_types_cutoff = 0.5;

uniform vec3 dirt_color : source_color;
uniform vec3 grass_color : source_color = vec3(0.4, 0.7, 0.3);

uniform bool draw_coast = true; // todo: deside if I want cost and remove this bool
uniform vec2 coast_offset;
uniform vec3 coast_color : source_color;

uniform vec2 shadow_offset = vec2(-0.015, -0.02);
uniform vec3 shadow_color : source_color = vec3(0.0);


vec2 get_aspect_correct_uv(vec2 uv) {
	vec2 size = vec2(textureSize(world_mask, 0));
	vec2 max_dim = vec2(max(size.x, size.y));
	return (uv * size - size * 0.5) / max_dim + 0.5;
}

float island_alpha(vec2 uv) {
	return texture(world_mask, uv).a;
}

vec3 terrain_color(vec4 mask) {
	vec3 col = grass_color;
	if (mask.r > land_types_cutoff) { // dirt
		col = dirt_color;
	}
	if (mask.g > land_types_cutoff) { // grass
		col = grass_color;
	}
	return col;
}

void fragment() {
	vec2 uv = get_aspect_correct_uv(UV);
	vec4 mask = texture(world_mask, uv);

	//float inside = mask.a;//step(alfa_cutoff, mask.a);

	vec4 res_col;

	if (mask.a > 0.5) {
		res_col = vec4(terrain_color(mask), 1.0);
		
		if (draw_coast && island_alpha(uv + coast_offset) < alfa_cutoff) { // coast
			res_col = vec4(coast_color, 1.);
		}
	}
	else {
		res_col.a = 0.;
		if (island_alpha(uv + shadow_offset) > alfa_cutoff) { // shadow
			res_col = vec4(shadow_color, 1.);
		}
	}

	COLOR = res_col;
}