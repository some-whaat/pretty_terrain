shader_type texture_blit;
render_mode blend_disabled;

uniform sampler2D source_texture0 : hint_blit_source0;
uniform float fade_factor = 0.99;

void blit() {
    vec4 color = texture(source_texture0, UV);
    color.a *= fade_factor;
    COLOR0 = color;
}