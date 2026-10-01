extends Node

@export var world_bounds := Rect2(-2800.0, -1800.0, 5600.0, 3600.0)
@export_range(1.0, 1000.0, 1.0) var separation_radius := 150.0
@export_group("Trail Sensing")
@export_range(1.0, 600.0, 1.0) var sensor_distance := 220.0
@export_range(1.0, 160.0, 1.0) var sensor_angle_degrees := 72.0
@export_range(32, 4096, 32) var sensor_sample_budget := 512
@export_range(0.0, 1.0, 0.01) var trail_threshold := 0.04
@export_range(0.0, 1.0, 0.01) var trail_follow_strength := 0.78

const COMPUTE_SHADER_PATH := "res://shader/ant_movement.glsl"
const AGENT_BYTES := 48
const VISUAL_AGENT_BYTES := 32
const WORKGROUP_SIZE := 64

var agents: Array[CharacterBody2D] = []
var _trail_manager: Node
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _params_buffer := RID()
var _state_buffers: Array[RID] = []
var _visual_buffer := RID()
var _uniform_sets: Array[RID] = []
var _current_buffer := 0
var _simulation_time := 0.0
var _state_dirty := true
var _agent_generation := 0
var _gpu_failed := false
var _requested_agent_count := -1

func _ready() -> void:
    add_to_group("ant_simulation")
    _trail_manager = get_tree().get_first_node_in_group("ant_trail_manager")
    if _trail_manager == null:
        push_error("AntSimulation requires an AntTraysManager in the 'ant_trail_manager' group.")
        set_physics_process(false)
        return
    world_bounds = _trail_manager.call("get_trail_world_bounds")
    _rd = RenderingServer.get_rendering_device()
    if _rd == null or RenderingServer.get_current_rendering_method() == "gl_compatibility":
        push_warning("Unified GPU trails are disabled: use a display runtime with the Forward Plus or Mobile RenderingDevice renderer (not Compatibility/headless).")
        _gpu_failed = true
        set_physics_process(false)
        return
    var shader_file := load(COMPUTE_SHADER_PATH) as RDShaderFile
    if shader_file == null:
        push_error("Could not load ant compute shader: %s" % COMPUTE_SHADER_PATH)
        _gpu_failed = true
        set_physics_process(false)
        return
    var spirv := shader_file.get_spirv()
    RenderingServer.call_on_render_thread(Callable(self, "_initialize_gpu").bind(spirv))

func register_ant(ant: CharacterBody2D) -> void:
    if not agents.has(ant):
        agents.append(ant)
        _state_dirty = true
        _agent_generation += 1

func unregister_ant(ant: CharacterBody2D) -> void:
    if agents.has(ant):
        agents.erase(ant)
        _state_dirty = true
        _agent_generation += 1

func _physics_process(delta: float) -> void:
    if _gpu_failed or _rd == null:
        return
    for i in range(agents.size() - 1, -1, -1):
        if not is_instance_valid(agents[i]):
            agents.remove_at(i)
            _state_dirty = true
    if agents.size() != _requested_agent_count:
        _state_dirty = true
        _requested_agent_count = agents.size()
    _simulation_time += delta
    var initial_state := _build_initial_state() if _state_dirty else PackedByteArray()
    var frame_input: Dictionary = _trail_manager.call("take_frame_input")
    var generation := _agent_generation
    # This single render-thread callback records decay/stamps before ant sensing and movement.
    RenderingServer.call_on_render_thread(
        Callable(self, "_run_gpu_frame").bind(delta, _simulation_time, initial_state, _state_dirty, frame_input, agents.size(), generation)
    )
    _state_dirty = false

func _build_initial_state() -> PackedByteArray:
    var data := PackedByteArray()
    data.resize(maxi(agents.size(), 1) * AGENT_BYTES)
    for i in range(agents.size()):
        var ant := agents[i]
        var offset := i * AGENT_BYTES
        data.encode_float(offset, ant.global_position.x)
        data.encode_float(offset + 4, ant.global_position.y)
        data.encode_float(offset + 8, ant.global_rotation)
        data.encode_float(offset + 12, 0.0)
        data.encode_float(offset + 16, ant.velocity.x)
        data.encode_float(offset + 20, ant.velocity.y)
        data.encode_float(offset + 24, ant.max_speed)
        data.encode_float(offset + 28, ant.steer_force)
        data.encode_float(offset + 32, ant.rotation_speed)
        data.encode_float(offset + 36, ant.wander_strength)
        data.encode_float(offset + 40, float(i + 1) * 17.173)
        data.encode_float(offset + 44, separation_radius)
    return data

func _initialize_gpu(spirv: RDShaderSPIRV) -> void:
    # Global RenderingDevice resources are created and used on RenderingServer's render thread.
    if not bool(_trail_manager.call("create_gpu_resources", _rd)):
        _gpu_failed = true
        return
    _shader = _rd.shader_create_from_spirv(spirv)
    if not _shader.is_valid():
        push_error("Failed to create the ant movement shader on the global RenderingDevice.")
        _gpu_failed = true
        return
    _pipeline = _rd.compute_pipeline_create(_shader)
    if not _pipeline.is_valid():
        push_error("Failed to create the ant movement compute pipeline.")
        _gpu_failed = true
        return
    _params_buffer = _rd.uniform_buffer_create(64)
    _rebuild_state_resources(PackedByteArray(), 0)

func _rebuild_state_resources(initial_state: PackedByteArray, ant_count: int) -> void:
    # Release descriptor sets before freeing the state buffers they reference.
    for uniform_set in _uniform_sets:
        if uniform_set.is_valid():
            _rd.free_rid(uniform_set)
    _uniform_sets.clear()
    _trail_manager.call("clear_uniform_sets")
    for buffer in _state_buffers:
        if buffer.is_valid():
            _rd.free_rid(buffer)
    _state_buffers.clear()
    if _visual_buffer.is_valid():
        _rd.free_rid(_visual_buffer)
    var buffer_data := initial_state
    if buffer_data.is_empty():
        buffer_data.resize(maxi(ant_count, 1) * AGENT_BYTES)
    _state_buffers = [
        _rd.storage_buffer_create(buffer_data.size(), buffer_data),
        _rd.storage_buffer_create(buffer_data.size(), buffer_data)
    ]
    var visual_data := PackedByteArray()
    visual_data.resize(maxi(ant_count, 1) * VISUAL_AGENT_BYTES)
    _visual_buffer = _rd.storage_buffer_create(visual_data.size(), visual_data)
    for input_index in range(2):
        for trail_index in range(2):
            var uniforms: Array[RDUniform] = []
            var input_uniform := RDUniform.new()
            input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
            input_uniform.binding = 0
            input_uniform.add_id(_state_buffers[input_index])
            uniforms.append(input_uniform)
            var output_uniform := RDUniform.new()
            output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
            output_uniform.binding = 1
            output_uniform.add_id(_state_buffers[1 - input_index])
            uniforms.append(output_uniform)
            var params_uniform := RDUniform.new()
            params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
            params_uniform.binding = 2
            params_uniform.add_id(_params_buffer)
            uniforms.append(params_uniform)
            var trail_uniform := RDUniform.new()
            trail_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
            trail_uniform.binding = 3
            trail_uniform.add_id(_trail_manager.call("get_trail_sampler_rid"))
            trail_uniform.add_id(_trail_manager.call("get_trail_texture_rid", trail_index))
            uniforms.append(trail_uniform)
            var visual_uniform := RDUniform.new()
            visual_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
            visual_uniform.binding = 4
            visual_uniform.add_id(_visual_buffer)
            uniforms.append(visual_uniform)
            _uniform_sets.append(_rd.uniform_set_create(uniforms, _shader, 0))
    _trail_manager.call("rebuild_uniform_sets", _state_buffers)
    _current_buffer = 0

func _run_gpu_frame(delta: float, simulation_time: float, initial_state: PackedByteArray, state_dirty: bool, frame_input: Dictionary, ant_count: int, requested_generation: int) -> void:
    if _gpu_failed or not _pipeline.is_valid():
        return
    if state_dirty or _state_buffers.is_empty():
        _rebuild_state_resources(initial_state, ant_count)
    var input_index := _current_buffer
    _trail_manager.call("update_gpu", delta, input_index, ant_count, frame_input)
    if bool(frame_input.get("clear", false)):
        return
    if ant_count <= 0:
        return
    _update_parameters(delta, simulation_time, ant_count)
    var trail_index: int = _trail_manager.call("get_front_index")
    var compute_list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
    # Binding the just-written trail RID as a sampler asks RenderingDevice to transition access automatically.
    _rd.compute_list_bind_uniform_set(compute_list, _uniform_sets[input_index * 2 + trail_index], 0)
    _rd.compute_list_dispatch(compute_list, ceili(float(ant_count) / float(WORKGROUP_SIZE)), 1, 1)
    _rd.compute_list_end()
    _current_buffer = 1 - input_index
    # RenderingDevice's async staging callback avoids stalling the global render queue for scene-node visuals.
    _rd.buffer_get_data_async(_visual_buffer, Callable(self, "_on_agent_data_ready").bind(requested_generation, ant_count), 0, ant_count * VISUAL_AGENT_BYTES)

func _update_parameters(delta: float, simulation_time: float, ant_count: int) -> void:
    var params := PackedByteArray()
    params.resize(64)
    params.encode_float(0, clampf(delta, 0.0, 0.1))
    params.encode_float(4, simulation_time)
    params.encode_float(8, world_bounds.position.x)
    params.encode_float(12, world_bounds.position.y)
    params.encode_float(16, world_bounds.end.x)
    params.encode_float(20, world_bounds.end.y)
    params.encode_u32(24, ant_count)
    var texture_size: Vector2i = _trail_manager.call("get_trail_texture_size")
    params.encode_u32(28, texture_size.x)
    params.encode_u32(32, texture_size.y)
    params.encode_float(36, trail_threshold)
    params.encode_float(40, sensor_distance)
    params.encode_float(44, deg_to_rad(sensor_angle_degrees))
    params.encode_u32(48, sensor_sample_budget)
    params.encode_float(52, trail_follow_strength)
    params.encode_float(56, world_bounds.size.x)
    params.encode_float(60, world_bounds.size.y)
    _rd.buffer_update(_params_buffer, 0, params.size(), params)

func _on_agent_data_ready(data: PackedByteArray, generation: int, ant_count: int) -> void:
    call_deferred("_apply_agent_data", data, generation, ant_count)

func _apply_agent_data(data: PackedByteArray, generation: int, ant_count: int) -> void:
    if generation != _agent_generation or data.size() < ant_count * VISUAL_AGENT_BYTES:
        return
    for i in range(mini(ant_count, agents.size())):
        var ant := agents[i]
        if not is_instance_valid(ant):
            continue
        var offset := i * VISUAL_AGENT_BYTES
        ant.global_position = Vector2(data.decode_float(offset), data.decode_float(offset + 4))
        ant.global_rotation = data.decode_float(offset + 8)
        ant.velocity = Vector2(data.decode_float(offset + 16), data.decode_float(offset + 20))

func _exit_tree() -> void:
    if _rd == null:
        return
    RenderingServer.call_on_render_thread(Callable(self, "_free_gpu_resources"))

func _free_gpu_resources() -> void:
    for uniform_set in _uniform_sets:
        if uniform_set.is_valid():
            _rd.free_rid(uniform_set)
    _uniform_sets.clear()
    _trail_manager.call("free_gpu_resources")
    for buffer in _state_buffers:
        if buffer.is_valid():
            _rd.free_rid(buffer)
    _state_buffers.clear()
    if _visual_buffer.is_valid():
        _rd.free_rid(_visual_buffer)
    for rid in [_params_buffer, _pipeline, _shader]:
        if rid.is_valid():
            _rd.free_rid(rid)
