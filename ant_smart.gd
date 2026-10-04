extends CharacterBody2D

enum AntType { STUPID }
enum AntState { NORMAL }

@export var type : AntType = AntType.STUPID
@export var state : AntState = AntState.NORMAL

@export var max_speed: float = 180.0
@export var steer_force: float = 4.0
@export var rotation_speed: float = 6.0
@export var wander_strength: float = 0.4


func _ready() -> void:
    call_deferred("_register_with_simulation")

func _register_with_simulation() -> void:
    var simulation := get_tree().get_first_node_in_group("ant_simulation")
    if simulation != null:
        simulation.call("register_ant", self)
    else:
        push_error("Ant could not find a node in the 'ant_simulation' group.")

func _exit_tree() -> void:
    var simulation := get_tree().get_first_node_in_group("ant_simulation")
    if simulation != null:
        simulation.call("unregister_ant", self)
