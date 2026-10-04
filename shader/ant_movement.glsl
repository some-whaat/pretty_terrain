#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer InputState {
    vec4 state[];
} input_state;

layout(set = 0, binding = 1, std430) writeonly buffer OutputState {
    vec4 state[];
} output_state;

layout(set = 0, binding = 2, std140) uniform SimulationParameters {
    float delta;
    float simulation_time;
    vec2 bounds_min;
    vec2 bounds_max;
    uint ant_count;
    uint trail_width;
    uint trail_height;
    float trail_threshold;
    float sensor_distance;
    float sensor_angle_radians;
    uint sensor_sample_budget;
    float trail_follow_strength;
    vec2 bounds_size;
} params;

layout(set = 0, binding = 3) uniform sampler2D trail_field;

layout(set = 0, binding = 4, std430) writeonly buffer VisualState {
    vec4 values[]; // two vec4 values per ant: position/heading, then velocity
} visual_state;

float hash(float value) {
    return fract(sin(value * 127.1) * 43758.5453123);
}

float wrap_angle(float angle) {
    return mod(angle + 3.14159265, 6.2831853) - 3.14159265;
}

vec2 rotate_vector(vec2 value, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return vec2(c * value.x - s * value.y, s * value.x + c * value.y);
}

bool point_in_triangle(vec2 point, vec2 a, vec2 b, vec2 c) {
    float ab = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x);
    float bc = (c.x - b.x) * (point.y - b.y) - (c.y - b.y) * (point.x - b.x);
    float ca = (a.x - c.x) * (point.y - c.y) - (a.y - c.y) * (point.x - c.x);
    bool has_negative = (ab < 0.0) || (bc < 0.0) || (ca < 0.0);
    bool has_positive = (ab > 0.0) || (bc > 0.0) || (ca > 0.0);
    return !(has_negative && has_positive);
}

// Area-samples the forward triangle, skipping cells with a regular stride when over budget.
// This remains triangle sensing (not three ray samples); stride is the documented quality/performance approximation.
vec2 go_along_trail(vec2 ant_position, vec2 forward, out float signal_strength) {
    signal_strength = 0.0;
    vec2 field_max = params.bounds_min + params.bounds_size;
    if (any(lessThan(ant_position, params.bounds_min)) || any(greaterThanEqual(ant_position, field_max))) {
        return vec2(0.0);
    }

    float distance = clamp(params.sensor_distance, 1.0, 600.0);
    float half_angle = clamp(params.sensor_angle_radians, 0.0174533, 2.7925268) * 0.5;
    vec2 apex = ant_position;
    vec2 left = ant_position + rotate_vector(forward * distance, -half_angle);
    vec2 right = ant_position + rotate_vector(forward * distance, half_angle);

    vec2 triangle_min = min(apex, min(left, right));
    vec2 triangle_max = max(apex, max(left, right));
    vec2 texture_size = vec2(float(params.trail_width), float(params.trail_height));
    vec2 first_center = (triangle_min - params.bounds_min) / params.bounds_size * texture_size - vec2(0.5);
    vec2 last_center = (triangle_max - params.bounds_min) / params.bounds_size * texture_size - vec2(0.5);
    ivec2 last_valid = ivec2(int(params.trail_width) - 1, int(params.trail_height) - 1);
    ivec2 low = clamp(ivec2(floor(first_center)), ivec2(0), last_valid);
    ivec2 high = clamp(ivec2(ceil(last_center)), ivec2(0), last_valid);
    if (any(lessThan(high, low))) {
        return vec2(0.0);
    }

    ivec2 box_size = high - low + ivec2(1);
    uint budget = max(params.sensor_sample_budget, 1u);
    int stride = 1;
    while (uint((box_size.x + stride - 1) / stride) * uint((box_size.y + stride - 1) / stride) > budget) {
        stride++;
    }

    vec2 weighted_direction = vec2(0.0);
    float strongest_sample = 0.0;
    for (int y = low.y; y <= high.y; y += stride) {
        for (int x = low.x; x <= high.x; x += stride) {
            ivec2 texel = ivec2(x, y);
            vec2 pixel_center = params.bounds_min + (vec2(texel) + vec2(0.5)) / texture_size * params.bounds_size;
            if (!point_in_triangle(pixel_center, apex, left, right)) {
                continue;
            }
            float intensity = texelFetch(trail_field, texel, 0).a;
            strongest_sample = max(strongest_sample, intensity);
            weighted_direction += (pixel_center - ant_position) * intensity;
        }
    }

    if (strongest_sample <= params.trail_threshold || dot(weighted_direction, weighted_direction) < 1e-8) {
        return vec2(0.0);
    }
    signal_strength = clamp((strongest_sample - params.trail_threshold) / max(1.0 - params.trail_threshold, 1e-4), 0.0, 1.0);
    return normalize(weighted_direction);
}

void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= params.ant_count) {
        return;
    }

    uint base = id * 3u;
    vec4 position_heading = input_state.state[base];
    vec4 velocity_speed_steer = input_state.state[base + 1u];
    vec4 tuning = input_state.state[base + 2u];
    vec2 position = position_heading.xy;
    float heading = position_heading.z;
    vec2 velocity = velocity_speed_steer.xy;
    float max_speed = max(velocity_speed_steer.z, 0.0);
    float steer_force = max(velocity_speed_steer.w, 0.0);
    float rotation_speed = max(tuning.x, 0.0);
    float wander_strength = tuning.y;
    float seed = tuning.z;
    float separation_radius = max(tuning.w, 1.0);

    float random_phase = hash(seed + floor(params.simulation_time * 60.0)) * 2.0 - 1.0;
    float wander_angle = random_phase * wander_strength;
    vec2 forward = vec2(cos(heading), sin(heading));
    vec2 desired = vec2(0.); //vec2(cos(heading + wander_angle), sin(heading + wander_angle));
    // vec2 desired = vec2(cos(heading + wander_angle), sin(heading + wander_angle));

    float trail_signal = 0.0;
    vec2 trail_direction = go_along_trail(position, forward, trail_signal);
    if (trail_signal > 0.3 && dot(trail_direction, trail_direction) > 1e-8) {

        // float follow = clamp(params.trail_follow_strength * trail_signal, 0.0, 0.85);
        // desired = normalize(mix(desired, trail_direction, follow));
        desired = trail_direction;
    }
    else {
        velocity = vec2(0.0);

            // Pick a turn direction. random_phase is in [-1, 1].
            //float turn_dir = (random_phase >= 0.0) ? 1.0 : -1.0;

            heading = wrap_angle(heading + rotation_speed * params.delta / 2.0);

            output_state.state[base] = vec4(position, heading, 0.0);
            output_state.state[base + 1u] = vec4(velocity, max_speed, steer_force);
            output_state.state[base + 2u] = tuning;
            visual_state.values[id * 2u] = vec4(position, heading, 0.0);
            visual_state.values[id * 2u + 1u] = vec4(velocity, 0.0, 0.0);

            return;
    }

    vec2 separation = vec2(0.0);
    float radius_squared = separation_radius * separation_radius;
    for (uint other = 0u; other < params.ant_count; other++) {
        if (other == id) {
            continue;
        }
        vec2 away = position - input_state.state[other * 3u].xy;
        float distance_squared = dot(away, away);
        if (distance_squared < radius_squared) {
            if (distance_squared < 1e-4) {
                float angle = hash(seed + float(other) * 31.0) * 6.2831853;
                separation += vec2(cos(angle), sin(angle));
            } else {
                separation += normalize(away) * (1.0 - sqrt(distance_squared) / separation_radius);
            }
        }
    }
    if (dot(separation, separation) > 1e-4) {
        desired = normalize(desired + normalize(separation) * 2.5);
    }

    float wall_margin = max(separation_radius * 1.5, max_speed * 1.5);
    vec2 boundary_force = vec2(0.0);
    if (position.x < params.bounds_min.x + wall_margin) {
        boundary_force.x += (params.bounds_min.x + wall_margin - position.x) / wall_margin;
    }
    if (position.x > params.bounds_max.x - wall_margin) {
        boundary_force.x -= (position.x - (params.bounds_max.x - wall_margin)) / wall_margin;
    }
    if (position.y < params.bounds_min.y + wall_margin) {
        boundary_force.y += (params.bounds_min.y + wall_margin - position.y) / wall_margin;
    }
    if (position.y > params.bounds_max.y - wall_margin) {
        boundary_force.y -= (position.y - (params.bounds_max.y - wall_margin)) / wall_margin;
    }
    if (dot(boundary_force, boundary_force) > 1e-4) {
        desired = normalize(desired + normalize(boundary_force) * 4.0);
    }

    vec2 target_velocity = desired * max_speed;
    float steering_weight = clamp(steer_force * params.delta, 0.0, 1.0);
    velocity = mix(velocity, target_velocity, steering_weight);
    position += velocity * params.delta;

    if (dot(velocity, velocity) > 1e-4) {
        float target_heading = atan(velocity.y, velocity.x);
        heading += wrap_angle(target_heading - heading) * clamp(rotation_speed * params.delta, 0.0, 1.0);
    }

    output_state.state[base] = vec4(position, heading, 0.0);
    output_state.state[base + 1u] = vec4(velocity, max_speed, steer_force);
    output_state.state[base + 2u] = tuning;
    visual_state.values[id * 2u] = vec4(position, heading, 0.0);
    visual_state.values[id * 2u + 1u] = vec4(velocity, 0.0, 0.0);
}
