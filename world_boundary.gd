extends StaticBody2D


@export var world_boundary_south: CollisionShape2D
@export var world_boundary_north: CollisionShape2D
@export var world_boundary_west: CollisionShape2D
@export var world_boundary_east: CollisionShape2D

@export var camera_2d: Camera2D

func _ready() -> void:
    var half_screen_size := (get_viewport().get_visible_rect().size / camera_2d.zoom) / 2.
    
    world_boundary_south.global_position.y = half_screen_size.y
    world_boundary_north.global_position.y = -half_screen_size.y
    world_boundary_west.global_position.x = half_screen_size.x
    world_boundary_east.global_position.x = -half_screen_size.x
