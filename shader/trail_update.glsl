#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D previous_trail;
layout(rgba8, set = 0, binding = 1) uniform writeonly image2D next_trail;
layout(set = 0, binding = 2) uniform sampler2D brush_texture;

layout(set = 0, binding = 3, std430) readonly buffer MouseStamps {
    vec4 stamp[]; // world position.xy, per-stamp strength, reserved
} mouse_stamps;

layout(set = 0, binding = 4, std430) readonly buffer AntState {
    vec4 state[]; // three vec4 values per ant; first vec4.xy is world position
} ant_state;

layout(set = 0, binding = 5, std140) uniform TrailParameters {
    float delta;
    float fade_factor;
    vec2 bounds_min;
    vec2 bounds_size;
    uint trail_width;
    uint trail_height;
    uint mouse_stamp_count;
    uint ant_count;
    float mouse_brush_width;
    float mouse_brush_height;
    float ant_brush_width;
    float ant_brush_height;
    vec4 trail_color;
    float mouse_strength;
    float ant_strength;
    uint clear_flag;
} params;

float stamp_mask(vec2 world_position, vec2 stamp_position, vec2 brush_world_size) {
    vec2 local_uv = (world_position - stamp_position) / brush_world_size + vec2(0.5);
    if (any(lessThan(local_uv, vec2(0.0))) || any(greaterThanEqual(local_uv, vec2(1.0)))) {
        return 0.0;
    }
    // The brush alpha is the stamp mask. Coordinates share the field's top-left/world-min orientation.
    return texture(brush_texture, local_uv).a;
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 extent = ivec2(int(params.trail_width), int(params.trail_height));
    if (any(greaterThanEqual(pixel, extent))) {
        return;
    }

    vec4 old_value = texelFetch(previous_trail, pixel, 0);
    float intensity = params.clear_flag != 0u ? 0.0 : old_value.a;// * params.fade_factor;
    intensity *= exp(-0.3 * params.delta); // pow(0.0001, params.delta / 10.0);
    if (intensity < 0.1) {
        intensity = 0.0;
    }
    
    vec2 world_position = params.bounds_min + (vec2(pixel) + vec2(0.5)) / vec2(extent) * params.bounds_size;
    // Additional trail effects (diffusion, chemistry, etc.) belong between decay and stamping here.
    for (uint i = 0u; i < params.mouse_stamp_count; i++) {
        vec4 stamp = mouse_stamps.stamp[i];
        float mask = stamp_mask(world_position, stamp.xy, vec2(params.mouse_brush_width, params.mouse_brush_height));
        float amount = clamp(mask * params.mouse_strength * stamp.z, 0.0, 1.0);
        intensity = 1.0 - (1.0 - intensity) * (1.0 - amount);
    }
    for (uint ant = 0u; ant < params.ant_count; ant++) {
        vec2 ant_position = ant_state.state[ant * 3u].xy;
        float mask = stamp_mask(world_position, ant_position, vec2(params.ant_brush_width, params.ant_brush_height));
        float amount = clamp(mask * params.ant_strength, 0.0, 1.0);
        intensity = 1.0 - (1.0 - intensity) * (1.0 - amount);
    }

    imageStore(next_trail, pixel, vec4(params.trail_color.rgb, clamp(intensity, 0.0, 1.0)));
}
