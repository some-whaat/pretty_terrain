shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;


uniform float pixilation_amount = 0.1;

void fragment() {
	vec2 res = (pixilation_amount / SCREEN_PIXEL_SIZE);
    
    vec2 greed_uv = floor(SCREEN_UV * res) / res;
    
    COLOR = textureLod(screen_texture, greed_uv, 0.0);
}
