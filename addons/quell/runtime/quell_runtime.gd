extends Node

const NativeBridgeClass = preload("res://addons/quell_core/runtime/quell_native_bridge.gd")

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

@export_enum("Current frame only", "Temporal blend", "Adaptive") var correction_mode: int = 2:
	set(value):
		correction_mode = clampi(value, 0, 2)
		_sync_settings()

var _native_runtime: Node
var last_metrics: Dictionary = {}

func _ready() -> void:
	_ensure_native_runtime()
	_sync_settings()

func is_core_available() -> bool:
	return _ensure_native_runtime()

func reset() -> void:
	if not _ensure_native_runtime():
		last_metrics.clear()
		return
	_native_runtime.reset()
	last_metrics.clear()

func update_from_metrics(raw_metrics: Dictionary, after_metrics: Dictionary, delta: float, time_seconds: float) -> Dictionary:
	if not _ensure_native_runtime():
		last_metrics = _unavailable_metrics(time_seconds)
		metrics_updated.emit(last_metrics)
		return last_metrics
	last_metrics = _native_runtime.update_from_metrics(raw_metrics, after_metrics, delta, time_seconds)
	metrics_updated.emit(last_metrics)
	return last_metrics

func shader_parameters(metrics: Dictionary = {}) -> Dictionary:
	if not _ensure_native_runtime():
		return {}
	return _native_runtime.shader_parameters(metrics)

func _ensure_native_runtime() -> bool:
	if _native_runtime != null:
		return true
	NativeBridgeClass.try_load_default_extension()
	if not ClassDB.class_exists("QuellRuntime"):
		return false
	_native_runtime = ClassDB.instantiate("QuellRuntime")
	if _native_runtime == null:
		return false
	add_child(_native_runtime)
	_native_runtime.metrics_updated.connect(func(metrics: Dictionary) -> void:
		last_metrics = metrics
	)
	_sync_settings()
	return true

func _sync_settings() -> void:
	if _native_runtime == null:
		return
	_native_runtime.mitigation_enabled = mitigation_enabled
	_native_runtime.viewing_distance_m = viewing_distance_m
	_native_runtime.headroom_margin = headroom_margin
	_native_runtime.correction_mode = correction_mode

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
