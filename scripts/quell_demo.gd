extends Control

const CORE_TMP_DIR := "C:/Users/komm64/Projects/quell-core/.tmp"
const CORE_TMP_FRAME_SEQUENCE_DIR := "C:/Users/komm64/Projects/quell-core/.tmp/quell-godot-sample-frames"
const TMP_VIDEO_FRAME_MANIFEST := "manifest.json"
const RiskGraphClass = preload("res://scripts/quell_risk_graph.gd")
const NativeBridgeClass = preload("res://addons/quell_core/runtime/quell_native_bridge.gd")

const SPATIAL_SENSITIVITY_STRICT := 0
const SPATIAL_SENSITIVITY_BALANCED := 1

var _core_available := false

# Synthetic stress modes for runtime visualization only. These values are not
# authoritative WCAG / ITU pass-fail samples; see docs/internal/pse_algorithm_traceability.md.
const MODE_CONFIGS: Array[Dictionary] = [
	{
		"name": "Luminance flash",
		"flash_hz": 8.0,
		"red_hz": 0.0,
		"stripe_cycles": 2.0,
		"unsafe_area": 0.72,
		"flash_amplitude": 1.0,
		"red_amplitude": 0.0,
		"spatial_contrast": 0.05,
		"risk_cycle_hz": 0.11,
		"validation_case_id": "luminance_more_than_three_per_second",
	},
	{
		"name": "Red saturation",
		"flash_hz": 1.0,
		"red_hz": 6.0,
		"stripe_cycles": 2.0,
		"unsafe_area": 0.64,
		"flash_amplitude": 0.15,
		"red_amplitude": 1.0,
		"spatial_contrast": 0.05,
		"risk_cycle_hz": 0.09,
		"validation_case_id": "red_saturated_fast_flash",
	},
	{
		"name": "Spatial stripes",
		"flash_hz": 1.0,
		"red_hz": 0.0,
		"stripe_cycles": 14.0,
		"unsafe_area": 1.0,
		"flash_amplitude": 0.05,
		"red_amplitude": 0.0,
		"spatial_contrast": 1.0,
		"risk_cycle_hz": 0.08,
		"validation_case_id": "spatial_vertical_high_density",
	},
	{
		"name": "Mixed stress",
		"flash_hz": 9.0,
		"red_hz": 6.0,
		"stripe_cycles": 12.0,
		"unsafe_area": 0.78,
		"flash_amplitude": 0.85,
		"red_amplitude": 0.70,
		"spatial_contrast": 0.85,
		"risk_cycle_hz": 0.10,
		"validation_case_id": "",
	},
]

const PRIVATE_FRAME_SEQUENCE_SOURCES: Array[Dictionary] = [
	{
		"id": "pokemon_shock_private",
		"name": "Pokemon shock clip (private)",
		"source_type": "frame_sequence",
		"frame_dir": "res://validation/private/demo-videos/pokemon-shock/frames",
		"frame_prefix": "frame_",
		"frame_extension": ".png",
		"fps": 1199.0 / 50.0,
		"estimated_risk": 1.35,
		"validation_case_id": "",
	},
]

const FRAME_CACHE_LIMIT: int = 384
const ANALYSIS_SCALE_DIVISOR: int = 4
const GAME_BUDGET_ANALYSIS_SCALE_DIVISOR: int = 16
const ENABLE_K64_IO_BY_DEFAULT: bool = false
const ENABLE_FRAME_SEQUENCE_RAW_SPATIAL_CPU_OVERRIDE: bool = false
const ENABLE_FRAME_SEQUENCE_AFTER_SPATIAL_READBACK: bool = false
const HUD_UPDATE_HZ: float = 10.0
const FRAME_SEQUENCE_PRELOAD_LIMIT: int = 96
const GAME_BUDGET_DEFAULT_ENABLED: bool = true
const DEBUG_MENU_DEFAULT_ENABLED: bool = false
var elapsed_seconds := 0.0
var current_mode := 0
var quell_enabled := true
var mitigation_enabled := true
var max_contrast_compression := 0.65
var max_brightness_reduction := 0.50
var max_feedback_amount := 0.60
var preserve_source_hue := true
var game_budget_enabled := GAME_BUDGET_DEFAULT_ENABLED
var spatial_sensitivity := 0
var viewing_distance_m := 0.60
var headroom_margin := 0.80
var contribution_enabled: Dictionary = {}
var debug_menu_hidden := false
var debug_menu_toggle_enabled := DEBUG_MENU_DEFAULT_ENABLED

var analyzer
var gpu_analyzer
var _hp_after_analyzer
# Sentinel for "After risk not measured this cycle". Distinct from a measured 0 so
# the display can show a gap instead of a misleading safe reading.
const AFTER_RISK_UNMEASURED := -1.0
# The last measured After risk (written ONLY by _hp_measure_after). Starts unmeasured.
var _measured_after_risk: float = AFTER_RISK_UNMEASURED
var gpu_frame_pipeline
var source_viewport: SubViewport
var source_display: TextureRect
var content_material: ShaderMaterial
var mode_select: OptionButton
var quell_toggle: CheckButton
var spatial_sensitivity_select: OptionButton
var mitigation_toggle: CheckButton
var hue_preserve_toggle: CheckButton
var frame_sequence_seek_slider: HSlider
var frame_sequence_seek_label: Label
var distance_value_label: Label
var headroom_value_label: Label
var contrast_limit_slider: HSlider
var contrast_limit_value_label: Label
var brightness_limit_slider: HSlider
var brightness_limit_value_label: Label
var feedback_limit_slider: HSlider
var feedback_limit_value_label: Label
var debug_panel: Control
var status_label: Label
var risk_graph: Control
var metric_labels: Dictionary = {}
var metric_bars: Dictionary = {}
var contribution_toggles: Dictionary = {}
var _process_frame_count: int = 0
var _raw_sample_count: int = 0
var _after_sample_count: int = 0
var _comparator_cases: Dictionary = {}
var _mode_configs: Array[Dictionary] = []
var _frame_sequence_paths: Dictionary = {}
var _frame_cache: Dictionary = {}
var _frame_cache_order: Array[String] = []
var _frame_sequence_active_id := ""
var _frame_sequence_index := 0
var _frame_sequence_accumulator := 0.0
var _frame_sequence_seek_dragging := false
var _frame_sequence_force_frame_changed := false
var _last_runtime_metrics: Dictionary = {}
var _last_after_metrics: Dictionary = {}
var _last_shader_parameters: Dictionary = {}
var _last_raw_sample_frame: int = -999999
var _last_after_sample_frame: int = -999999
var _next_hud_update_time: float = 0.0
var _profile_enabled: bool = false
var _legacy_risk_graph_enabled: bool = false
var _profile_accum: Dictionary = {}
var _profile_next_report: float = 0.0

const PROFILE_NATIVE_KEYS: Array[String] = [
	"total_us",
	"source_generate_us",
	"prepare_upload_us",
	"source_update_us",
	"source_analysis_resize_us",
	"mitigation_us",
	"after_analysis_resize_us",
	"visible_resize_us",
	"overlay_sample_us",
	"overlay_us",
	"emit_us",
]

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	Engine.max_fps = 60
	get_window().title = "[quell-godot] Godot Prototype"
	if not _load_core_classes():
		_build_notice("Quell private core is not installed.\nRun tools/sync_private_core.ps1 C:\\Users\\komm64\\Projects\\quell-core first.")
		return
	_profile_enabled = _cmdline_has_flag("--quell-profile")
	_legacy_risk_graph_enabled = _cmdline_has_flag("--quell-legacy-risk-graph")
	debug_menu_toggle_enabled = DEBUG_MENU_DEFAULT_ENABLED
	if _cmdline_has_flag("--quell-debug-menu") or _cmdline_has_flag("--quell-enable-debug-menu"):
		debug_menu_toggle_enabled = true
	if _cmdline_has_flag("--quell-no-debug-menu-toggle"):
		debug_menu_toggle_enabled = false
	debug_menu_hidden = (not debug_menu_toggle_enabled) or _cmdline_has_flag("--quell-risk-graph-only") or _cmdline_has_flag("--quell-hide-debug-menu") or _cmdline_has_flag("--quell-no-debug-menu")
	quell_enabled = not (_cmdline_has_flag("--quell-disabled") or _cmdline_has_flag("--quell-off"))
	if _cmdline_has_flag("--quell-enabled") or _cmdline_has_flag("--quell-on"):
		quell_enabled = true
	analyzer = NativeBridgeClass.instantiate_native_analyzer()
	gpu_analyzer = NativeBridgeClass.instantiate_native_gpu_analyzer()
	_hp_after_analyzer = NativeBridgeClass.instantiate_native_gpu_analyzer()
	gpu_frame_pipeline = NativeBridgeClass.instantiate_native_gpu_frame_pipeline()
	if analyzer == null or gpu_analyzer == null or _hp_after_analyzer == null or gpu_frame_pipeline == null:
		_build_notice("Quell native core could not be instantiated.\nBuild/load addons/quell_core_native before launching the demo.")
		return
	spatial_sensitivity = SPATIAL_SENSITIVITY_BALANCED
	contribution_enabled = _default_contribution_enabled()
	_mode_configs = MODE_CONFIGS.duplicate(true)
	_register_private_frame_sequences()
	_register_core_tmp_frame_sequences()
	_load_comparator_baselines()
	_sync_analyzer_settings()
	_build_visual_layers()
	_build_hud()
	_apply_mode(_initial_mode_index())
	_start_k64_io()

func _load_core_classes() -> bool:
	NativeBridgeClass.try_load_default_extension()
	_core_available = (
		NativeBridgeClass.is_analyzer_available()
		and NativeBridgeClass.is_gpu_analyzer_available()
		and NativeBridgeClass.is_gpu_frame_pipeline_available()
	)
	return _core_available

func _build_notice(message: String) -> void:
	var background := ColorRect.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.055, 0.063, 0.070)
	add_child(background)

	var panel := PanelContainer.new()
	panel.position = Vector2(24.0, 24.0)
	panel.custom_minimum_size = Vector2(520.0, 0.0)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color(0.90, 0.95, 0.97))
	margin.add_child(label)

func _exit_tree() -> void:
	if gpu_analyzer != null:
		gpu_analyzer.dispose()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.dispose()

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.ctrl_pressed or key_event.alt_pressed or key_event.meta_pressed:
		return
	var keycode := key_event.physical_keycode if key_event.physical_keycode != KEY_NONE else key_event.keycode
	if keycode == KEY_SPACE:
		_on_restart_video_pressed()
		get_viewport().set_input_as_handled()
	elif keycode == KEY_R:
		_on_clear_history_pressed()
		get_viewport().set_input_as_handled()
	elif keycode == KEY_F1:
		if debug_menu_toggle_enabled and debug_panel != null:
			debug_panel.visible = not debug_panel.visible
		get_viewport().set_input_as_handled()
	elif keycode == KEY_F2:
		if _legacy_risk_graph_enabled and risk_graph != null:
			risk_graph.visible = not risk_graph.visible
		get_viewport().set_input_as_handled()

func _start_k64_io() -> void:
	if not OS.is_debug_build():
		return
	if not _k64_io_enabled():
		return
	var io := get_node_or_null("/root/K64IO")
	if io == null:
		push_warning("[quell] K64IO autoload is not available")
		return
	# Quell validation only needs still screenshots/status. k64-io's generic
	# motion-history estimator conflicts with this prototype's RD-heavy path on
	# current Godot builds and can stall the file bus with per-frame RD errors.
	io.set("_motion_gpu_unavailable", true)
	io.call("set_game", "quell_godot_prototype", "0.2.0")
	io.call("register_sense", "/quell/status", Callable(self, "_provide_k64_status"), {
		"doc": "current Quell demo UI/debug state",
		"volatility": "per-frame",
		"fields": [
			{"name": "source", "type": "string", "doc": "selected source mode"},
			{"name": "quell_enabled", "type": "bool", "doc": "whole Quell runtime toggle"},
			{"name": "mitigation_enabled", "type": "bool", "doc": "UI mitigation toggle"},
			{"name": "headroom_margin", "type": "float", "doc": "After target slider"},
			{"name": "max_contrast_compression", "type": "float", "doc": "maximum contrast compression slider"},
			{"name": "max_brightness_reduction", "type": "float", "doc": "maximum brightness reduction slider"},
			{"name": "max_feedback_amount", "type": "float", "doc": "maximum temporal feedback slider"},
			{"name": "preserve_source_hue", "type": "bool", "doc": "Raw hue reconstruction toggle"},
			{"name": "game_budget_enabled", "type": "bool", "doc": "low-latency performance budget (analysis downscale)"},
			{"name": "spatial_sensitivity", "type": "int", "doc": "QuellAnalyzer.SpatialSensitivity enum value"},
			{"name": "render_backend", "type": "string", "doc": "active Quell output backend"},
			{"name": "display_size", "type": "string", "doc": "current output texture size"},
			{"name": "analysis_size", "type": "string", "doc": "current reduced analysis/mask texture size"},
			{"name": "frame", "type": "int", "doc": "demo _process frame counter"},
		],
	})
	io.call("register_screenshot", "", Callable(self, "_provide_k64_screenshot"))
	io.call("register_screenshot", "quell", Callable(self, "_provide_k64_ui_screenshot"))
	io.call("register_screenshot", "ui", Callable(self, "_provide_k64_ui_screenshot"))
	io.call("register_screenshot", "source", Callable(self, "_provide_k64_source_screenshot"))
	io.call("register_screenshot", "after", Callable(self, "_provide_k64_after_screenshot"))
	io.call("register_action", "quell_set_mode", Callable(self, "_act_k64_set_mode"), {
		"args": [{"name": "index", "type": "int"}],
	})
	io.call("register_action", "quell_set_enabled", Callable(self, "_act_k64_set_enabled"), {
		"args": [{"name": "enabled", "type": "bool"}],
	})
	io.call("register_action", "quell_restart_video", Callable(self, "_act_k64_restart_video"), {
		"args": [],
	})
	io.call("register_action", "quell_clear_history", Callable(self, "_act_k64_clear_history"), {
		"args": [],
	})
	var ok: Variant = io.call("start")
	print("[quell] K64IO.start() -> ", ok, "  bus at: user://k64_io/")

func _k64_io_enabled() -> bool:
	if ENABLE_K64_IO_BY_DEFAULT:
		return true
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg == "--k64-io" or arg == "--quell-k64-io":
			return true
	return false

func _cmdline_has_flag(flag: String) -> bool:
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg == flag:
			return true
	return false

func _cmdline_arg_value(prefix: String, fallback: String) -> String:
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix)
	return fallback

func _object_has_property(object: Object, property_name: String) -> bool:
	if object == null:
		return false
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func _profile_add(key: String, usec: int) -> void:
	if not _profile_enabled:
		return
	_profile_accum[key] = int(_profile_accum.get(key, 0)) + usec

func _profile_add_native_pipeline_profile(prefix: String) -> void:
	if not _profile_enabled or gpu_frame_pipeline == null or not gpu_frame_pipeline.has_method("get_last_profile"):
		return
	var native_profile: Dictionary = gpu_frame_pipeline.get_last_profile()
	for key in PROFILE_NATIVE_KEYS:
		_profile_add("%s_%s" % [prefix, key], int(native_profile.get(key, 0)))

func _profile_avg_ms(key: String, samples: int) -> float:
	return float(_profile_accum.get(key, 0)) / float(max(1, samples)) / 1000.0

func _profile_sample() -> void:
	if not _profile_enabled:
		return
	_profile_accum["samples"] = int(_profile_accum.get("samples", 0)) + 1
	if elapsed_seconds < _profile_next_report:
		return
	_profile_next_report = elapsed_seconds + 2.0
	var samples: int = max(1, int(_profile_accum.get("samples", 1)))
	var total_us := int(_profile_accum.get("total_us", 0))
	var tracked_us := 0
	for key in ["setup_us", "ready_us", "ensure_us", "load_us", "cache_us", "source_upload_us", "source_generate_us", "output_apply_us", "raw_analyze_us", "after_analyze_us", "spatial_cpu_us", "controller_us", "shader_us", "feedback_us", "overlay_refresh_us", "store_us", "hud_us"]:
		tracked_us += int(_profile_accum.get(key, 0))
	print("[quell-profile] gpu %s pipeline_ready %s analyzer_ready %s texture %s setup %.2fms ready %.2fms ensure %.2fms load %.2fms cache %.2fms source_upload %.2fms source_generate %.2fms output_apply %.2fms raw_analyze %.2fms after_analyze %.2fms spatial_cpu %.2fms controller %.2fms shader %.2fms feedback %.2fms overlay_refresh %.2fms store %.2fms hud %.2fms native_upload_total %.2fms native_upload_prepare %.2fms native_upload_update %.2fms native_upload_resize %.2fms native_generate_total %.2fms native_generate_source %.2fms native_generate_resize %.2fms native_apply_total %.2fms native_apply_mitigate %.2fms native_apply_after_resize %.2fms native_apply_visible_resize %.2fms native_apply_overlay %.2fms native_refresh_total %.2fms native_refresh_visible_resize %.2fms native_refresh_overlay %.2fms other %.2fms total %.2fms samples %d" % [
		str(_has_gpu_frame_pipeline()),
		str(gpu_frame_pipeline != null and gpu_frame_pipeline.is_ready()),
		str(gpu_analyzer != null and gpu_analyzer.is_ready()),
		str(gpu_frame_pipeline != null and gpu_frame_pipeline.analysis_source_texture != null),
		_profile_avg_ms("setup_us", samples),
		_profile_avg_ms("ready_us", samples),
		_profile_avg_ms("ensure_us", samples),
		_profile_avg_ms("load_us", samples),
		_profile_avg_ms("cache_us", samples),
		_profile_avg_ms("source_upload_us", samples),
		_profile_avg_ms("source_generate_us", samples),
		_profile_avg_ms("output_apply_us", samples),
		_profile_avg_ms("raw_analyze_us", samples),
		_profile_avg_ms("after_analyze_us", samples),
		_profile_avg_ms("spatial_cpu_us", samples),
		_profile_avg_ms("controller_us", samples),
		_profile_avg_ms("shader_us", samples),
		_profile_avg_ms("feedback_us", samples),
		_profile_avg_ms("overlay_refresh_us", samples),
		_profile_avg_ms("store_us", samples),
		_profile_avg_ms("hud_us", samples),
		_profile_avg_ms("native_source_upload_total_us", samples),
		_profile_avg_ms("native_source_upload_prepare_upload_us", samples),
		_profile_avg_ms("native_source_upload_source_update_us", samples),
		_profile_avg_ms("native_source_upload_source_analysis_resize_us", samples),
		_profile_avg_ms("native_source_generate_total_us", samples),
		_profile_avg_ms("native_source_generate_source_generate_us", samples),
		_profile_avg_ms("native_source_generate_source_analysis_resize_us", samples),
		_profile_avg_ms("native_output_apply_total_us", samples),
		_profile_avg_ms("native_output_apply_mitigation_us", samples),
		_profile_avg_ms("native_output_apply_after_analysis_resize_us", samples),
		_profile_avg_ms("native_output_apply_visible_resize_us", samples),
		_profile_avg_ms("native_output_apply_overlay_us", samples),
		_profile_avg_ms("native_overlay_refresh_total_us", samples),
		_profile_avg_ms("native_overlay_refresh_visible_resize_us", samples),
		_profile_avg_ms("native_overlay_refresh_overlay_us", samples),
		float(max(0, total_us - tracked_us)) / float(samples) / 1000.0,
		_profile_avg_ms("total_us", samples),
		samples,
	])
	_profile_accum.clear()

func _initial_mode_index() -> int:
	if OS.get_environment("QUELL_CLIP") != "":
		for i in range(_mode_configs.size()):
			if _is_frame_sequence_source(_mode_configs[i]):
				return i
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg.begins_with("--quell-mode="):
			return clampi(int(arg.get_slice("=", 1)), 0, max(0, _mode_configs.size() - 1))
		if arg.begins_with("--quell-source="):
			var requested := arg.get_slice("=", 1)
			for i in range(_mode_configs.size()):
				var config: Dictionary = _mode_configs[i]
				if requested == String(config.get("id", "")) or requested == String(config.get("name", "")):
					return i
	return 0

func _provide_k64_status() -> Dictionary:
	var source := _current_source_config()
	var display_size := _display_size()
	var analysis_size: Vector2i = _analysis_size_for_display(display_size)
	if gpu_frame_pipeline != null:
		analysis_size = gpu_frame_pipeline.get_analysis_size()
	return {
		"source": String(source.get("name", "")),
		"quell_enabled": quell_enabled,
		"mitigation_enabled": mitigation_enabled,
		"headroom_margin": headroom_margin,
		"max_contrast_compression": max_contrast_compression,
		"max_brightness_reduction": max_brightness_reduction,
		"max_feedback_amount": max_feedback_amount,
		"preserve_source_hue": preserve_source_hue,
		"game_budget_enabled": game_budget_enabled,
		"spatial_sensitivity": int(spatial_sensitivity),
		"render_backend": _render_backend_label(),
		"display_size": "%dx%d" % [display_size.x, display_size.y],
		"analysis_size": "%dx%d" % [analysis_size.x, analysis_size.y],
		"pipeline_display_size": "%dx%d" % [gpu_frame_pipeline.get_display_size().x, gpu_frame_pipeline.get_display_size().y] if gpu_frame_pipeline != null else "",
		"pipeline_analysis_size": "%dx%d" % [gpu_frame_pipeline.get_analysis_size().x, gpu_frame_pipeline.get_analysis_size().y] if gpu_frame_pipeline != null else "",
		"raw_risk": float(_last_runtime_metrics.get("raw_risk", 0.0)),
		"after_risk": float(_last_runtime_metrics.get("output_risk", _last_after_metrics.get("estimated_raw_risk", _last_after_metrics.get("raw_risk", _last_runtime_metrics.get("solver_after_risk", 0.0))))),
		"solver_correction_scale": float(_last_runtime_metrics.get("solver_correction_scale", 0.0)),
		"solver_identity_after_risk": float(_last_runtime_metrics.get("solver_identity_after_risk", 0.0)),
		"solver_after_risk": float(_last_runtime_metrics.get("solver_after_risk", 0.0)),
		"shader_strength": float(_last_shader_parameters.get("mitigation_strength", 0.0)),
		"correction_mix_alpha": float(_last_shader_parameters.get("correction_mix_alpha", 0.0)),
		"emergency_hold": float(_last_shader_parameters.get("emergency_hold", 0.0)),
		"mitigation_enabled_signal": float(_last_shader_parameters.get("mitigation_enabled_signal", 0.0)),
		"frame": _process_frame_count,
		"raw_samples": _raw_sample_count,
		"after_samples": _after_sample_count,
	}

func _provide_k64_screenshot() -> Variant:
	if DisplayServer.get_name() == "headless":
		return null
	return _provide_k64_ui_screenshot()

func _provide_k64_ui_screenshot() -> Variant:
	if DisplayServer.get_name() == "headless":
		return null
	var viewport := get_tree().root
	var texture := viewport.get_texture()
	if texture == null:
		return null
	var image := texture.get_image()
	if image == null or image.get_width() <= 0 or image.get_height() <= 0:
		return null
	return image

func _provide_k64_after_screenshot() -> Variant:
	if DisplayServer.get_name() == "headless":
		return null
	if _has_gpu_frame_pipeline() and gpu_frame_pipeline.after_texture != null:
		var image: Image = gpu_frame_pipeline.after_texture.get_image()
		if image != null and image.get_width() > 0 and image.get_height() > 0:
			return image
	if source_viewport != null:
		var source_texture := source_viewport.get_texture()
		if source_texture != null:
			var source_image := source_texture.get_image()
			if source_image != null and source_image.get_width() > 0 and source_image.get_height() > 0:
				return source_image
	return _provide_k64_ui_screenshot()

func _provide_k64_source_screenshot() -> Variant:
	if DisplayServer.get_name() == "headless":
		return null
	if _has_gpu_frame_pipeline() and gpu_frame_pipeline.source_texture != null:
		var image: Image = gpu_frame_pipeline.source_texture.get_image()
		if image != null and image.get_width() > 0 and image.get_height() > 0:
			return image
	if source_viewport != null:
		var source_texture := source_viewport.get_texture()
		if source_texture != null:
			var source_image := source_texture.get_image()
			if source_image != null and source_image.get_width() > 0 and source_image.get_height() > 0:
				return source_image
	return _provide_k64_ui_screenshot()

func _act_k64_set_mode(args: Dictionary) -> Dictionary:
	_apply_mode(int(args.get("index", current_mode)))
	return _provide_k64_status()

func _act_k64_set_enabled(args: Dictionary) -> Dictionary:
	quell_enabled = bool(args.get("enabled", args.get("value", quell_enabled)))
	if quell_toggle != null:
		quell_toggle.set_pressed_no_signal(quell_enabled)
	_sync_analyzer_settings()
	_reset_analysis_state()
	return _provide_k64_status()

func _act_k64_set_mitigation(args: Dictionary) -> Dictionary:
	mitigation_enabled = bool(args.get("enabled", mitigation_enabled))
	if mitigation_toggle != null:
		mitigation_toggle.button_pressed = mitigation_enabled
	_sync_analyzer_settings()
	_reset_analysis_state()
	return _provide_k64_status()

func _act_k64_set_contrast_max(args: Dictionary) -> Dictionary:
	max_contrast_compression = clamp(float(args.get("compression", args.get("value", max_contrast_compression))), 0.0, 0.90)
	if contrast_limit_slider != null:
		contrast_limit_slider.set_value_no_signal(max_contrast_compression)
	_sync_analyzer_settings()
	_refresh_static_labels()
	return _provide_k64_status()

func _act_k64_set_brightness_max(args: Dictionary) -> Dictionary:
	max_brightness_reduction = clamp(float(args.get("reduction", args.get("value", max_brightness_reduction))), 0.0, 0.90)
	if brightness_limit_slider != null:
		brightness_limit_slider.set_value_no_signal(max_brightness_reduction)
	_sync_analyzer_settings()
	_refresh_static_labels()
	return _provide_k64_status()

func _act_k64_set_feedback_max(args: Dictionary) -> Dictionary:
	max_feedback_amount = clamp(float(args.get("amount", args.get("value", max_feedback_amount))), 0.0, 0.95)
	if feedback_limit_slider != null:
		feedback_limit_slider.set_value_no_signal(max_feedback_amount)
	_sync_analyzer_settings()
	_refresh_static_labels()
	return _provide_k64_status()

func _act_k64_set_hue_preserve(args: Dictionary) -> Dictionary:
	preserve_source_hue = bool(args.get("enabled", args.get("value", preserve_source_hue)))
	if hue_preserve_toggle != null:
		hue_preserve_toggle.set_pressed_no_signal(preserve_source_hue)
	_sync_analyzer_settings()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.reset_output_history()
	return _provide_k64_status()

func _act_k64_set_game_budget(args: Dictionary) -> Dictionary:
	game_budget_enabled = bool(args.get("enabled", args.get("value", game_budget_enabled)))
	if game_budget_enabled and _is_frame_sequence_source(_current_source_config()):
		_preload_frame_sequence(_current_source_config())
	_sync_analyzer_settings()
	_ensure_gpu_frame_pipeline_size(_current_source_config())
	_reset_analysis_state()
	return _provide_k64_status()

func _act_k64_restart_video(_args: Dictionary) -> Dictionary:
	_on_restart_video_pressed()
	return _provide_k64_status()

func _act_k64_clear_history(_args: Dictionary) -> Dictionary:
	_on_clear_history_pressed()
	return _provide_k64_status()

func _act_k64_set_spatial_sensitivity(args: Dictionary) -> Dictionary:
	var requested: int = int(args.get("mode", args.get("value", spatial_sensitivity)))
	if requested == SPATIAL_SENSITIVITY_BALANCED:
		spatial_sensitivity = SPATIAL_SENSITIVITY_BALANCED
	else:
		spatial_sensitivity = SPATIAL_SENSITIVITY_STRICT
	_select_option_by_item_id(spatial_sensitivity_select, int(spatial_sensitivity))
	_sync_analyzer_settings()
	_reset_analysis_state()
	return _provide_k64_status()

func _act_k64_set_contribution(args: Dictionary) -> Dictionary:
	var component := String(args.get("component", ""))
	if contribution_enabled.has(component):
		contribution_enabled[component] = bool(args.get("enabled", contribution_enabled[component]))
		if contribution_toggles.has(component):
			contribution_toggles[component].button_pressed = bool(contribution_enabled[component])
		_sync_analyzer_settings()
		_reset_analysis_state()
	return _provide_k64_status()

func _select_option_by_item_id(option: OptionButton, item_id: int) -> void:
	if option == null:
		return
	for i in range(option.item_count):
		if option.get_item_id(i) == item_id:
			option.select(i)
			return

func _process(delta: float) -> void:
	if not _core_available:
		return
	var profile_total_start := Time.get_ticks_usec()
	_process_frame_count += 1
	elapsed_seconds += delta
	var setup_start := Time.get_ticks_usec()
	var source: Dictionary = _current_source_config()
	var envelope: float = _demo_risk_envelope(float(source.get("risk_cycle_hz", 0.10)))
	if content_material != null and not _is_frame_sequence_source(source):
		_set_content_shader_parameter("time_seconds", elapsed_seconds)
		_set_content_shader_parameter("risk_envelope", envelope)
	_profile_add("setup_us", Time.get_ticks_usec() - setup_start)

	var metrics: Dictionary
	var shader_parameters: Dictionary
	var ready_start := Time.get_ticks_usec()
	var has_gpu_frame_pipeline := _has_gpu_frame_pipeline()
	_profile_add("ready_us", Time.get_ticks_usec() - ready_start)
	if DisplayServer.get_name() == "headless":
		if not quell_enabled:
			metrics = _disabled_metrics(elapsed_seconds, "headless-disabled")
		elif _is_frame_sequence_source(source):
			var headless_sequence_image = _load_frame_sequence_image_for_demo(source, delta)
			if headless_sequence_image != null:
				metrics = analyzer.update_from_image(headless_sequence_image, delta, elapsed_seconds)
				metrics["metric_backend"] = "image-sequence"
			else:
				metrics = analyzer.update_from_generated_source(MODE_CONFIGS[0], delta, elapsed_seconds)
				metrics["metric_backend"] = "generated-fallback"
		else:
			metrics = analyzer.update_from_generated_source(source, delta, elapsed_seconds)
			metrics["metric_backend"] = "generated"
		shader_parameters = _resolve_shader_parameters(metrics)
		_apply_shader_parameter_metrics(metrics, shader_parameters)
	elif has_gpu_frame_pipeline:
		var ensure_start := Time.get_ticks_usec()
		_ensure_gpu_frame_pipeline_size(source)
		_profile_add("ensure_us", Time.get_ticks_usec() - ensure_start)
		var uploaded_sequence_frame := false
		var gpu_sequence_image = null
		if _is_frame_sequence_source(source):
			# Mode-3 dynamics are dt-normalized (delta_seconds), so the pipeline runs
			# every display tick like a real game — no held-frame skip/cadence
			# synchronizer. A held source frame simply measures no transitions.
			var load_start := Time.get_ticks_usec()
			gpu_sequence_image = _load_frame_sequence_image_for_demo(source, delta)
			_profile_add("load_us", Time.get_ticks_usec() - load_start)
			if gpu_sequence_image != null:
				var upload_start := Time.get_ticks_usec()
				uploaded_sequence_frame = gpu_frame_pipeline.upload_source_image(gpu_sequence_image, false)
				_profile_add("source_upload_us", Time.get_ticks_usec() - upload_start)
				_profile_add_native_pipeline_profile("native_source_upload")
		if not uploaded_sequence_frame:
			var source_config := source.duplicate(true)
			source_config["index"] = current_mode
			var generate_start := Time.get_ticks_usec()
			gpu_frame_pipeline.generate_source(source_config, elapsed_seconds, envelope)
			_profile_add("source_generate_us", Time.get_ticks_usec() - generate_start)
			_profile_add_native_pipeline_profile("native_source_generate")
		if not quell_enabled:
			metrics = _disabled_metrics(elapsed_seconds, "gpu-frame-seq-disabled" if uploaded_sequence_frame else "gpu-disabled")
			shader_parameters = _resolve_shader_parameters(metrics)
			_apply_mitigation_parameters(shader_parameters)
			_last_runtime_metrics = metrics.duplicate(false)
			_last_after_metrics = metrics.duplicate(false)
			_last_shader_parameters = shader_parameters.duplicate(false)
			var disabled_hud_start := Time.get_ticks_usec()
			_update_hud(metrics)
			_profile_add("hud_us", Time.get_ticks_usec() - disabled_hud_start)
			_profile_add("total_us", Time.get_ticks_usec() - profile_total_start)
			_profile_sample()
			return
		_raw_sample_count += 1
		_last_raw_sample_frame = _process_frame_count
		var analyze_start := Time.get_ticks_usec()
		var raw_gpu_metrics: Dictionary = _analyze_raw_source_texture(elapsed_seconds)
		_profile_add("raw_analyze_us", Time.get_ticks_usec() - analyze_start)
		if not uploaded_sequence_frame:
			raw_gpu_metrics["source_kind"] = "generated"
			var estimated_temporal_contrast := _estimate_mode_temporal_contrast(source)
			raw_gpu_metrics["luminance_contrast"] = max(float(raw_gpu_metrics.get("luminance_contrast", 0.0)), estimated_temporal_contrast)
			if estimated_temporal_contrast > 0.001:
				raw_gpu_metrics["general_flash_area"] = max(float(raw_gpu_metrics.get("general_flash_area", 0.0)), float(source.get("unsafe_area", 1.0)))
		else:
			raw_gpu_metrics["source_kind"] = "frame_sequence"
			if ENABLE_FRAME_SEQUENCE_RAW_SPATIAL_CPU_OVERRIDE:
				var spatial_cpu_start := Time.get_ticks_usec()
				_apply_cpu_spatial_override(raw_gpu_metrics, gpu_sequence_image, analyzer)
				_profile_add("spatial_cpu_us", Time.get_ticks_usec() - spatial_cpu_start)
		var controller_start := Time.get_ticks_usec()
		metrics = analyzer.update_from_metrics(raw_gpu_metrics, delta, elapsed_seconds)
		_profile_add("controller_us", Time.get_ticks_usec() - controller_start)
		metrics["metric_backend"] = "gpu-frame-seq" if uploaded_sequence_frame else "gpu-rd"
		var shader_start := Time.get_ticks_usec()
		shader_parameters = _resolve_output_shader_parameters(metrics, delta, "frame_sequence" if uploaded_sequence_frame else "generated")
		_profile_add("shader_us", Time.get_ticks_usec() - shader_start)
		_apply_mitigation_parameters(_hard_projection_parameters(shader_parameters, metrics, delta), _analyzer_hazard_rid())
		_hp_measure_after(metrics, delta)
	else:
		if not quell_enabled:
			metrics = _disabled_metrics(elapsed_seconds, "generated-disabled")
		else:
			metrics = analyzer.update_from_generated_source(source, delta, elapsed_seconds)
			metrics["metric_backend"] = "generated"
		shader_parameters = _resolve_shader_parameters(metrics)
		_apply_shader_parameter_metrics(metrics, shader_parameters)
	var hud_start := Time.get_ticks_usec()
	_update_hud(metrics)
	_profile_add("hud_us", Time.get_ticks_usec() - hud_start)
	_profile_add("total_us", Time.get_ticks_usec() - profile_total_start)
	_profile_sample()
	if OS.get_environment("QUELL_DEBUG_HAZARD") != "" and _process_frame_count % 12 == 0:
		var haz_rid := _analyzer_hazard_rid()
		if haz_rid.is_valid():
			var haz_rd := RenderingServer.get_rendering_device()
			var haz_bytes := haz_rd.texture_get_data(haz_rid, 0)
			var haz_img := Image.create_from_data(64, 36, false, Image.FORMAT_RGBA8, haz_bytes)
			haz_img.save_png(OS.get_environment("QUELL_DEBUG_HAZARD") + "_%05d.png" % _process_frame_count)
	if OS.get_environment("QUELL_DEBUG_TICKS") != "" and _process_frame_count % 30 == 0:
		print("[dbg] f=%d t=%.2f raw=%.3f out=%.3f mit=%.3f backend=%s" % [
			_process_frame_count, elapsed_seconds,
			float(metrics.get("raw_risk", -9.0)), float(metrics.get("output_risk", -9.0)),
			float(metrics.get("mitigation", -9.0)), String(metrics.get("metric_backend", "?"))])
	if OS.get_environment("QUELL_SHOT") != "":
		# Dev screenshot hook: capture at QUELL_SHOT_FRAME (default 130) and quit,
		# so a specific clip section (e.g. the flash segment) can be verified.
		# QUELL_SHOT_EVERY=N additionally saves numbered shots every N frames on
		# the way there (QUELL_SHOT gets _%05d suffixes), for sequence review.
		var shot_frame := 130
		if OS.get_environment("QUELL_SHOT_FRAME") != "":
			shot_frame = maxi(1, int(OS.get_environment("QUELL_SHOT_FRAME")))
		var shot_every := 0
		if OS.get_environment("QUELL_SHOT_EVERY") != "":
			shot_every = maxi(1, int(OS.get_environment("QUELL_SHOT_EVERY")))
		if shot_every > 0 and _process_frame_count % shot_every == 0 and _process_frame_count < shot_frame:
			var seq_img := get_viewport().get_texture().get_image()
			if seq_img != null:
				seq_img.save_png(OS.get_environment("QUELL_SHOT").get_basename() + "_%05d.png" % _process_frame_count)
		if _process_frame_count >= shot_frame:
			var shot_img := get_viewport().get_texture().get_image()
			if shot_img != null:
				shot_img.save_png(OS.get_environment("QUELL_SHOT"))
			get_tree().quit()

func _build_visual_layers() -> void:
	var source := _current_source_config()
	var display_size := _pipeline_display_size_for_source(source)
	var analysis_size := _pipeline_analysis_size_for_source(source, display_size)
	if gpu_frame_pipeline != null and gpu_analyzer.is_ready() and _hp_after_analyzer.is_ready() and gpu_frame_pipeline.configure(display_size, analysis_size):
		source_display = TextureRect.new()
		source_display.name = "GpuAfterDisplayFullRes"
		source_display.set_anchors_preset(Control.PRESET_FULL_RECT)
		source_display.texture = gpu_frame_pipeline.after_texture
		source_display.stretch_mode = TextureRect.STRETCH_SCALE
		source_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(source_display)
		return

	source_viewport = SubViewport.new()
	source_viewport.name = "AnalysisSourceViewport"
	source_viewport.size = analysis_size
	source_viewport.disable_3d = true
	source_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(source_viewport)

	var source_root := Control.new()
	source_root.name = "SourceRoot"
	source_root.size = Vector2(source_viewport.size)
	source_viewport.add_child(source_root)

	var content_rect := ColorRect.new()
	content_rect.name = "HazardPattern"
	content_rect.size = Vector2(source_viewport.size)
	content_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	source_root.add_child(content_rect)

	content_material = ShaderMaterial.new()
	content_material.shader = load("res://shaders/demo_pattern.gdshader")
	content_rect.material = content_material

	source_display = TextureRect.new()
	source_display.name = "SourceDisplay"
	source_display.set_anchors_preset(Control.PRESET_FULL_RECT)
	source_display.texture = source_viewport.get_texture()
	source_display.stretch_mode = TextureRect.STRETCH_SCALE
	source_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(source_display)

	if gpu_frame_pipeline != null and gpu_analyzer.is_ready():
		gpu_frame_pipeline.configure(_display_size(), analysis_size)

func _build_hud() -> void:
	var hud_layer := CanvasLayer.new()
	hud_layer.name = "HUD"
	hud_layer.layer = 20
	add_child(hud_layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(16.0, 16.0)
	panel.custom_minimum_size = Vector2(430.0, 0.0)
	panel.visible = not debug_menu_hidden
	debug_panel = panel
	hud_layer.add_child(panel)

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.055, 0.063, 0.070, 0.90)
	panel_style.border_color = Color(0.28, 0.36, 0.40, 0.85)
	panel_style.border_width_left = 1
	panel_style.border_width_top = 1
	panel_style.border_width_right = 1
	panel_style.border_width_bottom = 1
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	panel.add_theme_stylebox_override("panel", panel_style)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(430.0, max(320.0, get_viewport_rect().size.y - 32.0))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	panel.add_child(scroll)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	scroll.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 10)
	margin.add_child(stack)

	var title := Label.new()
	title.text = "Quell / Godot prototype"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.92, 0.96, 0.98))
	stack.add_child(title)

	mode_select = OptionButton.new()
	for config in _mode_configs:
		mode_select.add_item(config["name"])
	mode_select.item_selected.connect(_on_mode_selected)
	stack.add_child(_with_caption("Source", mode_select))

	quell_toggle = CheckButton.new()
	quell_toggle.text = "Quell"
	quell_toggle.button_pressed = quell_enabled
	quell_toggle.toggled.connect(_on_quell_toggled)
	stack.add_child(quell_toggle)

	stack.add_child(_reset_controls())
	stack.add_child(_frame_sequence_seek_controls())

	_add_metric_row(stack, "luminance", "Luminance")
	_add_metric_row(stack, "red", "Red")
	_add_metric_row(stack, "spatial", "Spatial")
	_add_metric_row(stack, "trend", "Trend")
	_add_metric_row(stack, "raw_risk", "Raw risk")
	_add_metric_row(stack, "output_risk", "After")
	_add_metric_row(stack, "reduction_ratio", "Drop")
	_add_metric_row(stack, "brightness_control", "Brightness")
	_add_metric_row(stack, "contrast_control", "Contrast")
	_add_metric_row(stack, "mitigation", "Mitigation")

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Color(0.70, 0.78, 0.82))
	stack.add_child(status_label)

	if _legacy_risk_graph_enabled:
		risk_graph = RiskGraphClass.new()
		risk_graph.headroom_margin = headroom_margin
		risk_graph.anchor_left = 1.0
		risk_graph.anchor_top = 1.0
		risk_graph.anchor_right = 1.0
		risk_graph.anchor_bottom = 1.0
		risk_graph.offset_left = -456.0
		risk_graph.offset_top = -224.0
		risk_graph.offset_right = -16.0
		risk_graph.offset_bottom = -16.0
		risk_graph.visible = false
		hud_layer.add_child(risk_graph)

	_refresh_static_labels()

func _with_caption(caption: String, control: Control) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var label := Label.new()
	label.text = caption
	label.custom_minimum_size = Vector2(130.0, 0.0)
	label.add_theme_color_override("font_color", Color(0.70, 0.78, 0.82))
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row

func _slider_row(caption: String, slider: HSlider, value_label: Label) -> Control:
	var wrapper := VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 3)

	var header := HBoxContainer.new()
	var label := Label.new()
	label.text = caption
	label.add_theme_color_override("font_color", Color(0.70, 0.78, 0.82))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)

	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.custom_minimum_size = Vector2(70.0, 0.0)
	value_label.add_theme_color_override("font_color", Color(0.90, 0.95, 0.97))
	header.add_child(value_label)
	wrapper.add_child(header)
	wrapper.add_child(slider)
	return wrapper

func _reset_controls() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var restart_video := Button.new()
	restart_video.text = "Restart video"
	restart_video.tooltip_text = "Restart the current frame sequence and clear analyzer history."
	restart_video.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	restart_video.pressed.connect(_on_restart_video_pressed)
	row.add_child(restart_video)

	var clear_history := Button.new()
	clear_history.text = "Clear history"
	clear_history.tooltip_text = "Clear analyzer feedback and the risk graph without changing the current video frame."
	clear_history.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_history.pressed.connect(_on_clear_history_pressed)
	row.add_child(clear_history)

	return row

func _frame_sequence_seek_controls() -> Control:
	var wrapper := VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)
	wrapper.visible = false

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = "Video"
	label.add_theme_color_override("font_color", Color(0.70, 0.78, 0.82))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)

	frame_sequence_seek_label = Label.new()
	frame_sequence_seek_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	frame_sequence_seek_label.custom_minimum_size = Vector2(145.0, 0.0)
	frame_sequence_seek_label.add_theme_color_override("font_color", Color(0.90, 0.95, 0.97))
	header.add_child(frame_sequence_seek_label)
	wrapper.add_child(header)

	frame_sequence_seek_slider = HSlider.new()
	frame_sequence_seek_slider.min_value = 0.0
	frame_sequence_seek_slider.max_value = 1.0
	frame_sequence_seek_slider.step = 1.0
	frame_sequence_seek_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame_sequence_seek_slider.drag_started.connect(_on_frame_sequence_seek_drag_started)
	frame_sequence_seek_slider.drag_ended.connect(_on_frame_sequence_seek_drag_ended)
	frame_sequence_seek_slider.value_changed.connect(_on_frame_sequence_seek_value_changed)
	wrapper.add_child(frame_sequence_seek_slider)
	return wrapper

func _add_metric_row(parent: VBoxContainer, key: String, caption: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var label := Label.new()
	label.text = caption
	label.custom_minimum_size = Vector2(120.0, 0.0)
	label.add_theme_color_override("font_color", Color(0.82, 0.88, 0.90))
	row.add_child(label)

	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.step = 0.001
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(145.0, 10.0)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(bar)

	var value := Label.new()
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.custom_minimum_size = Vector2(54.0, 0.0)
	value.add_theme_color_override("font_color", Color(0.90, 0.95, 0.97))
	row.add_child(value)

	metric_bars[key] = bar
	metric_labels[key] = value
	parent.add_child(row)

func _contribution_controls() -> Control:
	var wrapper := VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	var label := Label.new()
	label.text = "Risk inputs"
	label.add_theme_color_override("font_color", Color(0.70, 0.78, 0.82))
	wrapper.add_child(label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var specs := [
		{"key": "luminance", "label": "Luma"},
		{"key": "red", "label": "Red"},
		{"key": "spatial", "label": "Spatial"},
		{"key": "trend", "label": "Trend"},
	]
	for spec in specs:
		var key := String(spec["key"])
		var toggle := CheckBox.new()
		toggle.text = String(spec["label"])
		toggle.button_pressed = bool(contribution_enabled.get(key, true))
		toggle.toggled.connect(_on_contribution_toggled.bind(key))
		row.add_child(toggle)
		contribution_toggles[key] = toggle
	wrapper.add_child(row)
	return wrapper

func _apply_shader_parameter_metrics(metrics: Dictionary, parameters: Dictionary) -> void:
	metrics["controller_mitigation"] = float(metrics.get("mitigation", 0.0))
	metrics["mitigation"] = float(parameters.get("mitigation_strength", metrics.get("mitigation", 0.0)))
	metrics["temporal_hold"] = 1.0 if float(parameters.get("luminance_delta_limit", 1.0)) <= 0.000001 else 0.0
	metrics["brightness_control"] = float(parameters.get("brightness_reduction", 0.0))
	metrics["contrast_control"] = 1.0 - float(parameters.get("contrast_scale_limit", 1.0))

func _apply_overlay_metrics_to_shader_parameters(parameters: Dictionary, metrics: Dictionary, output_risk: float) -> void:
	parameters["raw_risk_for_overlay"] = clampf(float(metrics.get("raw_risk", 0.0)), 0.0, 1.50)
	parameters["output_risk_for_overlay"] = clampf(output_risk, 0.0, 1.50)
	parameters["target_risk_for_overlay"] = headroom_margin
	parameters["time_for_overlay"] = float(metrics.get("time", elapsed_seconds))

func _mitigation_active() -> bool:
	return quell_enabled and mitigation_enabled

func _resolve_shader_parameters(metrics: Dictionary) -> Dictionary:
	var parameters: Dictionary
	if not _mitigation_active():
		parameters = _identity_shader_parameters_for_metrics(metrics)
	else:
		if analyzer == null or not analyzer.has_method("resolve_shader_parameters"):
			push_error("Quell analyzer does not provide resolve_shader_parameters; sync/build quell-core first.")
			return {}
		parameters = analyzer.resolve_shader_parameters(metrics)
	return parameters

func _identity_shader_parameters_for_metrics(metrics: Dictionary) -> Dictionary:
	if analyzer == null or not analyzer.has_method("identity_shader_parameters"):
		push_error("Quell analyzer does not provide identity_shader_parameters; sync/build quell-core first.")
		return {}
	var parameters: Dictionary = analyzer.identity_shader_parameters(metrics)
	_apply_overlay_metrics_to_shader_parameters(parameters, metrics, 0.0)
	return parameters

func _resolve_output_shader_parameters(metrics: Dictionary, after_analysis_delta: float, source_kind: String) -> Dictionary:
	# Carry the single measured After forward (prior frame's real value, or the
	# UNMEASURED sentinel) so the analyzer's _attach_overlay_metrics is the sole
	# writer of the overlay After — no raw/estimated synthesis anywhere.
	metrics["output_risk"] = _measured_after_risk
	var parameters: Dictionary = _resolve_shader_parameters(metrics)
	_apply_shader_parameter_metrics(metrics, parameters)
	_last_shader_parameters = parameters.duplicate(false)
	return parameters

func _apply_mitigation_parameters(parameters: Dictionary, hazard_rid: RID = RID()) -> void:
	var mitigate_start := Time.get_ticks_usec()
	gpu_frame_pipeline.apply_mitigation(parameters, hazard_rid)
	_profile_add("output_apply_us", Time.get_ticks_usec() - mitigate_start)
	_profile_add_native_pipeline_profile("native_output_apply")

# Builds the mode-3 shader parameters the GPU pass needs from the analyzer
# metrics and the real display-tick dt.
func _hard_projection_parameters(parameters: Dictionary, metrics: Dictionary, delta: float) -> Dictionary:
	var p: Dictionary = parameters.duplicate(false)
	p["mitigation_mode"] = 3
	p["mitigation_style"] = 1.0
	# Real display-tick dt so per-tick application at any fps matches the
	# certified 30 fps export dynamics.
	p["delta_seconds"] = delta
	# Instantaneous per-tick transition areas — the same input semantics as the
	# certified export path. (The 1-second-windowed maxima that used to be mixed
	# in here were a held-frame-skip-era workaround; they only added a ~1 s full
	# hold past the last event.)
	p["general_transition_area"] = max(
		float(metrics.get("general_transition_area", 0.0)),
		float(metrics.get("red_transition_area", 0.0)))
	p["target_risk"] = 0.80
	p["safety_margin"] = 0.90
	return p

func _analyzer_hazard_rid() -> RID:
	# Use the analyzer's temporally-smoothed regional hazard map, not the raw
	# per-frame mask (the raw one flashes with the source).
	if gpu_analyzer != null and gpu_analyzer.hazard_map_texture != null:
		return gpu_analyzer.hazard_map_texture.texture_rd_rid
	return RID()

# SINGLE SOURCE OF TRUTH for the After risk. This is the ONLY writer of
# metrics["output_risk"]. It scores the ACTUAL mode-3 output texture with the
# same WINDOWED detector channels the release gate scores (rolling 1-second
# flash-count risk per WCAG/ITU counting; luminance/red/spatial), so RAW and
# AFTER read on the same scale. A single safe transition (a burst onset the
# continuous engage passes by design, or a scene cut) is not a flash pair and
# barely moves it — the previous instantaneous transition-area/0.25 surface
# pinned the graph to 1.35 for one tick on exactly those. If the measurement
# cannot run, output_risk is left UNWRITTEN (stays the AFTER_RISK_UNMEASURED
# sentinel) — never a synthesized/raw/estimated value — so "measurement enabled
# but not measured" surfaces as a visible gap, not a misleading safe 0.
func _hp_measure_after(metrics: Dictionary, delta: float) -> void:
	var raw_risk: float = float(metrics.get("raw_risk", 0.0))
	if _hp_after_analyzer == null or not _hp_after_analyzer.is_ready() or gpu_frame_pipeline == null or gpu_frame_pipeline.mitigated_after_texture == null:
		return
	var gpu_after: Dictionary = _hp_after_analyzer.analyze_texture(gpu_frame_pipeline.mitigated_after_texture, elapsed_seconds)
	var luminance := float(gpu_after.get("luminance", 0.0))
	var red := float(gpu_after.get("red", 0.0))
	var spatial := float(gpu_after.get("spatial", 0.0))
	_measured_after_risk = minf(clampf(max(max(luminance, red), spatial), 0.0, 1.35), raw_risk)
	metrics["output_risk"] = _measured_after_risk
	# Surface the mode-3 enforcement level as the HUD Mitigation track (the legacy
	# mitigation_strength is unused on this path, which left the graph pinned at 0).
	metrics["mitigation"] = float(gpu_frame_pipeline.get_last_profile().get("enforcement", 0.0))

func _analyze_raw_source_texture(time_seconds: float) -> Dictionary:
	return gpu_analyzer.analyze_texture(gpu_frame_pipeline.analysis_source_texture, time_seconds)

func _update_hud(metrics: Dictionary) -> void:
	if elapsed_seconds + 0.0001 < _next_hud_update_time:
		return
	_next_hud_update_time = elapsed_seconds + (1.0 / HUD_UPDATE_HZ)
	if risk_graph != null:
		risk_graph.add_sample(elapsed_seconds, metrics)
	_refresh_frame_sequence_seek_ui()

	for key in metric_bars.keys():
		if not metrics.has(key):
			continue
		var value := float(metrics[key])
		metric_bars[key].value = clamp(value, 0.0, 1.0)
		metric_labels[key].text = "%3d%%" % roundi(value * 100.0)

	var state := "disabled" if not quell_enabled else ("off" if not mitigation_enabled else ("active" if float(metrics["mitigation"]) > 0.01 else "idle"))
	var drop_percent := roundi(float(metrics["reduction_ratio"]) * 100.0)
	var display_size := _display_size()
	var analysis_size: Vector2i = _analysis_size_for_display(display_size)
	if gpu_frame_pipeline != null:
		analysis_size = gpu_frame_pipeline.get_analysis_size()
	status_label.text = "%s / %s / %s->%s / hue %s / budget %s / spatial %s / %s / frames %d raw %d after %d / drop %d%% / G %d area %d%% / R %d area %d%% / %s / %s" % [
		state,
		_render_backend_label(),
		"%dx%d" % [display_size.x, display_size.y],
		"%dx%d" % [analysis_size.x, analysis_size.y],
		"raw" if preserve_source_hue else "off",
		"on" if game_budget_enabled else "off",
		_spatial_sensitivity_label(),
		String(metrics.get("metric_backend", "generated")),
		_process_frame_count,
		_raw_sample_count,
		_after_sample_count,
		drop_percent,
		int(metrics.get("general_flash_count", 0)),
		roundi(float(metrics.get("general_flash_area", 0.0)) * 100.0),
		int(metrics.get("red_flash_count", 0)),
		roundi(float(metrics.get("red_flash_area", 0.0)) * 100.0),
		_contribution_status(),
		_comparator_status_for_mode(),
	]

func _apply_mode(index: int) -> void:
	current_mode = clampi(index, 0, _mode_configs.size() - 1)
	var config := _current_source_config()
	elapsed_seconds = 0.0
	if mode_select != null and mode_select.selected != current_mode:
		mode_select.select(current_mode)
	if content_material != null and not _is_frame_sequence_source(config):
		_set_content_shader_parameter("mode", current_mode)
		_set_content_shader_parameter("flash_hz", float(config["flash_hz"]))
		_set_content_shader_parameter("red_hz", float(config["red_hz"]))
		_set_content_shader_parameter("stripe_cycles", float(config["stripe_cycles"]))
		_set_content_shader_parameter("unsafe_area", float(config["unsafe_area"]))
	if game_budget_enabled and _is_frame_sequence_source(config):
		_preload_frame_sequence(config)
	_reset_analysis_state()
	_refresh_frame_sequence_seek_ui()

func _demo_risk_envelope(cycle_hz: float) -> float:
	var phase: float = sin(elapsed_seconds * TAU * cycle_hz) * 0.5 + 0.5
	return lerpf(0.58, 1.0, smoothstep(0.0, 1.0, phase))

func _sync_analyzer_settings() -> void:
	analyzer.viewing_distance_m = viewing_distance_m
	analyzer.headroom_margin = headroom_margin
	analyzer.mitigation_enabled = quell_enabled and mitigation_enabled
	analyzer.max_contrast_compression = max_contrast_compression
	analyzer.max_brightness_reduction = max_brightness_reduction
	analyzer.max_feedback_amount = max_feedback_amount
	analyzer.preserve_source_hue = preserve_source_hue
	analyzer.spatial_sensitivity = spatial_sensitivity
	_apply_contribution_settings(analyzer)
	gpu_analyzer.viewing_distance_m = viewing_distance_m

func _default_contribution_enabled() -> Dictionary:
	return {
		"luminance": true,
		"red": true,
		"spatial": true,
		"trend": true,
	}

func _apply_contribution_settings(target_analyzer) -> void:
	for key in contribution_enabled.keys():
		target_analyzer.set_contribution_enabled(String(key), bool(contribution_enabled[key]))

func _reset_analysis_state(reset_graph: bool = true) -> void:
	_reset_history_state(reset_graph, true)

func _reset_history_state(reset_graph: bool = true, reset_playback: bool = true) -> void:
	analyzer.reset()
	gpu_analyzer.reset()
	_hp_after_analyzer.reset()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.reset_output_history()
	analyzer.set_mitigation_strength(_prewarm_mitigation_for_mode(_current_source_config()))
	if reset_playback:
		_reset_frame_sequence_playback()
	_process_frame_count = 0
	_raw_sample_count = 0
	_after_sample_count = 0
	_next_hud_update_time = 0.0
	_last_runtime_metrics.clear()
	_last_after_metrics.clear()
	_last_shader_parameters.clear()
	_last_raw_sample_frame = -999999
	_last_after_sample_frame = -999999
	if reset_graph and risk_graph != null:
		risk_graph.reset()

func _register_private_frame_sequences() -> void:
	for source in PRIVATE_FRAME_SEQUENCE_SOURCES:
		_register_frame_sequence_source(source)

func _register_core_tmp_frame_sequences() -> void:
	var root_dir := _globalize_demo_path(CORE_TMP_FRAME_SEQUENCE_DIR)
	var dir := DirAccess.open(root_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while entry_name != "":
		if dir.current_is_dir() and not entry_name.begins_with("."):
			var sequence_dir := root_dir.path_join(entry_name)
			var manifest_path := sequence_dir.path_join(TMP_VIDEO_FRAME_MANIFEST)
			var manifest := _load_json_dictionary(manifest_path)
			if not manifest.is_empty():
				var source := {
					"id": String(manifest.get("id", "tmp_video_%s" % entry_name)),
					"name": String(manifest.get("name", entry_name)),
					"source_type": "frame_sequence",
					"frame_dir": String(manifest.get("frame_dir", sequence_dir)),
					"frame_prefix": String(manifest.get("frame_prefix", "frame_")),
					"frame_extension": String(manifest.get("frame_extension", ".jpg")),
					"fps": float(manifest.get("fps", 12.0)),
					"estimated_risk": float(manifest.get("estimated_risk", 1.35)),
					"validation_case_id": "",
				}
				_register_frame_sequence_source(source)
		entry_name = dir.get_next()
	dir.list_dir_end()

func _register_frame_sequence_source(source: Dictionary) -> void:
	var frame_paths := _find_frame_sequence_files(source)
	if frame_paths.is_empty():
		return
	var config := source.duplicate(true)
	var source_id := String(config.get("id", "frame_sequence_%d" % _mode_configs.size()))
	config["id"] = source_id
	config["frame_count"] = frame_paths.size()
	_frame_sequence_paths[source_id] = frame_paths
	_mode_configs.append(config)

func _load_json_dictionary(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}

func _find_frame_sequence_files(config: Dictionary) -> Array[String]:
	var frame_dir := String(config.get("frame_dir", ""))
	if frame_dir.is_empty():
		return []
	var global_dir := _globalize_demo_path(frame_dir)
	var dir := DirAccess.open(global_dir)
	if dir == null:
		return []

	var prefix := String(config.get("frame_prefix", ""))
	var extension := String(config.get("frame_extension", ".png"))
	var frame_paths: Array[String] = []
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.begins_with(prefix) and file_name.ends_with(extension):
			frame_paths.append(global_dir.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	frame_paths.sort()
	return frame_paths

func _globalize_demo_path(path: String) -> String:
	if path.is_empty():
		return path
	if path.is_absolute_path() or path.begins_with("\\\\"):
		return path.replace("\\", "/")
	return ProjectSettings.globalize_path(path).replace("\\", "/")

func _current_source_config() -> Dictionary:
	if _mode_configs.is_empty():
		return MODE_CONFIGS[0]
	return _mode_configs[clampi(current_mode, 0, _mode_configs.size() - 1)]

func _is_frame_sequence_source(config: Dictionary) -> bool:
	return String(config.get("source_type", "generated")) == "frame_sequence"

func _load_frame_sequence_image_for_demo(config: Dictionary, delta: float):
	var force_changed := _frame_sequence_force_frame_changed
	_frame_sequence_force_frame_changed = false
	var source_id := String(config.get("id", ""))
	var frame_paths: Array = _frame_sequence_paths.get(source_id, [])
	if frame_paths.is_empty():
		return null
	var fps: float = max(1.0, float(config.get("fps", 24.0)))
	if _frame_sequence_active_id != source_id:
		_frame_sequence_active_id = source_id
		_frame_sequence_index = 0
		_frame_sequence_accumulator = 0.0
	elif not force_changed:
		_frame_sequence_accumulator += max(delta, 0.0)
		var frame_duration := 1.0 / fps
		if _frame_sequence_accumulator >= frame_duration:
			var advance_count := int(floor(_frame_sequence_accumulator / frame_duration))
			_frame_sequence_index = (_frame_sequence_index + advance_count) % frame_paths.size()
			_frame_sequence_accumulator = fmod(_frame_sequence_accumulator, frame_duration)
	var frame_path := String(frame_paths[_frame_sequence_index])
	return _load_frame_sequence_path(frame_path)

func _load_frame_sequence_image(config: Dictionary, time_seconds: float, fps_limit: float = -1.0):
	var source_id := String(config.get("id", ""))
	var frame_paths: Array = _frame_sequence_paths.get(source_id, [])
	if frame_paths.is_empty():
		return null
	var fps: float = max(1.0, float(config.get("fps", 24.0)))
	if fps_limit > 0.0:
		fps = min(fps, fps_limit)
	var frame_index: int = int(floor(time_seconds * fps)) % frame_paths.size()
	var frame_path := String(frame_paths[frame_index])
	return _load_frame_sequence_path(frame_path)

func _seek_frame_sequence_to_frame(frame_index: int) -> void:
	var source := _current_source_config()
	if not _is_frame_sequence_source(source):
		return
	var source_id := String(source.get("id", ""))
	var frame_paths: Array = _frame_sequence_paths.get(source_id, [])
	if frame_paths.is_empty():
		return
	var clamped_index := clampi(frame_index, 0, frame_paths.size() - 1)
	var fps: float = max(1.0, float(source.get("fps", 24.0)))
	_frame_sequence_active_id = source_id
	_frame_sequence_index = clamped_index
	_frame_sequence_accumulator = 0.0
	_frame_sequence_force_frame_changed = true
	elapsed_seconds = float(clamped_index) / fps
	_reset_history_state(true, false)
	_refresh_frame_sequence_seek_ui()

func _refresh_frame_sequence_seek_ui() -> void:
	if frame_sequence_seek_slider == null:
		return
	var wrapper := frame_sequence_seek_slider.get_parent()
	var source := _current_source_config()
	var visible := _is_frame_sequence_source(source)
	if wrapper != null:
		wrapper.visible = visible
	if not visible:
		return
	var source_id := String(source.get("id", ""))
	var frame_paths: Array = _frame_sequence_paths.get(source_id, [])
	var frame_count := frame_paths.size()
	frame_sequence_seek_slider.editable = frame_count > 1
	frame_sequence_seek_slider.max_value = float(maxi(frame_count - 1, 0))
	frame_sequence_seek_slider.page = maxf(1.0, floor(float(frame_count) / 20.0))
	if not _frame_sequence_seek_dragging:
		frame_sequence_seek_slider.set_value_no_signal(float(clampi(_frame_sequence_index, 0, maxi(frame_count - 1, 0))))
		_set_frame_sequence_seek_label(_frame_sequence_index)

func _set_frame_sequence_seek_label(frame_index: int) -> void:
	if frame_sequence_seek_label == null:
		return
	var source := _current_source_config()
	var source_id := String(source.get("id", ""))
	var frame_paths: Array = _frame_sequence_paths.get(source_id, [])
	var frame_count := frame_paths.size()
	var fps: float = max(1.0, float(source.get("fps", 24.0)))
	var clamped_index := clampi(frame_index, 0, maxi(frame_count - 1, 0))
	var current_seconds := float(clamped_index) / fps
	var total_seconds := float(maxi(frame_count - 1, 0)) / fps
	frame_sequence_seek_label.text = "%s / %s  %d/%d" % [
		_format_time_seconds(current_seconds),
		_format_time_seconds(total_seconds),
		clamped_index + 1 if frame_count > 0 else 0,
		frame_count,
	]

func _format_time_seconds(seconds: float) -> String:
	var whole := maxi(0, int(floor(seconds)))
	var minutes := int(floor(float(whole) / 60.0))
	var secs := whole % 60
	return "%d:%02d" % [minutes, secs]

func _load_frame_sequence_path(frame_path: String):
	if _frame_cache.has(frame_path):
		return _frame_cache[frame_path]

	var image := Image.new()
	var error := image.load(frame_path)
	if error != OK:
		push_warning("Failed to load demo frame: %s" % frame_path)
		return null

	_frame_cache[frame_path] = image
	_frame_cache_order.append(frame_path)
	while _frame_cache_order.size() > FRAME_CACHE_LIMIT:
		var evicted_path := String(_frame_cache_order.pop_front())
		_frame_cache.erase(evicted_path)
	return image

func _preload_frame_sequence(config: Dictionary, start_index: int = 0, limit: int = FRAME_SEQUENCE_PRELOAD_LIMIT) -> void:
	var source_id := String(config.get("id", ""))
	var frame_paths: Array = _frame_sequence_paths.get(source_id, [])
	if frame_paths.is_empty() or limit <= 0:
		return
	var clamped_start := clampi(start_index, 0, frame_paths.size() - 1)
	var count := mini(limit, frame_paths.size())
	for offset in range(count):
		var index := (clamped_start + offset) % frame_paths.size()
		_load_frame_sequence_path(String(frame_paths[index]))

func _reset_frame_sequence_playback() -> void:
	_frame_sequence_active_id = ""
	_frame_sequence_index = 0
	_frame_sequence_accumulator = 0.0
	_frame_sequence_force_frame_changed = false

func _disabled_metrics(time_seconds: float, source_label: String) -> Dictionary:
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
		"next_mitigation": 0.0,
		"mitigation": 0.0,
		"brightness_control": 0.0,
		"contrast_control": 0.0,
		"general_flash_count": 0,
		"red_flash_count": 0,
		"general_flash_area": 0.0,
		"red_flash_area": 0.0,
		"metric_backend": source_label,
	}

func _apply_cpu_spatial_override(metrics: Dictionary, image: Image, spatial_analyzer) -> void:
	if spatial_analyzer == null:
		return
	spatial_analyzer.apply_spatial_image_override(metrics, image)

func _load_comparator_baselines() -> void:
	var text: String = FileAccess.get_file_as_string("res://tests/detection_corpus.json")
	if text.is_empty():
		return
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return
	for test_case in Array(parsed.get("cases", [])):
		_comparator_cases[String(test_case.get("id", ""))] = test_case
	_merge_comparator_results("res://validation/private/comparators/comparator-results.json")
	_merge_comparator_results("res://validation/private/comparators/peat-results.json")

func _merge_comparator_results(path: String) -> void:
	var global_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(global_path):
		return
	var text := FileAccess.get_file_as_string(global_path)
	if text.is_empty():
		return
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("Invalid comparator JSON: %s" % global_path)
		return
	for result in Array(parsed.get("results", [])):
		var case_id := String(result.get("id", ""))
		if case_id.is_empty() or not _comparator_cases.has(case_id):
			continue
		var test_case: Dictionary = _comparator_cases[case_id]
		var comparators: Dictionary = test_case.get("comparators", {})
		for key in ["iris", "peat"]:
			if result.has(key):
				comparators[key] = result[key]
		test_case["comparators"] = comparators

func _comparator_status_for_mode() -> String:
	var case_id: String = String(_current_source_config().get("validation_case_id", ""))
	if case_id.is_empty() or not _comparator_cases.has(case_id):
		return "IRIS n/a / PEAT n/a"
	var test_case: Dictionary = _comparator_cases[case_id]
	var comparators: Dictionary = test_case.get("comparators", {})
	var metric := String(test_case.get("metric", "raw_risk"))
	return "IRIS %s / PEAT %s" % [
		_comparator_label(comparators.get("iris", null), metric),
		_comparator_label(comparators.get("peat", null), metric),
	]

func _comparator_label(value, metric: String) -> String:
	if value == null:
		return "n/a"
	if value is Dictionary:
		var metrics: Dictionary = value.get("metrics", {})
		if metrics.has(metric):
			return "fail" if float(metrics[metric]) >= 1.0 else "pass"
		if metric == "spatial":
			for note in Array(value.get("notes", [])):
				if String(note).contains("no spatial-pattern field"):
					return "n/a"
		if value.has("status_text") and String(value["status_text"]).contains("Caution"):
			return "%s caution" % String(value.get("result", "data"))
		if value.has("result"):
			return String(value["result"])
	return "data"

func _prewarm_mitigation_for_mode(config: Dictionary) -> float:
	if _is_frame_sequence_source(config):
		return 0.0
	return analyzer.required_mitigation_for_risk(_estimate_mode_risk(config))

func _estimate_mode_risk(config: Dictionary) -> float:
	if _is_frame_sequence_source(config):
		if not bool(contribution_enabled.get("luminance", true)) and not bool(contribution_enabled.get("red", true)) and not bool(contribution_enabled.get("spatial", true)):
			return 0.0
		return clamp(float(config.get("estimated_risk", 1.35)), 0.0, 1.35)
	var area_risk: float = analyzer.visual_area_risk(float(config.get("unsafe_area", 0.0)))
	var luminance: float = area_risk * float(config.get("flash_amplitude", 0.0)) * analyzer.frequency_gate(float(config.get("flash_hz", 0.0))) if bool(contribution_enabled.get("luminance", true)) else 0.0
	var red: float = area_risk * float(config.get("red_amplitude", 0.0)) * analyzer.frequency_gate(float(config.get("red_hz", 0.0))) if bool(contribution_enabled.get("red", true)) else 0.0
	var stripe_cycles: float = float(config.get("stripe_cycles", 0.0))
	var spatial: float = float(config.get("spatial_contrast", 0.0)) * clamp((stripe_cycles - 8.0) / 6.0, 0.0, 1.15) if bool(contribution_enabled.get("spatial", true)) else 0.0
	return clamp(max(luminance, max(red, spatial)), 0.0, 1.35)

func _estimate_mode_temporal_contrast(config: Dictionary) -> float:
	if _is_frame_sequence_source(config):
		return 0.0
	var luminance_delta: float = float(config.get("flash_amplitude", 0.0)) * analyzer.frequency_gate(float(config.get("flash_hz", 0.0)))
	var red_delta: float = float(config.get("red_amplitude", 0.0)) * analyzer.frequency_gate(float(config.get("red_hz", 0.0))) * 0.2126
	return clamp(max(luminance_delta, red_delta), 0.0, 1.0)

func _has_gpu_frame_pipeline() -> bool:
	return (
		gpu_frame_pipeline != null
		and gpu_frame_pipeline.is_ready()
		and gpu_frame_pipeline.source_texture != null
		and gpu_frame_pipeline.after_texture != null
		and gpu_frame_pipeline.analysis_source_texture != null
		and gpu_analyzer.can_analyze_texture(gpu_frame_pipeline.analysis_source_texture)
		and _hp_after_analyzer.can_analyze_texture(gpu_frame_pipeline.analysis_after_texture)
	)

func _gpu_frame_pipeline_mitigated_after_texture() -> Texture2D:
	if gpu_frame_pipeline == null:
		return null
	for property in gpu_frame_pipeline.get_property_list():
		if String(property.get("name", "")) == "mitigated_after_texture":
			var texture = gpu_frame_pipeline.mitigated_after_texture
			if texture != null:
				return texture
			break
	return gpu_frame_pipeline.after_texture

func _render_backend_label() -> String:
	if _has_gpu_frame_pipeline():
		return "rd-texture"
	return "generated"

func _analysis_viewport_image() -> Image:
	if source_viewport == null:
		return null
	var source_texture := source_viewport.get_texture()
	if source_texture == null:
		return null
	var image := source_texture.get_image()
	if image == null or image.is_empty() or image.get_width() <= 0 or image.get_height() <= 0:
		return null
	return image

func _ensure_gpu_frame_pipeline_size(source: Dictionary) -> void:
	if gpu_frame_pipeline == null:
		return
	var display_size := _pipeline_display_size_for_source(source)
	var analysis_size := _pipeline_analysis_size_for_source(source, display_size)
	if gpu_frame_pipeline.get_display_size() == display_size and gpu_frame_pipeline.get_analysis_size() == analysis_size:
		return
	if gpu_frame_pipeline.configure(display_size, analysis_size):
		source_display.texture = gpu_frame_pipeline.after_texture
		_reset_analysis_state(false)

func _pipeline_display_size_for_source(source: Dictionary) -> Vector2i:
	return _display_size()

func _pipeline_analysis_size_for_source(source: Dictionary, display_size: Vector2i) -> Vector2i:
	if game_budget_enabled:
		return _analysis_size_for_display_with_divisor(display_size, GAME_BUDGET_ANALYSIS_SCALE_DIVISOR)
	if _is_frame_sequence_source(source) and not game_budget_enabled:
		return _frame_sequence_source_size(source)
	return _analysis_size_for_display(display_size)

func _frame_sequence_source_size(source: Dictionary) -> Vector2i:
	var source_id := String(source.get("id", ""))
	var frame_paths: Array = _frame_sequence_paths.get(source_id, [])
	if not frame_paths.is_empty():
		var image: Image = _load_frame_sequence_path(String(frame_paths[0]))
		if image != null and not image.is_empty():
			return Vector2i(maxi(1, image.get_width()), maxi(1, image.get_height()))
	return _analysis_size_for_display(_display_size())

func _set_content_shader_parameter(parameter: StringName, value: Variant) -> void:
	if content_material != null:
		content_material.set_shader_parameter(parameter, value)

func _display_size() -> Vector2i:
	var window_size: Vector2i = get_window().size
	if window_size.x <= 0 or window_size.y <= 0:
		var viewport_size: Vector2 = get_viewport_rect().size
		return Vector2i(max(1, roundi(viewport_size.x)), max(1, roundi(viewport_size.y)))
	return Vector2i(max(1, window_size.x), max(1, window_size.y))

func _analysis_size_for_display(display_size: Vector2i) -> Vector2i:
	return _analysis_size_for_display_with_divisor(display_size, ANALYSIS_SCALE_DIVISOR)

func _analysis_size_for_display_with_divisor(display_size: Vector2i, divisor: int) -> Vector2i:
	divisor = maxi(1, divisor)
	return Vector2i(
		max(1, int(ceil(float(display_size.x) / float(divisor)))),
		max(1, int(ceil(float(display_size.y) / float(divisor))))
	)

func _refresh_static_labels() -> void:
	if distance_value_label != null:
		distance_value_label.text = "%.2f m" % viewing_distance_m
	if headroom_value_label != null:
		headroom_value_label.text = "%d%%" % roundi(headroom_margin * 100.0)
	if brightness_limit_value_label != null:
		brightness_limit_value_label.text = "%d%%" % roundi(max_brightness_reduction * 100.0)
	if contrast_limit_value_label != null:
		contrast_limit_value_label.text = "%d%%" % roundi(max_contrast_compression * 100.0)
	if feedback_limit_value_label != null:
		feedback_limit_value_label.text = "%d%%" % roundi(max_feedback_amount * 100.0)
	if risk_graph != null:
		risk_graph.headroom_margin = headroom_margin
		risk_graph.queue_redraw()

func _on_mode_selected(index: int) -> void:
	_apply_mode(index)

func _on_mitigation_toggled(enabled: bool) -> void:
	mitigation_enabled = enabled
	_sync_analyzer_settings()
	_reset_analysis_state()

func _on_quell_toggled(enabled: bool) -> void:
	quell_enabled = enabled
	_sync_analyzer_settings()
	_reset_analysis_state()

func _on_spatial_sensitivity_selected(index: int) -> void:
	spatial_sensitivity = spatial_sensitivity_select.get_item_id(index)
	_sync_analyzer_settings()
	_reset_analysis_state()

func _on_hue_preserve_toggled(enabled: bool) -> void:
	preserve_source_hue = enabled
	_sync_analyzer_settings()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.reset_output_history()

func _on_game_budget_toggled(enabled: bool) -> void:
	game_budget_enabled = enabled
	if game_budget_enabled and _is_frame_sequence_source(_current_source_config()):
		_preload_frame_sequence(_current_source_config())
	_sync_analyzer_settings()
	_ensure_gpu_frame_pipeline_size(_current_source_config())
	_reset_analysis_state()

func _on_frame_sequence_seek_drag_started() -> void:
	_frame_sequence_seek_dragging = true

func _on_frame_sequence_seek_drag_ended(_value_changed: bool) -> void:
	_frame_sequence_seek_dragging = false
	if frame_sequence_seek_slider == null:
		return
	_seek_frame_sequence_to_frame(roundi(float(frame_sequence_seek_slider.value)))

func _on_frame_sequence_seek_value_changed(value: float) -> void:
	if _frame_sequence_seek_dragging:
		_set_frame_sequence_seek_label(roundi(value))

func _on_restart_video_pressed() -> void:
	elapsed_seconds = 0.0
	_reset_frame_sequence_playback()
	_reset_history_state()

func _on_clear_history_pressed() -> void:
	_reset_history_state(true, false)

func _on_contribution_toggled(enabled: bool, component: String) -> void:
	contribution_enabled[component] = enabled
	_sync_analyzer_settings()
	_reset_analysis_state()

func _on_viewing_distance_changed(value: float) -> void:
	viewing_distance_m = value
	_sync_analyzer_settings()
	_refresh_static_labels()

func _on_contrast_limit_changed(value: float) -> void:
	max_contrast_compression = value
	_sync_analyzer_settings()
	_refresh_static_labels()

func _on_brightness_limit_changed(value: float) -> void:
	max_brightness_reduction = value
	_sync_analyzer_settings()
	_refresh_static_labels()

func _on_feedback_limit_changed(value: float) -> void:
	max_feedback_amount = value
	_sync_analyzer_settings()
	_refresh_static_labels()

func _on_headroom_changed(value: float) -> void:
	headroom_margin = value
	_sync_analyzer_settings()
	_refresh_static_labels()

func _spatial_sensitivity_label() -> String:
	if spatial_sensitivity == SPATIAL_SENSITIVITY_BALANCED:
		return "balanced"
	return "strict"

func _contribution_status() -> String:
	var ignored := PackedStringArray()
	if not bool(contribution_enabled.get("luminance", true)):
		ignored.append("Luma")
	if not bool(contribution_enabled.get("red", true)):
		ignored.append("Red")
	if not bool(contribution_enabled.get("spatial", true)):
		ignored.append("Spatial")
	if not bool(contribution_enabled.get("trend", true)):
		ignored.append("Trend")
	if ignored.is_empty():
		return "inputs all"
	return "ignored %s" % ", ".join(ignored)
