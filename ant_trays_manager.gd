extends Sprite2D

@export var trace_drawing_texture: Texture2D
@export var world_bounds := Rect2(-2800.0, -1800.0, 5600.0, 3600.0)
@export var texture_size := Vector2i(2048, 2048)
@export var brush_size := Vector2(36.0, 36.0)
@export_range(0.1, 600.0, 0.1) var fade_half_life_seconds := 3.0

@export var ants_parent: Node2D
@export var trail_color := Color(0.72, 0.83, 0.43, 1.0)

const TRAIL_SHADER := preload("res://shader/trail_accumulate.gdshader")
const STAMP_SHADER := preload("res://shader/trail_stamp.gdshader")
const MAX_MOUSE_STAMPS_PER_FRAME := 256

var mouse_draw_points: Array[Vector2] = []
var is_mouse_drawing := false
var last_mouse_position := Vector2.ZERO
var _viewports: Array[SubViewport] = []
var _backgrounds: Array[Sprite2D] = []
var _background_materials: Array[ShaderMaterial] = []
var _stamp_materials: Array[ShaderMaterial] = []
var _ant_sprites: Array = []
var _mouse_sprites: Array = []
var _current_viewport := 0
var _clear_requested := false

func _ready() -> void:
    if trace_drawing_texture == null:
        push_error("AntTraysManager needs a trace_drawing_texture.")
        return
    if world_bounds.size.x <= 0.0 or world_bounds.size.y <= 0.0:
        push_error("AntTraysManager world_bounds must have a positive size.")
        return
    if texture_size.x <= 0 or texture_size.y <= 0:
        push_error("AntTraysManager texture_size must be positive.")
        return

    for i in range(2):
        var viewport := SubViewport.new()
        viewport.name = "TrailBuffer%d" % i
        viewport.size = texture_size
        viewport.transparent_bg = true
        viewport.disable_3d = true
        viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
        viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
        add_child(viewport)

        var background_material := ShaderMaterial.new()
        background_material.shader = TRAIL_SHADER
        var background := Sprite2D.new()
        background.centered = true
        background.position = Vector2(texture_size) * 0.5
        background.material = background_material
        viewport.add_child(background)

        var stamp_material := ShaderMaterial.new()
        stamp_material.shader = STAMP_SHADER
        _viewports.append(viewport)
        _backgrounds.append(background)
        _background_materials.append(background_material)
        _stamp_materials.append(stamp_material)
        _ant_sprites.append([])
        _mouse_sprites.append([])

    texture = _viewports[0].get_texture()
    centered = false
    position = world_bounds.position
    scale = world_bounds.size / Vector2(texture_size)
    z_index = -1

func _input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT:
            is_mouse_drawing = event.pressed
            if event.pressed:
                last_mouse_position = get_global_mouse_position()
                _add_mouse_segment(last_mouse_position, last_mouse_position)
        elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
            mouse_draw_points.clear()
            _clear_trails()
    elif event is InputEventMouseMotion and is_mouse_drawing:
        var mouse_position := get_global_mouse_position()
        _add_mouse_segment(last_mouse_position, mouse_position)
        last_mouse_position = mouse_position

func _add_mouse_segment(from_position: Vector2, to_position: Vector2) -> void:
    var spacing := maxf(minf(brush_size.x, brush_size.y) * 0.5, 1.0)
    var distance := from_position.distance_to(to_position)
    var steps := ceili(distance / spacing)
    if steps == 0:
        _store_mouse_point(to_position)
        return

    for i in range(1, steps + 1):
        var point := from_position.lerp(to_position, float(i) / float(steps))
        _store_mouse_point(point)

func _store_mouse_point(world_position: Vector2) -> void:
    if not world_bounds.has_point(world_position):
        return

    var texture_scale := Vector2(texture_size) / world_bounds.size
    var texture_position := (world_position - world_bounds.position) * texture_scale
    var point := Vector2(
        clampf(texture_position.x, 0.0, float(texture_size.x - 1)),
        clampf(texture_position.y, 0.0, float(texture_size.y - 1))
    )
    if mouse_draw_points.is_empty() or mouse_draw_points[-1].distance_squared_to(point) > 0.01:
        mouse_draw_points.append(point)

func _process(delta: float) -> void:
    if _viewports.size() != 2 or trace_drawing_texture == null:
        return

    var destination := 1 - _current_viewport
    var background_material := _background_materials[destination]
    _backgrounds[destination].texture = _viewports[_current_viewport].get_texture()
    background_material.set_shader_parameter("fade_factor", pow(0.5, delta / maxf(fade_half_life_seconds, 0.1)))
    background_material.set_shader_parameter("clear_frame", _clear_requested)
    _stamp_materials[destination].set_shader_parameter("trail_color", trail_color)

    var texture_scale := Vector2(texture_size) / world_bounds.size
    var stamp_scale := Vector2(
        brush_size.x * texture_scale.x / float(trace_drawing_texture.get_width()),
        brush_size.y * texture_scale.y / float(trace_drawing_texture.get_height())
    )
    var ant_positions: Array[Vector2] = []
    if ants_parent != null:
        for ant in ants_parent.get_children():
            if not ant is Node2D or not world_bounds.has_point(ant.global_position):
                continue
            ant_positions.append((ant.global_position - world_bounds.position) * texture_scale)

    var mouse_count := mini(mouse_draw_points.size(), MAX_MOUSE_STAMPS_PER_FRAME)
    _ensure_stamp_pool(_ant_sprites[destination], _viewports[destination], ant_positions.size())
    _ensure_stamp_pool(_mouse_sprites[destination], _viewports[destination], mouse_count)
    _update_stamp_sprites(_ant_sprites[destination], ant_positions, stamp_scale, not _clear_requested)
    var mouse_positions: Array[Vector2] = []
    for i in range(mouse_count):
        mouse_positions.append(mouse_draw_points[i])
    _update_stamp_sprites(_mouse_sprites[destination], mouse_positions, stamp_scale, not _clear_requested)

    _viewports[destination].render_target_update_mode = SubViewport.UPDATE_ONCE
    texture = _viewports[destination].get_texture()
    _current_viewport = destination
    _clear_requested = false
    for i in range(mouse_count):
        mouse_draw_points.pop_front()

func _ensure_stamp_pool(pool: Array, viewport: SubViewport, required_count: int) -> void:
    while pool.size() < required_count:
        var stamp := Sprite2D.new()
        stamp.centered = true
        stamp.texture = trace_drawing_texture
        stamp.material = _stamp_materials[_viewports.find(viewport)]
        viewport.add_child(stamp)
        pool.append(stamp)

func _update_stamp_sprites(pool: Array, positions: Array[Vector2], stamp_scale: Vector2, should_draw: bool) -> void:
    for i in range(pool.size()):
        var stamp: Sprite2D = pool[i]
        stamp.visible = should_draw and i < positions.size()
        if stamp.visible:
            stamp.position = positions[i]
            stamp.scale = stamp_scale

func _clear_trails() -> void:
    _clear_requested = true
