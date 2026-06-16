class_name QuellRuntime
extends Node

const CORE_RUNTIME_PATH := "res://addons/quell_core/runtime/quell_core_runtime.gd"
const CORE_COMPOSITOR_EFFECT_PATH := "res://addons/quell_core/runtime/quell_compositor_effect.gd"

signal metrics_updated(metrics: Dictionary)

@export var mitigation_enabled: bool = true:
	set(value):
		mitigation_enabled = value
		_sync_settings()

@export_range(0.25, 2.0, 0.05) var viewing_distance_m: float = 0.60:
	set(value):
		viewing_distance_m = value
		_sync_settings()

@export_range(0.70, 0.99, 0.01) var headroom_margin: float = 0.80:
	set(value):
		headroom_margin = value
		_sync_settings()

@export var compositor_analysis_size: Vector2i = Vector2i(256, 144)
@export_enum("Current frame only", "Temporal blend") var correction_mode: int = 1:
	set(value):
		correction_mode = clampi(value, 0, 1)
		_sync_settings()

var _core: Node
var last_metrics: Dictionary = {}

func _ready() -> void:
	_ensure_core()
	_sync_settings()

func is_core_available() -> bool:
	return _ensure_core()

func reset() -> void:
	if not _ensure_core():
		last_metrics.clear()
		return
	_core.reset()
	last_metrics.clear()

func update_from_metrics(raw_metrics: Dictionary, after_metrics: Dictionary, delta: float, time_seconds: float) -> Dictionary:
	if not _ensure_core():
		last_metrics = _unavailable_metrics(time_seconds)
		metrics_updated.emit(last_metrics)
		return last_metrics
	last_metrics = _core.update_from_metrics(raw_metrics, after_metrics, delta, time_seconds)
	metrics_updated.emit(last_metrics)
	return last_metrics

func shader_parameters(metrics: Dictionary = {}) -> Dictionary:
	if not _ensure_core():
		return {}
	return _core.shader_parameters(metrics)

func create_compositor_effect() -> CompositorEffect:
	if not ResourceLoader.exists(CORE_COMPOSITOR_EFFECT_PATH):
		return null
	var effect_script = load(CORE_COMPOSITOR_EFFECT_PATH)
	if effect_script == null:
		return null
	var effect: CompositorEffect = effect_script.new()
	effect.mitigation_enabled = mitigation_enabled
	effect.viewing_distance_m = viewing_distance_m
	effect.after_target = headroom_margin
	effect.analysis_size = compositor_analysis_size
	effect.correction_mode = correction_mode
	effect.set_shader_parameters(shader_parameters())
	return effect

func _ensure_core() -> bool:
	if _core != null:
		return true
	if not ResourceLoader.exists(CORE_RUNTIME_PATH):
		return false
	var core_script = load(CORE_RUNTIME_PATH)
	if core_script == null:
		return false
	_core = core_script.new()
	add_child(_core)
	if _core.has_signal("metrics_updated"):
		_core.metrics_updated.connect(func(metrics: Dictionary) -> void:
			last_metrics = metrics
		)
	_sync_settings()
	return true

func _sync_settings() -> void:
	if _core == null:
		return
	_core.mitigation_enabled = mitigation_enabled
	_core.viewing_distance_m = viewing_distance_m
	_core.headroom_margin = headroom_margin
	if _core.has_method("set_correction_mode"):
		_core.set_correction_mode(correction_mode)

func _unavailable_metrics(time_seconds: float) -> Dictionary:
	return {
		"time": time_seconds,
		"luminance": 0.0,
		"red": 0.0,
		"spatial": 0.0,
		"trend": 0.0,
		"raw_risk": 0.0,
		"output_risk": 0.0,
		"risk_reduction": 0.0,
		"reduction_ratio": 0.0,
		"mitigation": 0.0,
		"metric_backend": "core-unavailable",
	}
