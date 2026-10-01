extends StaticBody2D


@export var world_boundary_south: CollisionShape2D
@export var world_boundary_north: CollisionShape2D
@export var world_boundary_west: CollisionShape2D
@export var world_boundary_east: CollisionShape2D

@export var camera_2d: Camera2D

func _ready() -> void:
    var trail_manager := get_tree().get_first_node_in_group("ant_trail_manager")
    if trail_manager == null:
        push_warning("WorldBoundary could not find trail bounds; retaining scene-authored boundary positions.")
        return
    var bounds: Rect2 = trail_manager.call("get_trail_world_bounds")
    var center_x := bounds.position.x + bounds.size.x * 0.5
    var center_y := bounds.position.y + bounds.size.y * 0.5
    world_boundary_south.global_position = Vector2(center_x, bounds.end.y)
    world_boundary_north.global_position = Vector2(center_x, bounds.position.y)
    world_boundary_west.global_position = Vector2(bounds.end.x, center_y)
    world_boundary_east.global_position = Vector2(bounds.position.x, center_y)
