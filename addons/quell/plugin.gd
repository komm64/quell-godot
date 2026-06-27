@tool
extends EditorPlugin

const NATIVE_RUNTIME_CLASS_NAME := "QuellRuntime"
const NATIVE_EXTENSION_PATH := "res://addons/quell_core_native/quell_core_native.gdextension"

func _enter_tree() -> void:
	if ClassDB.class_exists(NATIVE_RUNTIME_CLASS_NAME):
		return
	if not FileAccess.file_exists(NATIVE_EXTENSION_PATH):
		return
	if not Engine.has_singleton("GDExtensionManager"):
		return
	var manager: Object = Engine.get_singleton("GDExtensionManager")
	if manager != null and manager.has_method("load_extension"):
		manager.load_extension(NATIVE_EXTENSION_PATH)

func _exit_tree() -> void:
	pass
