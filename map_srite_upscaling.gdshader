shader_type canvas_item;

uniform sampler2D world_curr_col : filter_linear, repeat_disable;

uniform float alfa_cutoff = 0.6;
uniform float land_types_cutoff = 0.53;

uniform vec3 dirt_color : source_color;
uniform vec3 grass_color : source_color = vec3(0.4, 0.7, 0.3);
uniform vec2 grass_blade_size = vec2(0.1, 0.15);

uniform bool draw_coast = true;
uniform vec2 coast_offset;
uniform vec3 coast_color : source_color;

uniform vec2 shadow_offset = vec2(-0.015, -0.02);
uniform vec3 shadow_color : source_color = vec3(0.0);

uniform vec3 waveline_color : source_color;
uniform float waveline_wave_scale = 33.0;
uniform float waveline_wave_speed = 3.0;
uniform float waveline_wave_amplitude = 2.0;
uniform float waveline_wave_threshold = 0.5;
uniform float waveline_alpha_power = 2.0;
uniform float waveline_cutoff = 0.00000001;

vec2 get_aspect_correct_uv(vec2 uv) {
	vec2 size = vec2(textureSize(world_curr_col, 0));
	vec2 max_dim = vec2(max(size.x, size.y));
	return (uv * size - size * 0.5) / max_dim + 0.5;
}

float island_alpha(vec2 uv) {
	return texture(world_curr_col, uv).a;
}

float sdEquilateralTriangle( in vec2 p, in float size )
{
    const float k = sqrt(3.0);
    p.x = abs(p.x) - size;
    p.y = p.y + size/k;
    if( p.x+k*p.y>0.0 ) p = vec2(p.x-k*p.y,-k*p.x-p.y)/2.0;
    p.x -= clamp( p.x, -2.0*size, 0.0 );
    return -length(p)*sign(p.y);
}

float grass_sdf(vec2 pos) {
	pos = mod(pos, grass_blade_size);
	
	return sdEquilateralTriangle(pos, 1.0);
}

vec3 terrain_color(vec4 curr_col, vec2 pos) {
	vec3 col = grass_color;
	vec3 curr_col_with_grass = curr_col.xyz;
	
	if (curr_col_with_grass.r > land_types_cutoff) {
		col = dirt_color;
	}
	if (curr_col_with_grass.g > land_types_cutoff) {
		col = grass_color;
	}
	return col;
}

vec4 waveline(float alpha) {
	float wave = sin(alpha * waveline_wave_scale + sin(TIME * waveline_wave_speed) * waveline_wave_amplitude);
	float wave_value = step(waveline_wave_threshold, wave);
	float edge_alpha = clamp(pow(alpha / alfa_cutoff, waveline_alpha_power), 0.0, 1.0) * wave_value;

	return vec4(waveline_color * wave, edge_alpha);
}

void fragment() {
	vec2 uv = get_aspect_correct_uv(UV);
	vec4 curr_col = texture(world_curr_col, uv);
	vec4 res_col;

	if (curr_col.a > alfa_cutoff) {
		res_col = vec4(terrain_color(curr_col, uv), 1.0);

		if (draw_coast && island_alpha(uv + coast_offset) < alfa_cutoff) {
			res_col = vec4(coast_color, 1.0);
		}
	} else {
		res_col.a = 0.0;

		if (curr_col.a > waveline_cutoff) {
			res_col = waveline(curr_col.a);
		}
	}

	COLOR = res_col;
}