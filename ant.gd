extends Node2D

@export var follow_speed: float = 3.0
@export var rotate_speed: float = 10.0 
@export var rotate_offset: float = 0.0 

func _process(delta: float) -> void:
	var mouse_pos := get_global_mouse_position()
	
	global_position = global_position.lerp(mouse_pos, follow_speed * delta)
	
	var target_angle := (mouse_pos - global_position).angle() + rotate_offset
	rotation = lerp_angle(rotation, target_angle, rotate_speed * delta)
