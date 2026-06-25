extends Control

const CORE_ANALYZER_PATH := "res://addons/quell_core/runtime/quell_analyzer.gd"
const CORE_GPU_ANALYZER_PATH := "res://addons/quell_core/runtime/quell_gpu_analyzer.gd"
const CORE_GPU_FRAME_PIPELINE_PATH := "res://addons/quell_core/runtime/quell_gpu_frame_pipeline.gd"
const CORE_CURRENT_FRAME_SOLVER_PATH := "res://addons/quell_core/runtime/quell_current_frame_solver.gd"
const RiskGraphClass = preload("res://scripts/quell_risk_graph.gd")

var QuellAnalyzerClass
var GpuAnalyzerClass
var GpuFramePipelineClass
var CurrentFrameSolverClass
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
const DEFAULT_ANALYSIS_SCALE_DIVISOR: int = 4
const GAME_BUDGET_ANALYSIS_SCALE_DIVISOR: int = 8
const GAME_BUDGET_RAW_ANALYSIS_INTERVAL_FRAMES: int = 3
const GAME_BUDGET_AFTER_FEEDBACK_INTERVAL_FRAMES: int = 4
const ENABLE_K64_IO_BY_DEFAULT: bool = false
const ENABLE_FRAME_SEQUENCE_RAW_SPATIAL_CPU_OVERRIDE: bool = false
const ENABLE_FRAME_SEQUENCE_AFTER_SPATIAL_READBACK: bool = false
const HUD_UPDATE_HZ: float = 10.0
var elapsed_seconds := 0.0
var current_mode := 0
var mitigation_enabled := true
var mitigation_mode := 0
var temporal_blend_alpha := 0.50
var max_contrast_compression := 0.65
var max_brightness_reduction := 0.50
var max_feedback_amount := 0.60
var local_correction_enabled := true
var preserve_source_hue := true
var current_frame_solver_enabled := true
var game_budget_mode_enabled := false
var analysis_scale_divisor := DEFAULT_ANALYSIS_SCALE_DIVISOR
var raw_analysis_interval_frames := 1
var after_feedback_interval_frames := 1
var spatial_sensitivity := 0
var viewing_distance_m := 0.60
var headroom_margin := 0.80
var contribution_enabled: Dictionary = {}

var analyzer
var after_analyzer
var gpu_analyzer
var gpu_after_analyzer
var current_frame_solver
var gpu_frame_pipeline
var source_viewport: SubViewport
var source_display: TextureRect
var content_material: ShaderMaterial
var mode_select: OptionButton
var mitigation_mode_select: OptionButton
var spatial_sensitivity_select: OptionButton
var mitigation_toggle: CheckButton
var local_correction_toggle: CheckButton
var hue_preserve_toggle: CheckButton
var current_frame_solver_toggle: CheckButton
var distance_value_label: Label
var headroom_value_label: Label
var temporal_blend_value_label: Label
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
var _frame_sequence_frame_changed := false
var _frame_sequence_pending_analysis_delta := 0.0
var _last_frame_sequence_metrics: Dictionary = {}
var _last_runtime_metrics: Dictionary = {}
var _last_after_metrics: Dictionary = {}
var _last_shader_parameters: Dictionary = {}
var _next_hud_update_time: float = 0.0
var _profile_enabled: bool = false
var _profile_accum: Dictionary = {}
var _profile_next_report: float = 0.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	Engine.max_fps = 60
	get_window().title = "[quell-godot] Godot Prototype"
	if not _load_core_classes():
		_build_notice("Quell private core is not installed.\nRun tools/sync_private_core.ps1 C:\\Users\\komm64\\Projects\\quell-core first.")
		return
	_profile_enabled = _cmdline_has_flag("--quell-profile")
	game_budget_mode_enabled = _cmdline_has_flag("--quell-game-budget")
	current_frame_solver_enabled = not (_cmdline_has_flag("--quell-no-solver") or _cmdline_has_flag("--quell-no-current-frame-solver"))
	if _cmdline_has_flag("--quell-solver") or _cmdline_has_flag("--quell-current-frame-solver"):
		current_frame_solver_enabled = true
	if game_budget_mode_enabled:
		current_frame_solver_enabled = false
		analysis_scale_divisor = GAME_BUDGET_ANALYSIS_SCALE_DIVISOR
		raw_analysis_interval_frames = GAME_BUDGET_RAW_ANALYSIS_INTERVAL_FRAMES
		after_feedback_interval_frames = GAME_BUDGET_AFTER_FEEDBACK_INTERVAL_FRAMES
	analysis_scale_divisor = max(1, _cmdline_int_value("--quell-analysis-divisor=", analysis_scale_divisor))
	raw_analysis_interval_frames = max(1, _cmdline_int_value("--quell-raw-analysis-interval=", raw_analysis_interval_frames))
	after_feedback_interval_frames = max(1, _cmdline_int_value("--quell-after-feedback-interval=", after_feedback_interval_frames))
	analyzer = QuellAnalyzerClass.new()
	after_analyzer = QuellAnalyzerClass.new()
	gpu_analyzer = GpuAnalyzerClass.new()
	gpu_after_analyzer = GpuAnalyzerClass.new()
	current_frame_solver = CurrentFrameSolverClass.new()
	gpu_frame_pipeline = GpuFramePipelineClass.new()
	mitigation_mode = QuellAnalyzerClass.MitigationMode.CURRENT_FRAME_ONLY
	spatial_sensitivity = QuellAnalyzerClass.SpatialSensitivity.BALANCED
	contribution_enabled = _default_contribution_enabled()
	_mode_configs = MODE_CONFIGS.duplicate(true)
	_register_private_frame_sequences()
	_load_comparator_baselines()
	_sync_analyzer_settings()
	_build_visual_layers()
	_build_hud()
	_apply_mode(_initial_mode_index())
	_start_k64_io()

func _load_core_classes() -> bool:
	for path in [CORE_ANALYZER_PATH, CORE_GPU_ANALYZER_PATH, CORE_GPU_FRAME_PIPELINE_PATH, CORE_CURRENT_FRAME_SOLVER_PATH]:
		if not ResourceLoader.exists(path):
			return false
	QuellAnalyzerClass = load(CORE_ANALYZER_PATH)
	GpuAnalyzerClass = load(CORE_GPU_ANALYZER_PATH)
	GpuFramePipelineClass = load(CORE_GPU_FRAME_PIPELINE_PATH)
	CurrentFrameSolverClass = load(CORE_CURRENT_FRAME_SOLVER_PATH)
	_core_available = QuellAnalyzerClass != null and GpuAnalyzerClass != null and GpuFramePipelineClass != null and CurrentFrameSolverClass != null
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
	if gpu_after_analyzer != null:
		gpu_after_analyzer.dispose()
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
		if debug_panel != null:
			debug_panel.visible = not debug_panel.visible
		get_viewport().set_input_as_handled()
	elif keycode == KEY_F2:
		if risk_graph != null:
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
	io.call("set_game", "quell_godot_prototype", "0.1.0")
	io.call("register_sense", "/quell/status", Callable(self, "_provide_k64_status"), {
		"doc": "current Quell demo UI/debug state",
		"volatility": "per-frame",
		"fields": [
			{"name": "source", "type": "string", "doc": "selected source mode"},
			{"name": "mitigation_enabled", "type": "bool", "doc": "UI mitigation toggle"},
			{"name": "mitigation_mode", "type": "int", "doc": "QuellAnalyzer.MitigationMode enum value"},
			{"name": "headroom_margin", "type": "float", "doc": "After target slider"},
			{"name": "max_contrast_compression", "type": "float", "doc": "maximum contrast compression slider"},
			{"name": "max_brightness_reduction", "type": "float", "doc": "maximum brightness reduction slider"},
			{"name": "max_feedback_amount", "type": "float", "doc": "maximum temporal feedback slider"},
			{"name": "local_correction_enabled", "type": "bool", "doc": "local correction toggle"},
			{"name": "preserve_source_hue", "type": "bool", "doc": "Raw hue reconstruction toggle"},
			{"name": "current_frame_solver_enabled", "type": "bool", "doc": "CurrentFrame preview solver toggle"},
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
	io.call("register_action", "quell_set_policy", Callable(self, "_act_k64_set_policy"), {
		"args": [{"name": "mode", "type": "int"}],
	})
	io.call("register_action", "quell_set_mitigation", Callable(self, "_act_k64_set_mitigation"), {
		"args": [{"name": "enabled", "type": "bool"}],
	})
	io.call("register_action", "quell_set_temporal_alpha", Callable(self, "_act_k64_set_temporal_alpha"), {
		"args": [{"name": "alpha", "type": "float"}],
	})
	io.call("register_action", "quell_set_contrast_max", Callable(self, "_act_k64_set_contrast_max"), {
		"args": [{"name": "compression", "type": "float"}],
	})
	io.call("register_action", "quell_set_brightness_max", Callable(self, "_act_k64_set_brightness_max"), {
		"args": [{"name": "reduction", "type": "float"}],
	})
	io.call("register_action", "quell_set_feedback_max", Callable(self, "_act_k64_set_feedback_max"), {
		"args": [{"name": "amount", "type": "float"}],
	})
	io.call("register_action", "quell_set_local_correction", Callable(self, "_act_k64_set_local_correction"), {
		"args": [{"name": "enabled", "type": "bool"}],
	})
	io.call("register_action", "quell_set_hue_preserve", Callable(self, "_act_k64_set_hue_preserve"), {
		"args": [{"name": "enabled", "type": "bool"}],
	})
	io.call("register_action", "quell_set_current_frame_solver", Callable(self, "_act_k64_set_current_frame_solver"), {
		"args": [{"name": "enabled", "type": "bool"}],
	})
	io.call("register_action", "quell_restart_video", Callable(self, "_act_k64_restart_video"), {
		"args": [],
	})
	io.call("register_action", "quell_clear_history", Callable(self, "_act_k64_clear_history"), {
		"args": [],
	})
	io.call("register_action", "quell_set_spatial_sensitivity", Callable(self, "_act_k64_set_spatial_sensitivity"), {
		"args": [{"name": "mode", "type": "int"}],
	})
	io.call("register_action", "quell_set_contribution", Callable(self, "_act_k64_set_contribution"), {
		"args": [
			{"name": "component", "type": "string"},
			{"name": "enabled", "type": "bool"},
		],
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

func _cmdline_int_value(prefix: String, default_value: int) -> int:
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return int(arg.substr(prefix.length()))
	return default_value

func _profile_add(key: String, usec: int) -> void:
	if not _profile_enabled:
		return
	_profile_accum[key] = int(_profile_accum.get(key, 0)) + usec

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
	for key in ["setup_us", "ready_us", "ensure_us", "load_us", "cache_us", "texture_us", "analyze_us", "controller_us", "shader_us", "feedback_us", "store_us", "hud_us"]:
		tracked_us += int(_profile_accum.get(key, 0))
	print("[quell-profile] gpu %s pipeline_ready %s analyzer_ready %s texture %s setup %.2fms ready %.2fms ensure %.2fms load %.2fms cache %.2fms texture %.2fms analyze %.2fms controller %.2fms shader %.2fms feedback %.2fms store %.2fms hud %.2fms other %.2fms total %.2fms samples %d" % [
		str(_has_gpu_frame_pipeline()),
		str(gpu_frame_pipeline != null and gpu_frame_pipeline.is_ready()),
		str(gpu_analyzer != null and gpu_analyzer.is_ready()),
		str(gpu_frame_pipeline != null and gpu_frame_pipeline.analysis_source_texture != null),
		float(_profile_accum.get("setup_us", 0)) / float(samples) / 1000.0,
		float(_profile_accum.get("ready_us", 0)) / float(samples) / 1000.0,
		float(_profile_accum.get("ensure_us", 0)) / float(samples) / 1000.0,
		float(_profile_accum.get("load_us", 0)) / float(samples) / 1000.0,
		float(_profile_accum.get("cache_us", 0)) / float(samples) / 1000.0,
		float(_profile_accum.get("texture_us", 0)) / float(samples) / 1000.0,
		float(_profile_accum.get("analyze_us", 0)) / float(samples) / 1000.0,
		float(_profile_accum.get("controller_us", 0)) / float(samples) / 1000.0,
		float(_profile_accum.get("shader_us", 0)) / float(samples) / 1000.0,
		float(_profile_accum.get("feedback_us", 0)) / float(samples) / 1000.0,
		float(_profile_accum.get("store_us", 0)) / float(samples) / 1000.0,
		float(_profile_accum.get("hud_us", 0)) / float(samples) / 1000.0,
		float(max(0, total_us - tracked_us)) / float(samples) / 1000.0,
		float(_profile_accum.get("total_us", 0)) / float(samples) / 1000.0,
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
	var analysis_size := _analysis_size_for_display(display_size)
	return {
		"source": String(source.get("name", "")),
		"mitigation_enabled": mitigation_enabled,
		"mitigation_mode": int(mitigation_mode),
		"headroom_margin": headroom_margin,
		"temporal_blend_alpha": temporal_blend_alpha,
		"max_contrast_compression": max_contrast_compression,
		"max_brightness_reduction": max_brightness_reduction,
		"max_feedback_amount": max_feedback_amount,
		"local_correction_enabled": local_correction_enabled,
		"preserve_source_hue": preserve_source_hue,
		"current_frame_solver_enabled": current_frame_solver_enabled,
		"spatial_sensitivity": int(spatial_sensitivity),
		"render_backend": _render_backend_label(),
		"display_size": "%dx%d" % [display_size.x, display_size.y],
		"analysis_size": "%dx%d" % [analysis_size.x, analysis_size.y],
		"pipeline_display_size": "%dx%d" % [gpu_frame_pipeline.get_display_size().x, gpu_frame_pipeline.get_display_size().y] if gpu_frame_pipeline != null else "",
		"pipeline_analysis_size": "%dx%d" % [gpu_frame_pipeline.get_analysis_size().x, gpu_frame_pipeline.get_analysis_size().y] if gpu_frame_pipeline != null else "",
		"raw_risk": float(_last_runtime_metrics.get("raw_risk", 0.0)),
		"after_risk": float(_last_after_metrics.get("raw_risk", _last_runtime_metrics.get("solver_after_risk", 0.0))),
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

func _act_k64_set_policy(args: Dictionary) -> Dictionary:
	mitigation_mode = clampi(int(args.get("mode", mitigation_mode)), QuellAnalyzerClass.MitigationMode.CURRENT_FRAME_ONLY, QuellAnalyzerClass.MitigationMode.ADAPTIVE)
	_select_option_by_item_id(mitigation_mode_select, mitigation_mode)
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

func _act_k64_set_temporal_alpha(args: Dictionary) -> Dictionary:
	temporal_blend_alpha = clamp(float(args.get("alpha", temporal_blend_alpha)), 0.05, 1.0)
	_sync_analyzer_settings()
	_refresh_static_labels()
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

func _act_k64_set_local_correction(args: Dictionary) -> Dictionary:
	local_correction_enabled = bool(args.get("enabled", args.get("value", local_correction_enabled)))
	if local_correction_toggle != null:
		local_correction_toggle.set_pressed_no_signal(local_correction_enabled)
	_sync_analyzer_settings()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.reset_output_history()
	return _provide_k64_status()

func _act_k64_set_hue_preserve(args: Dictionary) -> Dictionary:
	preserve_source_hue = bool(args.get("enabled", args.get("value", preserve_source_hue)))
	if hue_preserve_toggle != null:
		hue_preserve_toggle.set_pressed_no_signal(preserve_source_hue)
	_sync_analyzer_settings()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.reset_output_history()
	return _provide_k64_status()

func _act_k64_set_current_frame_solver(args: Dictionary) -> Dictionary:
	current_frame_solver_enabled = bool(args.get("enabled", args.get("value", current_frame_solver_enabled)))
	if current_frame_solver_toggle != null:
		current_frame_solver_toggle.set_pressed_no_signal(current_frame_solver_enabled)
	_sync_analyzer_settings()
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
	if requested == QuellAnalyzerClass.SpatialSensitivity.BALANCED:
		spatial_sensitivity = QuellAnalyzerClass.SpatialSensitivity.BALANCED
	else:
		spatial_sensitivity = QuellAnalyzerClass.SpatialSensitivity.STRICT
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
		if _is_frame_sequence_source(source):
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
		shader_parameters = analyzer.shader_parameters(metrics)
		_apply_shader_parameter_metrics(metrics, shader_parameters)
	elif has_gpu_frame_pipeline:
		var ensure_start := Time.get_ticks_usec()
		_ensure_gpu_frame_pipeline_size(source)
		_profile_add("ensure_us", Time.get_ticks_usec() - ensure_start)
		var uploaded_sequence_frame := false
		var analysis_delta := delta
		var after_analysis_delta := delta
		var gpu_sequence_image = null
		if _is_frame_sequence_source(source):
			_frame_sequence_pending_analysis_delta += max(delta, 0.0)
			var load_start := Time.get_ticks_usec()
			gpu_sequence_image = _load_frame_sequence_image_for_demo(source, delta)
			_profile_add("load_us", Time.get_ticks_usec() - load_start)
			if not _frame_sequence_frame_changed and not _last_frame_sequence_metrics.is_empty():
				var cache_start := Time.get_ticks_usec()
				metrics = _last_frame_sequence_metrics.duplicate(false)
				metrics["metric_backend"] = "gpu-frame-seq-cached"
				_profile_add("cache_us", Time.get_ticks_usec() - cache_start)
				if mitigation_enabled and gpu_frame_pipeline != null and gpu_frame_pipeline.after_texture != null and _should_measure_after_feedback():
					_after_sample_count += 1
					var held_after_start := Time.get_ticks_usec()
					var held_after_metrics: Dictionary = _measure_after_for_source(source, elapsed_seconds, after_analysis_delta)
					_profile_add("analyze_us", Time.get_ticks_usec() - held_after_start)
					var held_feedback_start := Time.get_ticks_usec()
					_apply_measured_after_metrics(metrics, held_after_metrics, after_analysis_delta)
					_last_after_metrics = held_after_metrics.duplicate(false)
					_last_runtime_metrics = metrics.duplicate(false)
					_last_frame_sequence_metrics = metrics.duplicate(false)
					_profile_add("feedback_us", Time.get_ticks_usec() - held_feedback_start)
				var cached_hud_start := Time.get_ticks_usec()
				_update_hud(metrics)
				_profile_add("hud_us", Time.get_ticks_usec() - cached_hud_start)
				_profile_add("total_us", Time.get_ticks_usec() - profile_total_start)
				_profile_sample()
				_capture_requested_frame_if_ready()
				return
			analysis_delta = max(_frame_sequence_pending_analysis_delta, delta)
			_frame_sequence_pending_analysis_delta = 0.0
			if gpu_sequence_image != null:
				var upload_start := Time.get_ticks_usec()
				uploaded_sequence_frame = gpu_frame_pipeline.upload_source_image(gpu_sequence_image, true)
				_profile_add("texture_us", Time.get_ticks_usec() - upload_start)
		if not uploaded_sequence_frame:
			var source_config := source.duplicate(true)
			source_config["index"] = current_mode
			var generate_start := Time.get_ticks_usec()
			gpu_frame_pipeline.generate_source(source_config, elapsed_seconds, envelope)
			_profile_add("texture_us", Time.get_ticks_usec() - generate_start)
		if _can_reuse_runtime_control(uploaded_sequence_frame):
			metrics = _last_runtime_metrics.duplicate(false)
			metrics["metric_backend"] = "gpu-frame-seq-reused" if uploaded_sequence_frame else "gpu-rd-reused"
			shader_parameters = _last_shader_parameters.duplicate(false)
			_apply_shader_parameter_metrics(metrics, shader_parameters)
			var reuse_mitigate_start := Time.get_ticks_usec()
			gpu_frame_pipeline.apply_mitigation(shader_parameters)
			_profile_add("texture_us", Time.get_ticks_usec() - reuse_mitigate_start)
			if not _last_after_metrics.is_empty():
				var reuse_feedback_start := Time.get_ticks_usec()
				_reuse_last_after_metrics(metrics, _last_after_metrics)
				_profile_add("feedback_us", Time.get_ticks_usec() - reuse_feedback_start)
			var reuse_hud_start := Time.get_ticks_usec()
			_update_hud(metrics)
			_profile_add("hud_us", Time.get_ticks_usec() - reuse_hud_start)
			_profile_add("total_us", Time.get_ticks_usec() - profile_total_start)
			_profile_sample()
			_capture_requested_frame_if_ready()
			return
		_raw_sample_count += 1
		var analyze_start := Time.get_ticks_usec()
		var raw_gpu_metrics: Dictionary = gpu_analyzer.analyze_texture(gpu_frame_pipeline.analysis_source_texture, elapsed_seconds)
		_profile_add("analyze_us", Time.get_ticks_usec() - analyze_start)
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
		metrics = analyzer.update_from_metrics(raw_gpu_metrics, analysis_delta, elapsed_seconds)
		_profile_add("controller_us", Time.get_ticks_usec() - controller_start)
		metrics["metric_backend"] = "gpu-frame-seq" if uploaded_sequence_frame else "gpu-rd"
		var shader_start := Time.get_ticks_usec()
		shader_parameters = analyzer.shader_parameters(metrics)
		var solver_result: Dictionary = current_frame_solver.solve(
			gpu_frame_pipeline,
			gpu_after_analyzer,
			after_analyzer,
			shader_parameters,
			headroom_margin,
			after_analysis_delta,
			elapsed_seconds,
			"frame_sequence" if uploaded_sequence_frame else "generated",
			null,
			false,
			metrics
		)
		shader_parameters = solver_result.get("parameters", shader_parameters)
		_apply_current_frame_solver_metrics(metrics, solver_result)
		analyzer.apply_current_frame_shader_solution(shader_parameters, metrics)
		_apply_shader_parameter_metrics(metrics, shader_parameters)
		_last_shader_parameters = shader_parameters.duplicate(false)
		_profile_add("shader_us", Time.get_ticks_usec() - shader_start)
		var mitigate_start := Time.get_ticks_usec()
		gpu_frame_pipeline.apply_mitigation(shader_parameters)
		_profile_add("texture_us", Time.get_ticks_usec() - mitigate_start)
		var should_measure_after := not mitigation_enabled or _should_measure_after_feedback()
		if should_measure_after:
			_after_sample_count += 1
		var after_analyze_start := Time.get_ticks_usec()
		var after_metrics: Dictionary = {}
		if not mitigation_enabled:
			after_metrics = metrics.duplicate(true)
		elif should_measure_after:
			after_metrics = _measure_after_for_source(source, elapsed_seconds, after_analysis_delta)
		else:
			after_metrics = _last_after_metrics.duplicate(false)
		_profile_add("analyze_us", Time.get_ticks_usec() - after_analyze_start)
		var feedback_start := Time.get_ticks_usec()
		if should_measure_after:
			_apply_measured_after_metrics(metrics, after_metrics, after_analysis_delta)
			_last_after_metrics = after_metrics.duplicate(false)
		else:
			_reuse_last_after_metrics(metrics, after_metrics)
		_last_runtime_metrics = metrics.duplicate(false)
		_profile_add("feedback_us", Time.get_ticks_usec() - feedback_start)
		if uploaded_sequence_frame:
			var store_start := Time.get_ticks_usec()
			_last_frame_sequence_metrics = metrics.duplicate(false)
			_profile_add("store_us", Time.get_ticks_usec() - store_start)
	else:
		metrics = analyzer.update_from_generated_source(source, delta, elapsed_seconds)
		metrics["metric_backend"] = "generated"
		shader_parameters = analyzer.shader_parameters(metrics)
		_apply_shader_parameter_metrics(metrics, shader_parameters)
	var hud_start := Time.get_ticks_usec()
	_update_hud(metrics)
	_profile_add("hud_us", Time.get_ticks_usec() - hud_start)
	_profile_add("total_us", Time.get_ticks_usec() - profile_total_start)
	_profile_sample()
	_capture_requested_frame_if_ready()

func _capture_requested_frame_if_ready() -> void:
	if _process_frame_count == 130 and OS.get_environment("QUELL_SHOT") != "":
		var shot_img := get_viewport().get_texture().get_image()
		if shot_img != null:
			shot_img.save_png(OS.get_environment("QUELL_SHOT"))
		get_tree().quit()

func _build_visual_layers() -> void:
	var source := _current_source_config()
	var display_size := _pipeline_display_size_for_source(source)
	var analysis_size := _pipeline_analysis_size_for_source(source, display_size)
	if gpu_frame_pipeline != null and gpu_analyzer.is_ready() and gpu_after_analyzer.is_ready() and gpu_frame_pipeline.configure(display_size, analysis_size):
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

	mitigation_toggle = CheckButton.new()
	mitigation_toggle.text = "Mitigation"
	mitigation_toggle.button_pressed = mitigation_enabled
	mitigation_toggle.toggled.connect(_on_mitigation_toggled)
	stack.add_child(mitigation_toggle)

	mitigation_mode_select = OptionButton.new()
	mitigation_mode_select.add_item("Current frame", QuellAnalyzerClass.MitigationMode.CURRENT_FRAME_ONLY)
	mitigation_mode_select.add_item("Temporal blend", QuellAnalyzerClass.MitigationMode.TEMPORAL_BLEND)
	mitigation_mode_select.add_item("Adaptive", QuellAnalyzerClass.MitigationMode.ADAPTIVE)
	mitigation_mode_select.select(int(mitigation_mode))
	mitigation_mode_select.item_selected.connect(_on_mitigation_mode_selected)
	stack.add_child(_with_caption("Policy", mitigation_mode_select))

	spatial_sensitivity_select = OptionButton.new()
	spatial_sensitivity_select.add_item("Balanced", QuellAnalyzerClass.SpatialSensitivity.BALANCED)
	spatial_sensitivity_select.add_item("Strict", QuellAnalyzerClass.SpatialSensitivity.STRICT)
	_select_option_by_item_id(spatial_sensitivity_select, int(spatial_sensitivity))
	spatial_sensitivity_select.item_selected.connect(_on_spatial_sensitivity_selected)
	stack.add_child(_with_caption("Spatial", spatial_sensitivity_select))

	local_correction_toggle = CheckButton.new()
	local_correction_toggle.text = "Local correction"
	local_correction_toggle.button_pressed = local_correction_enabled
	local_correction_toggle.toggled.connect(_on_local_correction_toggled)
	stack.add_child(local_correction_toggle)

	hue_preserve_toggle = CheckButton.new()
	hue_preserve_toggle.text = "Raw hue"
	hue_preserve_toggle.button_pressed = preserve_source_hue
	hue_preserve_toggle.toggled.connect(_on_hue_preserve_toggled)
	stack.add_child(hue_preserve_toggle)

	current_frame_solver_toggle = CheckButton.new()
	current_frame_solver_toggle.text = "CurrentFrame solver"
	current_frame_solver_toggle.button_pressed = current_frame_solver_enabled
	current_frame_solver_toggle.toggled.connect(_on_current_frame_solver_toggled)
	stack.add_child(current_frame_solver_toggle)

	stack.add_child(_reset_controls())
	stack.add_child(_contribution_controls())

	var distance_slider := HSlider.new()
	distance_slider.min_value = 0.25
	distance_slider.max_value = 2.00
	distance_slider.step = 0.05
	distance_slider.value = viewing_distance_m
	distance_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	distance_slider.value_changed.connect(_on_viewing_distance_changed)
	distance_value_label = Label.new()
	stack.add_child(_slider_row("Viewing distance", distance_slider, distance_value_label))

	var headroom_slider := HSlider.new()
	headroom_slider.min_value = 0.70
	headroom_slider.max_value = 0.99
	headroom_slider.step = 0.01
	headroom_slider.value = headroom_margin
	headroom_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	headroom_slider.value_changed.connect(_on_headroom_changed)
	headroom_value_label = Label.new()
	stack.add_child(_slider_row("After target", headroom_slider, headroom_value_label))

	var temporal_blend_slider := HSlider.new()
	temporal_blend_slider.min_value = 0.05
	temporal_blend_slider.max_value = 1.00
	temporal_blend_slider.step = 0.05
	temporal_blend_slider.value = temporal_blend_alpha
	temporal_blend_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	temporal_blend_slider.value_changed.connect(_on_temporal_blend_changed)
	temporal_blend_value_label = Label.new()
	stack.add_child(_slider_row("Temporal alpha", temporal_blend_slider, temporal_blend_value_label))

	brightness_limit_slider = HSlider.new()
	brightness_limit_slider.min_value = 0.00
	brightness_limit_slider.max_value = 0.90
	brightness_limit_slider.step = 0.05
	brightness_limit_slider.value = max_brightness_reduction
	brightness_limit_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brightness_limit_slider.value_changed.connect(_on_brightness_limit_changed)
	brightness_limit_value_label = Label.new()
	stack.add_child(_slider_row("Brightness max", brightness_limit_slider, brightness_limit_value_label))

	contrast_limit_slider = HSlider.new()
	contrast_limit_slider.min_value = 0.00
	contrast_limit_slider.max_value = 0.90
	contrast_limit_slider.step = 0.05
	contrast_limit_slider.value = max_contrast_compression
	contrast_limit_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	contrast_limit_slider.value_changed.connect(_on_contrast_limit_changed)
	contrast_limit_value_label = Label.new()
	stack.add_child(_slider_row("Contrast max", contrast_limit_slider, contrast_limit_value_label))

	feedback_limit_slider = HSlider.new()
	feedback_limit_slider.min_value = 0.00
	feedback_limit_slider.max_value = 0.95
	feedback_limit_slider.step = 0.05
	feedback_limit_slider.value = max_feedback_amount
	feedback_limit_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	feedback_limit_slider.value_changed.connect(_on_feedback_limit_changed)
	feedback_limit_value_label = Label.new()
	stack.add_child(_slider_row("Feedback max", feedback_limit_slider, feedback_limit_value_label))

	_add_metric_row(stack, "luminance", "Luminance")
	_add_metric_row(stack, "red", "Red")
	_add_metric_row(stack, "spatial", "Spatial")
	_add_metric_row(stack, "trend", "Trend")
	_add_metric_row(stack, "raw_risk", "Raw risk")
	_add_metric_row(stack, "output_risk", "After")
	_add_metric_row(stack, "reduction_ratio", "Drop")
	_add_metric_row(stack, "brightness_control", "Brightness")
	_add_metric_row(stack, "contrast_control", "Contrast")
	_add_metric_row(stack, "feedback_control", "Feedback")
	_add_metric_row(stack, "local_correction", "Local")
	_add_metric_row(stack, "mitigation", "Mitigation")

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Color(0.70, 0.78, 0.82))
	stack.add_child(status_label)

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
	metrics["feedback_control"] = 1.0 - float(parameters.get("temporal_blend_alpha", 1.0))
	metrics["local_correction"] = float(parameters.get("local_correction_strength", 0.0))

func _should_measure_after_feedback() -> bool:
	if after_feedback_interval_frames <= 1:
		return true
	return _process_frame_count % after_feedback_interval_frames == 0

func _should_analyze_raw() -> bool:
	if raw_analysis_interval_frames <= 1:
		return true
	return _process_frame_count % raw_analysis_interval_frames == 0

func _can_reuse_runtime_control(_uploaded_sequence_frame: bool) -> bool:
	if not game_budget_mode_enabled:
		return false
	if _last_runtime_metrics.is_empty() or _last_shader_parameters.is_empty():
		return false
	return not _should_analyze_raw()

func _apply_measured_after_metrics(metrics: Dictionary, after_metrics: Dictionary, delta: float) -> void:
	var raw_risk: float = float(metrics["raw_risk"])
	var output_risk: float = float(after_metrics["raw_risk"])
	var risk_reduction: float = max(0.0, raw_risk - output_risk)
	analyzer.apply_after_feedback(output_risk, delta, after_metrics)

	metrics["output_risk"] = output_risk
	metrics["risk_reduction"] = risk_reduction
	metrics["reduction_ratio"] = risk_reduction / max(raw_risk, 0.001)
	metrics["next_mitigation"] = analyzer.mitigation_strength
	metrics["after_general_flash_count"] = after_metrics.get("general_flash_count", 0)
	metrics["after_red_flash_count"] = after_metrics.get("red_flash_count", 0)
	metrics["after_general_flash_area"] = after_metrics.get("general_flash_area", 0.0)
	metrics["after_red_flash_area"] = after_metrics.get("red_flash_area", 0.0)

func _reuse_last_after_metrics(metrics: Dictionary, after_metrics: Dictionary) -> void:
	if after_metrics.is_empty():
		metrics["output_risk"] = float(metrics.get("raw_risk", 0.0))
		metrics["risk_reduction"] = 0.0
		metrics["reduction_ratio"] = 0.0
		return
	var raw_risk: float = float(metrics.get("raw_risk", 0.0))
	var output_risk: float = float(after_metrics.get("raw_risk", 0.0))
	var risk_reduction: float = max(0.0, raw_risk - output_risk)
	metrics["output_risk"] = output_risk
	metrics["risk_reduction"] = risk_reduction
	metrics["reduction_ratio"] = risk_reduction / max(raw_risk, 0.001)
	metrics["after_general_flash_count"] = after_metrics.get("general_flash_count", 0)
	metrics["after_red_flash_count"] = after_metrics.get("red_flash_count", 0)
	metrics["after_general_flash_area"] = after_metrics.get("general_flash_area", 0.0)
	metrics["after_red_flash_area"] = after_metrics.get("red_flash_area", 0.0)
	metrics["after_feedback_reused"] = true

func _update_hud(metrics: Dictionary) -> void:
	if elapsed_seconds + 0.0001 < _next_hud_update_time:
		return
	_next_hud_update_time = elapsed_seconds + (1.0 / HUD_UPDATE_HZ)
	risk_graph.add_sample(elapsed_seconds, metrics)

	for key in metric_bars.keys():
		if not metrics.has(key):
			continue
		var value := float(metrics[key])
		metric_bars[key].value = clamp(value, 0.0, 1.0)
		metric_labels[key].text = "%3d%%" % roundi(value * 100.0)

	var state := "off" if not mitigation_enabled else ("active" if float(metrics["mitigation"]) > 0.01 else "idle")
	var drop_percent := roundi(float(metrics["reduction_ratio"]) * 100.0)
	var display_size := _display_size()
	var analysis_size := _analysis_size_for_display(display_size)
	status_label.text = "%s / %s / %s->%s / local %s / hue %s / solver %s / budget %s div %d raw/%d after/%d / %s / spatial %s / %s / frames %d raw %d after %d / drop %d%% / G %d area %d%% / R %d area %d%% / %s / %s" % [
		state,
		_render_backend_label(),
		"%dx%d" % [display_size.x, display_size.y],
		"%dx%d" % [analysis_size.x, analysis_size.y],
		"on" if local_correction_enabled else "off",
		"raw" if preserve_source_hue else "off",
		"on" if current_frame_solver_enabled else "off",
		"on" if game_budget_mode_enabled else "off",
		analysis_scale_divisor,
		raw_analysis_interval_frames,
		after_feedback_interval_frames,
		_mitigation_mode_label(),
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
	_reset_analysis_state()

func _demo_risk_envelope(cycle_hz: float) -> float:
	var phase: float = sin(elapsed_seconds * TAU * cycle_hz) * 0.5 + 0.5
	return lerpf(0.58, 1.0, smoothstep(0.0, 1.0, phase))

func _sync_analyzer_settings() -> void:
	analyzer.viewing_distance_m = viewing_distance_m
	analyzer.headroom_margin = headroom_margin
	analyzer.mitigation_enabled = mitigation_enabled
	analyzer.mitigation_mode = mitigation_mode
	analyzer.temporal_blend_alpha = temporal_blend_alpha
	analyzer.max_contrast_compression = max_contrast_compression
	analyzer.max_brightness_reduction = max_brightness_reduction
	analyzer.max_feedback_amount = max_feedback_amount
	analyzer.local_correction_enabled = local_correction_enabled
	analyzer.preserve_source_hue = preserve_source_hue
	analyzer.spatial_sensitivity = spatial_sensitivity
	_apply_contribution_settings(analyzer)
	after_analyzer.viewing_distance_m = viewing_distance_m
	after_analyzer.headroom_margin = headroom_margin
	after_analyzer.mitigation_enabled = false
	after_analyzer.mitigation_mode = mitigation_mode
	after_analyzer.temporal_blend_alpha = temporal_blend_alpha
	after_analyzer.max_contrast_compression = max_contrast_compression
	after_analyzer.max_brightness_reduction = max_brightness_reduction
	after_analyzer.max_feedback_amount = max_feedback_amount
	after_analyzer.local_correction_enabled = local_correction_enabled
	after_analyzer.preserve_source_hue = preserve_source_hue
	after_analyzer.spatial_sensitivity = spatial_sensitivity
	_apply_contribution_settings(after_analyzer)
	gpu_analyzer.viewing_distance_m = viewing_distance_m
	gpu_after_analyzer.viewing_distance_m = viewing_distance_m
	current_frame_solver.enabled = current_frame_solver_enabled

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
	_reset_history_state(reset_graph)
	_reset_frame_sequence_playback()

func _reset_history_state(reset_graph: bool = true) -> void:
	analyzer.reset()
	after_analyzer.reset()
	gpu_analyzer.reset()
	gpu_after_analyzer.reset()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.reset_output_history()
	analyzer.set_mitigation_strength(_prewarm_mitigation_for_mode(_current_source_config()))
	_reset_frame_sequence_playback()
	_process_frame_count = 0
	_raw_sample_count = 0
	_after_sample_count = 0
	_next_hud_update_time = 0.0
	_last_frame_sequence_metrics.clear()
	_last_runtime_metrics.clear()
	_last_after_metrics.clear()
	_last_shader_parameters.clear()
	if reset_graph and risk_graph != null:
		risk_graph.reset()

func _register_private_frame_sequences() -> void:
	for source in PRIVATE_FRAME_SEQUENCE_SOURCES:
		var frame_paths := _find_frame_sequence_files(source)
		if frame_paths.is_empty():
			continue
		var config := source.duplicate(true)
		var source_id := String(config.get("id", "frame_sequence_%d" % _mode_configs.size()))
		config["id"] = source_id
		config["frame_count"] = frame_paths.size()
		_frame_sequence_paths[source_id] = frame_paths
		_mode_configs.append(config)

func _find_frame_sequence_files(config: Dictionary) -> Array[String]:
	var frame_dir := String(config.get("frame_dir", ""))
	if frame_dir.is_empty():
		return []
	var global_dir := ProjectSettings.globalize_path(frame_dir)
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

func _current_source_config() -> Dictionary:
	if _mode_configs.is_empty():
		return MODE_CONFIGS[0]
	return _mode_configs[clampi(current_mode, 0, _mode_configs.size() - 1)]

func _is_frame_sequence_source(config: Dictionary) -> bool:
	return String(config.get("source_type", "generated")) == "frame_sequence"

func _load_frame_sequence_image_for_demo(config: Dictionary, delta: float):
	_frame_sequence_frame_changed = false
	var source_id := String(config.get("id", ""))
	var frame_paths: Array = _frame_sequence_paths.get(source_id, [])
	if frame_paths.is_empty():
		return null
	var fps: float = max(1.0, float(config.get("fps", 24.0)))
	if _frame_sequence_active_id != source_id:
		_frame_sequence_active_id = source_id
		_frame_sequence_index = 0
		_frame_sequence_accumulator = 0.0
		_frame_sequence_frame_changed = true
	else:
		_frame_sequence_accumulator += max(delta, 0.0)
		var frame_duration := 1.0 / fps
		if _frame_sequence_accumulator >= frame_duration:
			var advance_count := int(floor(_frame_sequence_accumulator / frame_duration))
			_frame_sequence_index = (_frame_sequence_index + advance_count) % frame_paths.size()
			_frame_sequence_accumulator = fmod(_frame_sequence_accumulator, frame_duration)
			_frame_sequence_frame_changed = advance_count > 0
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

func _reset_frame_sequence_playback() -> void:
	_frame_sequence_active_id = ""
	_frame_sequence_index = 0
	_frame_sequence_accumulator = 0.0
	_frame_sequence_frame_changed = false
	_frame_sequence_pending_analysis_delta = 0.0
	_last_frame_sequence_metrics.clear()

func _measure_after_for_source(source: Dictionary, time_seconds: float, delta: float) -> Dictionary:
	var after_gpu_metrics: Dictionary = gpu_after_analyzer.analyze_texture(gpu_frame_pipeline.analysis_after_texture, time_seconds)
	after_gpu_metrics["source"] = "gpu-after"
	if _is_frame_sequence_source(source):
		after_gpu_metrics["source_kind"] = "frame_sequence"
	if ENABLE_FRAME_SEQUENCE_AFTER_SPATIAL_READBACK and _is_frame_sequence_source(source) and gpu_frame_pipeline.after_texture != null:
		var after_image: Image = gpu_frame_pipeline.after_texture.get_image()
		_apply_cpu_spatial_override(after_gpu_metrics, after_image, after_analyzer)
	return after_analyzer.update_from_metrics(after_gpu_metrics, delta, time_seconds)

func _apply_current_frame_solver_metrics(metrics: Dictionary, solver_result: Dictionary) -> void:
	var solver_info = solver_result.get("solver", {})
	if not (solver_info is Dictionary) or not bool(solver_info.get("active", false)):
		return
	metrics["solver_correction_scale"] = float(solver_info.get("correction_scale", 1.0))
	metrics["solver_identity_after_risk"] = float(solver_info.get("identity_after_risk", 0.0))
	metrics["solver_after_risk"] = float(solver_info.get("after_risk", solver_info.get("upper_after_risk", 0.0)))
	metrics["solver_identity"] = bool(solver_info.get("identity", false))
	metrics["solver_upper_bound_exceeded"] = bool(solver_info.get("upper_bound_exceeded", false))
	metrics["solver_upper_candidate"] = String(solver_info.get("upper_candidate", ""))
	metrics["solver_upper_after_risk"] = float(solver_info.get("upper_after_risk", 0.0))
	metrics["solver_emergency_after_risk"] = float(solver_info.get("emergency_after_risk", -1.0))
	metrics["solver_emergency_hold_after_risk"] = float(solver_info.get("emergency_hold_after_risk", -1.0))
	metrics["solver_emergency_hold_mix"] = float(solver_info.get("emergency_hold_mix", 0.0))

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
		and gpu_after_analyzer.can_analyze_texture(gpu_frame_pipeline.analysis_after_texture)
	)

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
	if _is_frame_sequence_source(source):
		var source_id := String(source.get("id", ""))
		var frame_paths: Array = _frame_sequence_paths.get(source_id, [])
		if not frame_paths.is_empty():
			var image: Image = _load_frame_sequence_path(String(frame_paths[0]))
			if image != null and not image.is_empty():
				return Vector2i(maxi(1, image.get_width()), maxi(1, image.get_height()))
	return _display_size()

func _pipeline_analysis_size_for_source(source: Dictionary, display_size: Vector2i) -> Vector2i:
	if _is_frame_sequence_source(source):
		return display_size
	return _analysis_size_for_display(display_size)

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
	return Vector2i(
		max(1, int(ceil(float(display_size.x) / float(max(1, analysis_scale_divisor))))),
		max(1, int(ceil(float(display_size.y) / float(max(1, analysis_scale_divisor)))))
	)

func _refresh_static_labels() -> void:
	distance_value_label.text = "%.2f m" % viewing_distance_m
	headroom_value_label.text = "%d%%" % roundi(headroom_margin * 100.0)
	temporal_blend_value_label.text = "%d%%" % roundi(temporal_blend_alpha * 100.0)
	brightness_limit_value_label.text = "%d%%" % roundi(max_brightness_reduction * 100.0)
	contrast_limit_value_label.text = "%d%%" % roundi(max_contrast_compression * 100.0)
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

func _on_mitigation_mode_selected(index: int) -> void:
	mitigation_mode = mitigation_mode_select.get_item_id(index)
	_sync_analyzer_settings()
	_reset_analysis_state()

func _on_spatial_sensitivity_selected(index: int) -> void:
	spatial_sensitivity = spatial_sensitivity_select.get_item_id(index)
	_sync_analyzer_settings()
	_reset_analysis_state()

func _on_local_correction_toggled(enabled: bool) -> void:
	local_correction_enabled = enabled
	_sync_analyzer_settings()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.reset_output_history()

func _on_hue_preserve_toggled(enabled: bool) -> void:
	preserve_source_hue = enabled
	_sync_analyzer_settings()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.reset_output_history()

func _on_current_frame_solver_toggled(enabled: bool) -> void:
	current_frame_solver_enabled = enabled
	_sync_analyzer_settings()
	_reset_analysis_state()

func _on_restart_video_pressed() -> void:
	elapsed_seconds = 0.0
	_reset_frame_sequence_playback()
	_reset_history_state()

func _on_clear_history_pressed() -> void:
	_reset_history_state()

func _on_contribution_toggled(enabled: bool, component: String) -> void:
	contribution_enabled[component] = enabled
	_sync_analyzer_settings()
	_reset_analysis_state()

func _on_viewing_distance_changed(value: float) -> void:
	viewing_distance_m = value
	_sync_analyzer_settings()
	_refresh_static_labels()

func _on_temporal_blend_changed(value: float) -> void:
	temporal_blend_alpha = value
	_sync_analyzer_settings()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.reset_output_history()
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

func _mitigation_mode_label() -> String:
	if mitigation_mode == QuellAnalyzerClass.MitigationMode.CURRENT_FRAME_ONLY:
		return "current-frame"
	if mitigation_mode == QuellAnalyzerClass.MitigationMode.TEMPORAL_BLEND:
		return "temporal-blend %d%%" % roundi(temporal_blend_alpha * 100.0)
	return "adaptive"

func _spatial_sensitivity_label() -> String:
	if spatial_sensitivity == QuellAnalyzerClass.SpatialSensitivity.BALANCED:
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
