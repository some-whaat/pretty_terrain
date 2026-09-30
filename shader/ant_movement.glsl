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
} params;

layout(set = 0, binding = 3, std430) readonly buffer TrailSignal {
	float strength[];
} trail_signal;

float hash(float value) {
	return fract(sin(value * 127.1) * 43758.5453123);
}

float wrap_angle(float angle) {
	return mod(angle + 3.14159265, 6.2831853) - 3.14159265;
}

float trail_value(ivec2 coordinate) {
	uint index = uint(coordinate.y) * params.trail_width + uint(coordinate.x);
	return trail_signal.strength[index];
}

float sample_trail(vec2 world_position) {
	vec2 uv = (world_position - params.bounds_min) / (params.bounds_max - params.bounds_min);
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return 0.0;
	}
	vec2 field_size = vec2(float(params.trail_width), float(params.trail_height));
	vec2 grid_position = clamp(uv * field_size - 0.5, vec2(0.0), field_size - 1.0);
	ivec2 lower = ivec2(floor(grid_position));
	ivec2 upper = min(lower + ivec2(1), ivec2(int(params.trail_width) - 1, int(params.trail_height) - 1));
	vec2 fraction = fract(grid_position);
	float top = mix(trail_value(ivec2(lower.x, lower.y)), trail_value(ivec2(upper.x, lower.y)), fraction.x);
	float bottom = mix(trail_value(ivec2(lower.x, upper.y)), trail_value(ivec2(upper.x, upper.y)), fraction.x);
	return mix(top, bottom, fraction.y);
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
	float max_speed = velocity_speed_steer.z;
	float steer_force = velocity_speed_steer.w;
	float rotation_speed = tuning.x;
	float wander_strength = tuning.y;
	float seed = tuning.z;
	float separation_radius = tuning.w;

	float random_phase = hash(seed + floor(params.simulation_time * 60.0)) * 2.0 - 1.0;
	float wander_angle = random_phase * wander_strength;
	vec2 desired = vec2(cos(heading + wander_angle), sin(heading + wander_angle));
	vec2 forward = vec2(cos(heading), sin(heading));
	float sensor_distance = max(max_speed * 0.2, 48.0);
	float sensor_angle = 0.62;
	vec2 left_direction = vec2(cos(heading - sensor_angle), sin(heading - sensor_angle));
	vec2 right_direction = vec2(cos(heading + sensor_angle), sin(heading + sensor_angle));
	float trail_center = sample_trail(position + forward * sensor_distance);
	float trail_left = sample_trail(position + left_direction * sensor_distance);
	float trail_right = sample_trail(position + right_direction * sensor_distance);
	float strongest_trail = max(trail_center, max(trail_left, trail_right));
	if (strongest_trail > params.trail_threshold) {
		vec2 trail_direction = forward * trail_center + left_direction * trail_left + right_direction * trail_right;
		if (dot(trail_direction, trail_direction) > 0.0001) {
			float follow_weight = clamp(0.4 + (strongest_trail - params.trail_threshold) * 2.5, 0.4, 0.85);
			desired = normalize(mix(desired, normalize(trail_direction), follow_weight));
		}
	}
	vec2 separation = vec2(0.0);
	float radius_squared = separation_radius * separation_radius;

	for (uint other = 0u; other < params.ant_count; other++) {
		if (other == id) {
			continue;
		}
		vec2 other_position = input_state.state[other * 3u].xy;
		vec2 away = position - other_position;
		float distance_squared = dot(away, away);
		if (distance_squared < radius_squared) {
			if (distance_squared < 0.0001) {
				float angle = hash(seed + float(other) * 31.0) * 6.2831853;
				away = vec2(cos(angle), sin(angle));
				separation += away;
			} else {
				separation += normalize(away) * (1.0 - sqrt(distance_squared) / separation_radius);
			}
		}
	}
	if (dot(separation, separation) > 0.0001) {
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
	if (dot(boundary_force, boundary_force) > 0.0001) {
		desired = normalize(desired + normalize(boundary_force) * 4.0);
	}

	vec2 target_velocity = desired * max_speed;
	float steering_weight = clamp(steer_force * params.delta, 0.0, 1.0);
	velocity = mix(velocity, target_velocity, steering_weight);
	position += velocity * params.delta;

	if (dot(velocity, velocity) > 0.0001) {
		float target_heading = atan(velocity.y, velocity.x);
		heading += wrap_angle(target_heading - heading) * clamp(rotation_speed * params.delta, 0.0, 1.0);
	}

	output_state.state[base] = vec4(position, heading, 0.0);
	output_state.state[base + 1u] = vec4(velocity, max_speed, steer_force);
	output_state.state[base + 2u] = tuning;
}
