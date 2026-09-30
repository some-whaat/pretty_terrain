shader_type canvas_item;
render_mode unshaded;

uniform vec4 trail_color : source_color = vec4(0.72, 0.83, 0.43, 1.0);

void fragment() {
	COLOR = texture(TEXTURE, UV) * trail_color;
}
