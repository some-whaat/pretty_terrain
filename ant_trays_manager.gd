extends Sprite2D

@export_group("Trail Field")
@export var world_bounds := Rect2(-2800.0, -1800.0, 5600.0, 3600.0)
@export var trail_texture_size := Vector2i(896, 576)
@export_color_no_alpha var trail_color := Color(0.72, 0.83, 0.43)
@export_range(0.1, 120.0, 0.1, "or_greater") var fade_half_life_seconds := 12.0

@export_group("Brush")
@export var trace_drawing_texture: Texture2D
@export_range(1.0, 1000.0, 1.0, "or_greater") var brush_size_world := 120.0
@export_range(0.0, 1.0, 0.01) var mouse_stamp_strength := 0.55
@export_range(0.0, 1.0, 0.01) var ant_stamp_strength := 0.22
@export_range(1, 512, 1) var max_mouse_stamps_per_frame := 512

const UPDATE_SHADER_PATH := "res://shader/trail_update.glsl"
const DISPLAY_SHADER_PATH := "res://shader/trail_display.gdshader"
const MAX_STAMPS := 512
const WORKGROUP_SIZE := 8
const TRAIL_FORMAT := RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
const TRAIL_USAGE := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT

var _display_texture: Texture2DRD
var _display_material: ShaderMaterial
var _gpu_ready := false
var _rd: RenderingDevice
var _trail_textures: Array[RID] = []
var _trail_shader := RID()
var _trail_pipeline := RID()
var _trail_sampler := RID()
var _brush_texture := RID()
var _stamp_buffer := RID()
var _params_buffer := RID()
var _uniform_sets: Array[RID] = []
var _front_index := 0
var _mouse_stamps: Array[Vector2] = []
var _drawing := false
var _last_mouse_world := Vector2.ZERO
var _clear_requested := false
var _brush_bytes := PackedByteArray()
var _brush_size := Vector2i.ONE
var _update_spirv: RDShaderSPIRV

func _ready() -> void:
    add_to_group("ant_trail_manager")
    centered = false
    z_index = -1
    _display_texture = Texture2DRD.new()
    texture = _display_texture
    region_enabled = true
    region_rect = Rect2(Vector2.ZERO, Vector2(trail_texture_size))
    _display_material = ShaderMaterial.new()
    _display_material.shader = load(DISPLAY_SHADER_PATH) as Shader
    _display_material.set_shader_parameter("trail_color", trail_color)
    material = _display_material
    var update_shader := load(UPDATE_SHADER_PATH) as RDShaderFile
    if update_shader != null:
        _update_spirv = update_shader.get_spirv()
    if trace_drawing_texture != null:
        var brush_image := trace_drawing_texture.get_image()
        if brush_image != null:
            brush_image.convert(Image.FORMAT_RGBA8)
            _brush_size = brush_image.get_size()
            _brush_bytes = brush_image.get_data()
    if _brush_bytes.is_empty():
        push_warning("Trail brush texture is unavailable; a solid circular fallback brush will be used.")
        _brush_size = Vector2i(32, 32)
        var fallback := Image.create(32, 32, false, Image.FORMAT_RGBA8)
        for y in range(32):
            for x in range(32):
                var distance := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(16.0, 16.0)) / 16.0
                fallback.set_pixel(x, y, Color(1, 1, 1, clampf(1.0 - distance, 0.0, 1.0)))
        _brush_bytes = fallback.get_data()
    _update_world_sprite_transform()

func _notification(what: int) -> void:
    if what == NOTIFICATION_TRANSFORM_CHANGED:
        _update_world_sprite_transform()

func _update_world_sprite_transform() -> void:
    if trail_texture_size.x <= 0 or trail_texture_size.y <= 0:
        return
    position = world_bounds.position
    scale = world_bounds.size / Vector2(trail_texture_size)

func _input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        var button := event as InputEventMouseButton
        if button.button_index == MOUSE_BUTTON_RIGHT and button.pressed:
            clear_trails()
        elif button.button_index == MOUSE_BUTTON_LEFT:
            _drawing = button.pressed
            var world_position := get_global_mouse_position()
            if _drawing:
                _add_mouse_segment(world_position, world_position)
            _last_mouse_world = world_position
    elif event is InputEventMouseMotion and _drawing:
        var world_position := get_global_mouse_position()
        _add_mouse_segment(_last_mouse_world, world_position)
        _last_mouse_world = world_position

func _add_mouse_segment(from_world: Vector2, to_world: Vector2) -> void:
    var spacing := maxf(0.01, minf(brush_size_world * 0.25, _world_texel_size() * 0.75))
    var distance := from_world.distance_to(to_world)
    if distance < 0.001:
        if world_bounds.has_point(to_world) and _mouse_stamps.size() < MAX_STAMPS:
            _mouse_stamps.append(to_world)
        return
    var steps := maxi(1, ceili(distance / maxf(spacing, 0.01)))
    for step in range(1, steps + 1):
        var point := from_world.lerp(to_world, float(step) / float(steps))
        # Out-of-bounds points are rejected. Segment interpolation still preserves strokes crossing into the field.
        if world_bounds.has_point(point) and _mouse_stamps.size() < MAX_STAMPS:
            _mouse_stamps.append(point)

func _world_texel_size() -> float:
    var texel_world := world_bounds.size / Vector2(trail_texture_size)
    return minf(texel_world.x, texel_world.y)

func clear_trails() -> void:
    _mouse_stamps.clear()
    _clear_requested = true

func take_frame_input() -> Dictionary:
    var stamps := PackedByteArray()
    stamps.resize(mini(_mouse_stamps.size(), max_mouse_stamps_per_frame) * 16)
    for i in range(stamps.size() / 16):
        var offset := i * 16
        stamps.encode_float(offset, _mouse_stamps[i].x)
        stamps.encode_float(offset + 4, _mouse_stamps[i].y)
        stamps.encode_float(offset + 8, mouse_stamp_strength)
        stamps.encode_float(offset + 12, 0.0)
    var result := {
        "bytes": stamps,
        "count": stamps.size() / 16,
        "clear": _clear_requested
    }
    _mouse_stamps.clear()
    _clear_requested = false
    return result

func get_trail_world_bounds() -> Rect2:
    return world_bounds

func get_trail_texture_size() -> Vector2i:
    return trail_texture_size

func get_display_texture() -> Texture2DRD:
    return _display_texture

func get_front_index() -> int:
    return _front_index

func get_trail_sampler_rid() -> RID:
    return _trail_sampler

func get_trail_texture_rid(index: int) -> RID:
    if index < 0 or index >= _trail_textures.size():
        return RID()
    return _trail_textures[index]

func create_gpu_resources(rd: RenderingDevice) -> bool:
    # Called on the render thread using the same global device as ant compute and scene rendering.
    _rd = rd
    if trail_texture_size.x <= 0 or trail_texture_size.y <= 0 or world_bounds.size.x <= 0.0 or world_bounds.size.y <= 0.0:
        push_warning("Trail field has invalid bounds or dimensions; GPU trails are disabled.")
        return false
    if not _rd.texture_is_format_supported_for_usage(TRAIL_FORMAT, TRAIL_USAGE):
        push_warning("GPU does not support RGBA8 trail textures with sampling and storage usage; GPU trails are disabled.")
        return false
    var image_format := RDTextureFormat.new()
    image_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
    image_format.format = TRAIL_FORMAT
    image_format.width = trail_texture_size.x
    image_format.height = trail_texture_size.y
    image_format.depth = 1
    image_format.array_layers = 1
    image_format.mipmaps = 1
    image_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
    image_format.usage_bits = TRAIL_USAGE
    var zero_data := PackedByteArray()
    zero_data.resize(trail_texture_size.x * trail_texture_size.y * 4)
    _trail_textures = [
        _rd.texture_create(image_format, RDTextureView.new(), [zero_data]),
        _rd.texture_create(image_format, RDTextureView.new(), [zero_data])
    ]
    for i in range(_trail_textures.size()):
        if not _trail_textures[i].is_valid():
            push_warning("Could not create a GPU trail field texture; GPU trails are disabled.")
            return false
    var brush_format := RDTextureFormat.new()
    brush_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
    brush_format.format = TRAIL_FORMAT
    brush_format.width = _brush_size.x
    brush_format.height = _brush_size.y
    brush_format.depth = 1
    brush_format.array_layers = 1
    brush_format.mipmaps = 1
    brush_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
    brush_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
    _brush_texture = _rd.texture_create(brush_format, RDTextureView.new(), [_brush_bytes])
    var sampler_state := RDSamplerState.new()
    sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
    sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
    sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
    sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
    sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
    _trail_sampler = _rd.sampler_create(sampler_state)
    _stamp_buffer = _rd.storage_buffer_create(MAX_STAMPS * 16)
    _params_buffer = _rd.uniform_buffer_create(96)
    if _update_spirv == null:
        push_warning("Could not load trail update compute shader: %s" % UPDATE_SHADER_PATH)
        return false
    _trail_shader = _rd.shader_create_from_spirv(_update_spirv)
    if not _trail_shader.is_valid():
        push_warning("Could not create the trail update shader on the global RenderingDevice.")
        return false
    _trail_pipeline = _rd.compute_pipeline_create(_trail_shader)
    if not _trail_pipeline.is_valid():
        push_warning("Could not create the trail update compute pipeline.")
        return false
    _display_texture.texture_rd_rid = _trail_textures[0]
    _gpu_ready = true
    return true

func rebuild_uniform_sets(agent_state_buffers: Array[RID]) -> void:
    if not _gpu_ready:
        return
    _create_uniform_sets(agent_state_buffers)

func clear_uniform_sets() -> void:
    for set_rid in _uniform_sets:
        if set_rid.is_valid():
            _rd.free_rid(set_rid)
    _uniform_sets.clear()

func _create_uniform_sets(agent_state_buffers: Array[RID]) -> void:
    clear_uniform_sets()
    for ant_buffer_index in range(2):
        var agent_state_buffer := agent_state_buffers[ant_buffer_index] if ant_buffer_index < agent_state_buffers.size() else _stamp_buffer
        for input_index in range(2):
            var output_index := 1 - input_index
            var uniforms: Array[RDUniform] = []
            var field_uniform := RDUniform.new()
            field_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
            field_uniform.binding = 0
            field_uniform.add_id(_trail_sampler)
            field_uniform.add_id(_trail_textures[input_index])
            uniforms.append(field_uniform)
            var output_uniform := RDUniform.new()
            output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
            output_uniform.binding = 1
            output_uniform.add_id(_trail_textures[output_index])
            uniforms.append(output_uniform)
            var brush_uniform := RDUniform.new()
            brush_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
            brush_uniform.binding = 2
            brush_uniform.add_id(_trail_sampler)
            brush_uniform.add_id(_brush_texture)
            uniforms.append(brush_uniform)
            var stamp_uniform := RDUniform.new()
            stamp_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
            stamp_uniform.binding = 3
            stamp_uniform.add_id(_stamp_buffer)
            uniforms.append(stamp_uniform)
            var agent_uniform := RDUniform.new()
            agent_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
            agent_uniform.binding = 4
            agent_uniform.add_id(agent_state_buffer if agent_state_buffer.is_valid() else _stamp_buffer)
            uniforms.append(agent_uniform)
            var params_uniform := RDUniform.new()
            params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
            params_uniform.binding = 5
            params_uniform.add_id(_params_buffer)
            uniforms.append(params_uniform)
            _uniform_sets.append(_rd.uniform_set_create(uniforms, _trail_shader, 0))

func update_gpu(delta: float, agent_buffer_index: int, agent_count: int, frame_input: Dictionary) -> void:
    if not _gpu_ready:
        return
    if bool(frame_input.get("clear", false)):
        _rd.texture_clear(_trail_textures[0], Color(0, 0, 0, 0), 0, 1, 0, 1)
        _rd.texture_clear(_trail_textures[1], Color(0, 0, 0, 0), 0, 1, 0, 1)
        _front_index = 0
        _display_texture.texture_rd_rid = _trail_textures[_front_index]
        return
    var mouse_bytes: PackedByteArray = frame_input.get("bytes", PackedByteArray())
    var mouse_count := mini(int(frame_input.get("count", 0)), MAX_STAMPS)
    if not mouse_bytes.is_empty():
        _rd.buffer_update(_stamp_buffer, 0, mouse_bytes.size(), mouse_bytes)
    var safe_delta := clampf(delta, 0.0, 0.1)
    var fade := exp(-log(2.0) * safe_delta / maxf(fade_half_life_seconds, 0.01))
    var params := PackedByteArray()
    params.resize(96)
    params.encode_float(0, safe_delta)
    params.encode_float(4, fade)
    params.encode_float(8, world_bounds.position.x)
    params.encode_float(12, world_bounds.position.y)
    params.encode_float(16, world_bounds.size.x)
    params.encode_float(20, world_bounds.size.y)
    params.encode_u32(24, trail_texture_size.x)
    params.encode_u32(28, trail_texture_size.y)
    params.encode_u32(32, mouse_count)
    params.encode_u32(36, agent_count)
    var brush_height_world := brush_size_world * float(_brush_size.y) / float(maxi(_brush_size.x, 1))
    params.encode_float(40, brush_size_world)
    params.encode_float(44, brush_height_world)
    params.encode_float(48, brush_size_world)
    params.encode_float(52, brush_height_world)
    # std140 aligns vec4 trail_color to byte 64; keep these CPU offsets in lockstep with GLSL.
    params.encode_float(64, trail_color.r)
    params.encode_float(68, trail_color.g)
    params.encode_float(72, trail_color.b)
    params.encode_float(76, 1.0)
    params.encode_float(80, mouse_stamp_strength)
    params.encode_float(84, ant_stamp_strength)
    params.encode_u32(88, 0)
    _rd.buffer_update(_params_buffer, 0, params.size(), params)
    var compute_list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(compute_list, _trail_pipeline)
    _rd.compute_list_bind_uniform_set(compute_list, _uniform_sets[agent_buffer_index * 2 + _front_index], 0)
    _rd.compute_list_dispatch(compute_list, ceili(float(trail_texture_size.x) / WORKGROUP_SIZE), ceili(float(trail_texture_size.y) / WORKGROUP_SIZE), 1)
    _rd.compute_list_end()
    # The output texture is now the new authoritative field; next pass samples it, never its own target.
    _front_index = 1 - _front_index
    _display_texture.texture_rd_rid = _trail_textures[_front_index]

func free_gpu_resources() -> void:
    if _rd == null:
        return
    if _display_texture != null:
        _display_texture.texture_rd_rid = RID()
    for set_rid in _uniform_sets:
        if set_rid.is_valid():
            _rd.free_rid(set_rid)
    _uniform_sets.clear()
    for rid in [_trail_pipeline, _trail_shader, _trail_sampler, _brush_texture, _stamp_buffer, _params_buffer]:
        if rid.is_valid():
            _rd.free_rid(rid)
    for rid in _trail_textures:
        if rid.is_valid():
            _rd.free_rid(rid)
    _trail_textures.clear()
    _gpu_ready = false
