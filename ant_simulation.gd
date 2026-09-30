extends Node

@export var world_bounds := Rect2(-2800.0, -1800.0, 5600.0, 3600.0)
@export_range(1.0, 1000.0, 1.0) var separation_radius := 150.0
#@export var camera_2d: Camera2D

const COMPUTE_SHADER_PATH := "res://shader/ant_movement.glsl"
const AGENT_FLOATS := 12
const AGENT_BYTES := AGENT_FLOATS * 4
const WORKGROUP_SIZE := 64
const DEFAULT_SIGNAL_FIELD_SIZE := Vector2i(256, 192)

var agents: Array[CharacterBody2D] = []
var _rd: RenderingDevice
var _trail_manager: Node
var _shader := RID()
var _pipeline := RID()
var _state_buffers: Array[RID] = []
var _params_buffer := RID()
var _trail_signal_buffer := RID()
var _uniform_sets: Array[RID] = []
var _current_buffer := 0
var _simulation_time := 0.0
var _trail_signal_size := DEFAULT_SIGNAL_FIELD_SIZE

func _ready() -> void:
    #var screen_size = get_viewport().get_visible_rect().size / camera_2d.zoom

    add_to_group("ant_simulation")
    _rd = RenderingServer.create_local_rendering_device()
    if _rd == null:
        push_error("AntSimulation requires a RenderingDevice-capable renderer (Forward+ or Mobile).")
        set_physics_process(false)
        return

    var shader_file := load(COMPUTE_SHADER_PATH) as RDShaderFile
    if shader_file == null:
        push_error("Could not load ant compute shader: %s" % COMPUTE_SHADER_PATH)
        set_physics_process(false)
        return
    _shader = _rd.shader_create_from_spirv(shader_file.get_spirv())
    if not _shader.is_valid():
        push_error("Failed to compile the ant movement compute shader.")
        set_physics_process(false)
        return
    _pipeline = _rd.compute_pipeline_create(_shader)
    if not _pipeline.is_valid():
        push_error("Failed to create the ant movement compute pipeline.")
        set_physics_process(false)
        return
    _trail_manager = get_tree().get_first_node_in_group("ant_trail_manager")
    if _trail_manager != null:
        world_bounds = _trail_manager.call("get_trail_world_bounds")
        _trail_signal_size = _trail_manager.call("get_trail_signal_size")
    var initial_signal := PackedFloat32Array()
    initial_signal.resize(_trail_signal_size.x * _trail_signal_size.y)
    initial_signal.fill(0.0)
    if _trail_manager != null:
        var manager_signal: PackedFloat32Array = _trail_manager.call("get_trail_signal")
        if manager_signal.size() == initial_signal.size():
            initial_signal = manager_signal
    var initial_signal_bytes := initial_signal.to_byte_array()
    _trail_signal_buffer = _rd.storage_buffer_create(initial_signal_bytes.size(), initial_signal_bytes)
    _params_buffer = _rd.uniform_buffer_create(48)

func register_ant(ant: CharacterBody2D) -> void:
    if not agents.has(ant):
        agents.append(ant)
        _rebuild_state_buffers()

func unregister_ant(ant: CharacterBody2D) -> void:
    if agents.has(ant):
        agents.erase(ant)
        _rebuild_state_buffers()

func _physics_process(delta: float) -> void:
    if agents.is_empty() or not _pipeline.is_valid():
        return
    _simulation_time += delta
    _update_trail_signal_buffer()
    _update_parameters(delta)

    var compute_list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
    _rd.compute_list_bind_uniform_set(compute_list, _uniform_sets[_current_buffer], 0)
    _rd.compute_list_dispatch(compute_list, ceili(float(agents.size()) / float(WORKGROUP_SIZE)), 1, 1)
    _rd.compute_list_end()
    _rd.submit()
    _rd.sync()

    _current_buffer = 1 - _current_buffer
    var state := _rd.buffer_get_data(_state_buffers[_current_buffer])
    for i in range(agents.size()):
        var offset := i * AGENT_BYTES
        var ant := agents[i]
        if not is_instance_valid(ant):
            continue
        var position := Vector2(state.decode_float(offset), state.decode_float(offset + 4))
        var angle := state.decode_float(offset + 8)
        var velocity := Vector2(state.decode_float(offset + 16), state.decode_float(offset + 20))
        ant.global_position = position
        ant.rotation = angle
        ant.velocity = velocity

func _rebuild_state_buffers() -> void:
    if _rd == null or not _pipeline.is_valid():
        return
    _free_state_resources()
    if agents.is_empty():
        return

    var initial_state := PackedByteArray()
    initial_state.resize(agents.size() * AGENT_BYTES)
    for i in range(agents.size()):
        var ant := agents[i]
        var offset := i * AGENT_BYTES
        initial_state.encode_float(offset, ant.global_position.x)
        initial_state.encode_float(offset + 4, ant.global_position.y)
        initial_state.encode_float(offset + 8, ant.global_rotation)
        initial_state.encode_float(offset + 12, 0.0)
        initial_state.encode_float(offset + 16, ant.velocity.x)
        initial_state.encode_float(offset + 20, ant.velocity.y)
        initial_state.encode_float(offset + 24, ant.max_speed)
        initial_state.encode_float(offset + 28, ant.steer_force)
        initial_state.encode_float(offset + 32, ant.rotation_speed)
        initial_state.encode_float(offset + 36, ant.wander_strength)
        initial_state.encode_float(offset + 40, float(i + 1) * 17.173)
        initial_state.encode_float(offset + 44, separation_radius)

    _state_buffers = [
        _rd.storage_buffer_create(initial_state.size(), initial_state),
        _rd.storage_buffer_create(initial_state.size(), initial_state)
    ]
    _uniform_sets.resize(2)
    for i in range(2):
        var uniforms: Array[RDUniform] = []
        var input_uniform := RDUniform.new()
        input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        input_uniform.binding = 0
        input_uniform.add_id(_state_buffers[i])
        uniforms.append(input_uniform)
        var output_uniform := RDUniform.new()
        output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        output_uniform.binding = 1
        output_uniform.add_id(_state_buffers[1 - i])
        uniforms.append(output_uniform)
        var params_uniform := RDUniform.new()
        params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        params_uniform.binding = 2
        params_uniform.add_id(_params_buffer)
        uniforms.append(params_uniform)
        var trail_uniform := RDUniform.new()
        trail_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        trail_uniform.binding = 3
        trail_uniform.add_id(_trail_signal_buffer)
        uniforms.append(trail_uniform)
        _uniform_sets[i] = _rd.uniform_set_create(uniforms, _shader, 0)
    _current_buffer = 0

func _update_parameters(delta: float) -> void:
    var params := PackedByteArray()
    params.resize(48)
    params.encode_float(0, delta)
    params.encode_float(4, _simulation_time)
    params.encode_float(8, world_bounds.position.x)
    params.encode_float(12, world_bounds.position.y)
    params.encode_float(16, world_bounds.end.x)
    params.encode_float(20, world_bounds.end.y)
    params.encode_u32(24, agents.size())
    params.encode_u32(28, _trail_signal_size.x)
    params.encode_u32(32, _trail_signal_size.y)
    params.encode_float(36, 0.08)
    _rd.buffer_update(_params_buffer, 0, params.size(), params)

func _update_trail_signal_buffer() -> void:
    if _trail_manager == null or not _trail_signal_buffer.is_valid():
        return
    var signal_data: PackedFloat32Array = _trail_manager.call("get_trail_signal")
    if signal_data.size() != _trail_signal_size.x * _trail_signal_size.y:
        return
    var signal_bytes := signal_data.to_byte_array()
    _rd.buffer_update(_trail_signal_buffer, 0, signal_bytes.size(), signal_bytes)

func _free_state_resources() -> void:
    for uniform_set in _uniform_sets:
        if uniform_set.is_valid():
            _rd.free_rid(uniform_set)
    _uniform_sets.clear()
    for state_buffer in _state_buffers:
        if state_buffer.is_valid():
            _rd.free_rid(state_buffer)
    _state_buffers.clear()

func _exit_tree() -> void:
    if _rd == null:
        return
    _free_state_resources()
    if _params_buffer.is_valid():
        _rd.free_rid(_params_buffer)
    if _trail_signal_buffer.is_valid():
        _rd.free_rid(_trail_signal_buffer)
    if _pipeline.is_valid():
        _rd.free_rid(_pipeline)
    if _shader.is_valid():
        _rd.free_rid(_shader)
