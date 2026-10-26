shader_type canvas_item;

uniform vec3 wight_color : source_color;
uniform vec3 black_color : source_color;
uniform sampler2D gray_texture : source_color;


varying vec2 global_position;

void vertex() {
    mat2 stretch_matrix = mat2(0.001);
	global_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy * stretch_matrix + vec2(0, 1.);
}

void fragment() {
	//if (COLOR.x >= 0.8) { // WHIGHT
        //COLOR.xyz = wight_color;// texture(gradient_texture, vec2(UV.x, 0.0));
    //}
    //else if (COLOR.x >= 0.2) { // GRAY
        //COLOR.xyz = texture(gray_texture, global_position.yx).xyz;
    //}
    //else { // BLACK
        //COLOR.xyz = black_color;
    //}
    COLOR.xyz = texture(gray_texture, global_position.yx).xyz * COLOR.x;
}

//void light() {
//	// Called for every pixel for every light affecting the CanvasItem.
//	// Uncomment to replace the default light processing function with this one.
//}
