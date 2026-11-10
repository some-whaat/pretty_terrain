shader_type canvas_item;

uniform sampler2D world_curr_col : filter_linear, repeat_disable;

uniform float alfa_cutoff = 0.6;
uniform float land_types_cutoff = 0.53;

uniform vec3 dirt_color : source_color;
uniform vec3 grass_color : source_color;
uniform vec3 mountains_color : source_color;
uniform vec3 mountain_pieck_color : source_color;
uniform sampler2D mountains_noise : source_color;
uniform vec2 grass_blade_size = vec2(0.1, 0.15);

uniform bool draw_coast = true;
uniform vec2 coast_offset = vec2(0.003);
uniform vec3 coast_color : source_color;

//uniform vec2 shadow_offset = vec2(-0.015, -0.02);
//uniform vec3 shadow_color : source_color = vec3(0.0);

uniform vec3 waveline_color : source_color;
uniform float waveline_wave_scale = 33.0;
uniform float waveline_wave_speed = 3.0;
uniform float waveline_wave_amplitude = 2.0;
//uniform float waveline_wave_threshold = 0.5;
uniform float waveline_alpha_power = 2.0;
uniform float waveline_cutoff = 0.00000001;

uniform bool draw_grass_blades = true;
uniform float grass_blades_hight = 0.007;
uniform float grass_blades_ampletude = 70;

vec2 get_aspect_correct_uv(vec2 uv) {
	vec2 size = vec2(textureSize(world_curr_col, 0));
	vec2 max_dim = vec2(max(size.x, size.y));
	return (uv * size - size * 0.5) / max_dim + 0.5;
}

float island_alpha(vec2 uv) {
	return texture(world_curr_col, uv).a;
}

float tringle(float x, float ampletude, float hight) {
    return abs(2.0 * fract(x * ampletude) - 1.0) * hight;
}

//vec3 map_turrain_colors(vec3 in_col) {
	//vec3 col = grass_color;
	//if (in_col.r > land_types_cutoff) {
		//col = dirt_color;
	//}
	//if (in_col.b > land_types_cutoff) {
		//col = mountains_color;
	//}
	//if (in_col.g > land_types_cutoff) {
		//col = grass_color;
	//}
	//return col;
//}

vec3 terrain_color(vec3 curr_col, vec2 uv) {
	vec3 col = grass_color;
	//vec3 curr_col_with_grass = curr_col.xyz;
	
	if (draw_grass_blades && curr_col.g > land_types_cutoff) { // grass blades 
		float grass_offset = tringle(uv.x + sin(TIME * 1.3) * 0.002, grass_blades_ampletude, -grass_blades_hight);
		
		vec3 grass_blades = texture(world_curr_col, vec2(uv.x, uv.y + grass_offset)).xyz;
		
		//col = grass_blades;
		curr_col = grass_blades;
	}
	
	if (curr_col.r > land_types_cutoff) {
		col = dirt_color;
	}

	
	if (curr_col.b > land_types_cutoff) {
		float mountain_noise = texture(mountains_noise, uv).x ;
		
		vec2 mountain_uv = mod(uv, vec2(0.03))/ 0.03;
		mountain_uv.y = 1. - mountain_uv.y;
		//mountain_uv.x = (mountain_uv.x + 1.)/2.;
		
		float hight = mountain_noise * 2.;
		float mountain_hight = hight/2. - pow(mountain_uv.x - 0.5, 2) * 2.*hight;
		if (mountain_uv.y >= mountain_hight) {mountain_uv.y = 0.;}
		col = mix(mountains_color, mountain_pieck_color, mountain_uv.y);
	}
	return col;
	//return map_turrain_colors(curr_col);
}

vec4 waveline(float alpha) {
	float wave = sin(alpha * waveline_wave_scale + sin(TIME * waveline_wave_speed) * waveline_wave_amplitude);
	if (wave < 0.5) {
		wave = 0.;
	} else {
		wave = 1.;
	}
	float edge_alpha = clamp(pow(alpha / alfa_cutoff, waveline_alpha_power), 0.0, 1.0) * wave;

	return vec4(waveline_color * wave, edge_alpha);
}

void fragment() {
	vec2 uv = get_aspect_correct_uv(UV);
	vec4 curr_col = texture(world_curr_col, uv);
	vec4 res_col;

	if (curr_col.a > alfa_cutoff) {
		res_col = vec4(terrain_color(curr_col.xyz, uv), 1.0);

		if (draw_coast && island_alpha(uv + coast_offset) < alfa_cutoff) {
			res_col = vec4(coast_color, 1.0);
		}
	} else {
		res_col.a = 0.0;
		
		vec4 wave_col = vec4(0.);
		if (curr_col.a > waveline_cutoff) {
			wave_col = waveline(curr_col.a); // wave line
		}
		
		//if (island_alpha(uv + shadow_offset) > alfa_cutoff) { // shadow
			//res_col = vec4(shadow_color, 1.);
		//}
		
		res_col = wave_col;
		
	}

	COLOR = res_col;
}