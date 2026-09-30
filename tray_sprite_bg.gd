extends Sprite2D


func setup(trays_texture, texture_size, world_bounds) -> void:
    texture = trays_texture
    centered = false
    position = world_bounds.position
    scale = world_bounds.size / Vector2(texture_size)
    z_index = -1
