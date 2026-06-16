@tool
extends EditorPlugin

const RuntimeScript = preload("res://addons/quell/runtime/quell_runtime.gd")
const CORE_COMPOSITOR_EFFECT_PATH := "res://addons/quell_core/runtime/quell_compositor_effect.gd"

var _registered_core_effect := false

func _enter_tree() -> void:
	add_custom_type("QuellRuntime", "Node", RuntimeScript, null)
	if ResourceLoader.exists(CORE_COMPOSITOR_EFFECT_PATH):
		var compositor_effect_script = load(CORE_COMPOSITOR_EFFECT_PATH)
		if compositor_effect_script != null:
			add_custom_type("QuellCompositorEffect", "CompositorEffect", compositor_effect_script, null)
			_registered_core_effect = true

func _exit_tree() -> void:
	if _registered_core_effect:
		remove_custom_type("QuellCompositorEffect")
		_registered_core_effect = false
	remove_custom_type("QuellRuntime")
