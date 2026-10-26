extends Node2D

@export var antenna_stiffness := 111.0
@export var antenna_damping := 7.0


@export var antenna_left_line: Line2D
@export var antenna_right_line: Line2D

@export var antenna_right_sprite: Sprite2D
@export var antenna_left_sprite: Sprite2D

@export var antenna_right_marker: Marker2D
@export var antenna_left_marker: Marker2D

var left_antenna_velocity := Vector2.ZERO
var right_antenna_velocity := Vector2.ZERO


func generate_line(marker: Marker2D) -> Line2D:
	var new_line := Line2D.new()
	add_child(new_line)

	new_line.top_level = true
	new_line.add_point(global_position)
	new_line.add_point(marker.global_position)
	
	new_line.end_cap_mode = Line2D.LINE_CAP_ROUND
	
	return new_line


func _physics_process(delta: float) -> void:
	var left_target := antenna_left_marker.global_position
	var right_target := antenna_right_marker.global_position

	var left_force := (left_target - antenna_left_sprite.global_position) * antenna_stiffness - left_antenna_velocity * antenna_damping
	left_antenna_velocity += left_force * delta
	antenna_left_sprite.global_position += left_antenna_velocity * delta

	var right_force := (right_target - antenna_right_sprite.global_position) * antenna_stiffness - right_antenna_velocity * antenna_damping
	right_antenna_velocity += right_force * delta
	antenna_right_sprite.global_position += right_antenna_velocity * delta
	
	var right_origin : Vector2 = to_global(Vector2(0, 6))
	var left_origin : Vector2 = to_global(Vector2(0, -6))
	
	antenna_left_line.set_point_position(0, antenna_left_sprite.global_position)
	antenna_left_line.set_point_position(1, left_origin)
	antenna_right_line.set_point_position(0, antenna_right_sprite.global_position)
	antenna_right_line.set_point_position(1, right_origin)
