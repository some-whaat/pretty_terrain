extends Node2D

@export var ant_leg_with: Curve
@export var ant_leg_gradient: Gradient
@export var gradient: ShaderMaterial

@export var left_leg_marker_1: Marker2D
@export var left_leg_marker_2: Marker2D
@export var left_leg_marker_3: Marker2D

@export var right_leg_marker_1: Marker2D
@export var right_leg_marker_2: Marker2D
@export var right_leg_marker_3: Marker2D

@export var leg_origin_marker_1: Marker2D
@export var leg_origin_marker_2: Marker2D
@export var leg_origin_marker_3: Marker2D


@onready var right_triangle: Array[Marker2D] = [
	right_leg_marker_1,
	left_leg_marker_2,
	right_leg_marker_3
]

@onready var left_triangle: Array[Marker2D] = [
	left_leg_marker_1,
	right_leg_marker_2,
	left_leg_marker_3
]

@onready var origins: Array[Marker2D] = [
	leg_origin_marker_1,
	leg_origin_marker_2,
	leg_origin_marker_3
]

var stepping_tween: Tween

var marker_to_leg: Dictionary[Marker2D, Line2D] = {}

@export var step_threshold: float = 55
@export var step_duration: float = 0.1
@export var step_period: float = 0.1

var is_stepping: bool = false
var step_timer: float = 0.0
var is_right_turn: bool = true

func _ready() -> void:
	generate_lines(right_triangle)
	generate_lines(left_triangle)

func generate_lines(markers: Array[Marker2D]) -> void:
	for marker in markers:
		var new_line := Line2D.new()
		add_child(new_line)

		new_line.top_level = true
		new_line.add_point(global_position)
		new_line.add_point(marker.global_position)
		
		new_line.width_curve = ant_leg_with
		new_line.gradient = ant_leg_gradient
		new_line.end_cap_mode = Line2D.LINE_CAP_ROUND
		new_line.material = gradient

		marker_to_leg[marker] = new_line

func _process(delta: float) -> void:
	step_timer += delta

	sync_origin(right_triangle)
	sync_origin(left_triangle)

	if is_right_turn:
		check_distance_and_step(right_triangle)
	else:
		check_distance_and_step(left_triangle)


func sync_origin(markers: Array[Marker2D]) -> void:
	for i in range(len(markers)):
		marker_to_leg[markers[i]].set_point_position(0, origins[i].global_position)


func check_distance_and_step(markers: Array[Marker2D]) -> void:
	if is_stepping:
		return
	if step_timer < step_period:
		return

	var should_step := false
	for marker in markers:
		var leg_end_pos: Vector2 = marker_to_leg[marker].get_point_position(1)
		if marker.global_position.distance_to(leg_end_pos) >= step_threshold:
			should_step = true
			break

	step_timer = 0.0

	if should_step:
		make_step(markers)
		is_right_turn = not is_right_turn

func make_step(markers: Array[Marker2D]) -> void:
	is_stepping = true

	if stepping_tween:
		stepping_tween.kill()
	stepping_tween = create_tween()
	stepping_tween.set_parallel(true)

	for marker in markers:
		var line: Line2D = marker_to_leg[marker]
		var start_pos: Vector2 = line.get_point_position(1)


		stepping_tween.tween_method(
			func(weight: float) -> void:
				line.set_point_position(1, start_pos.lerp(marker.global_position, weight)),
			0.0, 1.0,
			step_duration
		)

	stepping_tween.finished.connect(
		func() -> void: is_stepping = false,
		CONNECT_ONE_SHOT
	)
