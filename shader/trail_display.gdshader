shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform vec4 trail_color : source_color = vec4(0.72, 0.83, 0.43, 1.0);

void fragment() {
    float intensity = texture(TEXTURE, UV).a;
    COLOR = vec4(trail_color.rgb, trail_color.a * intensity);
}
