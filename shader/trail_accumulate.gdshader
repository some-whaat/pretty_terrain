shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform float fade_factor = 0.99;
uniform bool clear_frame = false;

void fragment() {
	if (clear_frame) {
		COLOR = vec4(0.0);
	} else {
		vec4 trail = texture(TEXTURE, UV);
		trail.a *= fade_factor;
		COLOR = trail;
	}
}
