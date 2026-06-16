@tool
extends EditorPlugin

const RuntimeScript = preload("res://addons/quell/runtime/quell_runtime.gd")

func _enter_tree() -> void:
	add_custom_type("QuellRuntime", "Node", RuntimeScript, null)

func _exit_tree() -> void:
	remove_custom_type("QuellRuntime")
