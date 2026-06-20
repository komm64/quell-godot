extends Control

# Public wrapper discovers the proprietary core at runtime so the demo degrades
# gracefully (notice instead of crash) when addons/quell_core is absent.
const CORE_ANALYZER_PATH := "res://addons/quell_core/runtime/quell_analyzer.gd"
const CORE_GPU_ANALYZER_PATH := "res://addons/quell_core/runtime/quell_gpu_analyzer.gd"
const CORE_GPU_FRAME_PIPELINE_PATH := "res://addons/quell_core/runtime/quell_gpu_frame_pipeline.gd"
const RiskGraphClass = preload("res://scripts/quell_risk_graph.gd")

var QuellAnalyzerClass
var GpuAnalyzerClass
var GpuFramePipelineClass
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
var elapsed_seconds := 0.0
var current_mode := 0
var mitigation_enabled := true
# mitigation_mode / spatial_sensitivity hold core enum ints; real defaults are
# assigned in _ready() once the core classes are loaded.
var mitigation_mode := 0
var temporal_blend_alpha := 0.50
var max_contrast_compression := 0.65
var max_brightness_reduction := 0.50
var max_feedback_amount := 0.60
var local_correction_enabled := false
var spatial_sensitivity := 0
var viewing_distance_m := 0.60
var headroom_margin := 0.80
var contribution_enabled: Dictionary = {}

var analyzer
var after_analyzer
var gpu_analyzer
var gpu_after_analyzer
var gpu_frame_pipeline
var source_viewport: SubViewport
var source_display: TextureRect
var content_material: ShaderMaterial
var post_material: ShaderMaterial
var mode_select: OptionButton
var mitigation_mode_select: OptionButton
var spatial_sensitivity_select: OptionButton
var mitigation_toggle: CheckButton
var local_correction_toggle: CheckButton
var distance_value_label: Label
var headroom_value_label: Label
var temporal_blend_value_label: Label
var contrast_limit_slider: HSlider
var contrast_limit_value_label: Label
var brightness_limit_slider: HSlider
var brightness_limit_value_label: Label
var feedback_limit_slider: HSlider
var feedback_limit_value_label: Label
var status_label: Label
var risk_graph: Control
var metric_labels: Dictionary = {}
var metric_bars: Dictionary = {}
var contribution_toggles: Dictionary = {}
var _analysis_size := Vector2i(256, 144)
var _process_frame_count: int = 0
var _raw_sample_count: int = 0
var _after_sample_count: int = 0
var _comparator_cases: Dictionary = {}
var _mode_configs: Array[Dictionary] = []
var _frame_sequence_paths: Dictionary = {}
var _frame_cache: Dictionary = {}
var _frame_cache_order: Array[String] = []

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	get_window().title = "Quell Godot Prototype"
	if not _load_core_classes():
		_build_notice("Quell private core is not installed.\nPlace quell-core/engines/godot/addons/quell_core at res://addons/quell_core.")
		return
	analyzer = QuellAnalyzerClass.new()
	after_analyzer = QuellAnalyzerClass.new()
	gpu_analyzer = GpuAnalyzerClass.new()
	gpu_after_analyzer = GpuAnalyzerClass.new()
	gpu_frame_pipeline = GpuFramePipelineClass.new()
	mitigation_mode = QuellAnalyzerClass.MitigationMode.ADAPTIVE
	spatial_sensitivity = QuellAnalyzerClass.SpatialSensitivity.BALANCED
	contribution_enabled = _default_contribution_enabled()
	_mode_configs = MODE_CONFIGS.duplicate(true)
	_register_private_frame_sequences()
	_load_comparator_baselines()
	_sync_analyzer_settings()
	_build_visual_layers()
	_build_hud()
	_apply_mode(0)
	_start_k64_io()

func _load_core_classes() -> bool:
	for path in [CORE_ANALYZER_PATH, CORE_GPU_ANALYZER_PATH, CORE_GPU_FRAME_PIPELINE_PATH]:
		if not ResourceLoader.exists(path):
			return false
	QuellAnalyzerClass = load(CORE_ANALYZER_PATH)
	GpuAnalyzerClass = load(CORE_GPU_ANALYZER_PATH)
	GpuFramePipelineClass = load(CORE_GPU_FRAME_PIPELINE_PATH)
	_core_available = QuellAnalyzerClass != null and GpuAnalyzerClass != null and GpuFramePipelineClass != null
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

func _start_k64_io() -> void:
	if not OS.is_debug_build():
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
			{"name": "spatial_sensitivity", "type": "int", "doc": "QuellAnalyzer.SpatialSensitivity enum value"},
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

func _provide_k64_status() -> Dictionary:
	var source := _current_source_config()
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
		"spatial_sensitivity": int(spatial_sensitivity),
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
	_process_frame_count += 1
	elapsed_seconds += delta
	var source: Dictionary = _current_source_config()
	var envelope: float = _demo_risk_envelope(float(source.get("risk_cycle_hz", 0.10)))
	if content_material != null:
		content_material.set_shader_parameter("time_seconds", elapsed_seconds)
		content_material.set_shader_parameter("risk_envelope", envelope)

	var metrics: Dictionary
	var shader_parameters: Dictionary
	if DisplayServer.get_name() == "headless":
		if _is_frame_sequence_source(source):
			var headless_sequence_image = _load_frame_sequence_image(source, elapsed_seconds)
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
	elif _has_gpu_frame_pipeline():
		_ensure_gpu_frame_pipeline_size()
		var uploaded_sequence_frame := false
		var gpu_sequence_image = null
		if _is_frame_sequence_source(source):
			gpu_sequence_image = _load_frame_sequence_image(source, elapsed_seconds)
			if gpu_sequence_image != null:
				uploaded_sequence_frame = gpu_frame_pipeline.upload_source_image(gpu_sequence_image, true)
		if not uploaded_sequence_frame:
			var source_config := source.duplicate(true)
			source_config["index"] = current_mode
			gpu_frame_pipeline.generate_source(source_config, elapsed_seconds, envelope)
		_raw_sample_count += 1
		var raw_gpu_metrics: Dictionary = gpu_analyzer.analyze_texture(gpu_frame_pipeline.analysis_source_texture, elapsed_seconds)
		if not uploaded_sequence_frame:
			raw_gpu_metrics["source_kind"] = "generated"
			var estimated_temporal_contrast := _estimate_mode_temporal_contrast(source)
			raw_gpu_metrics["luminance_contrast"] = max(float(raw_gpu_metrics.get("luminance_contrast", 0.0)), estimated_temporal_contrast)
			if estimated_temporal_contrast > 0.001:
				raw_gpu_metrics["general_flash_area"] = max(float(raw_gpu_metrics.get("general_flash_area", 0.0)), float(source.get("unsafe_area", 1.0)))
		else:
			raw_gpu_metrics["source_kind"] = "frame_sequence"
			_apply_cpu_spatial_override(raw_gpu_metrics, gpu_sequence_image, analyzer)
		metrics = analyzer.update_from_metrics(raw_gpu_metrics, delta, elapsed_seconds)
		metrics["metric_backend"] = "gpu-frame-seq" if uploaded_sequence_frame else "gpu-rd"
		shader_parameters = analyzer.shader_parameters(metrics)
		_apply_shader_parameter_metrics(metrics, shader_parameters)
		gpu_frame_pipeline.apply_mitigation(shader_parameters)
		source_display.texture = gpu_frame_pipeline.after_texture
		_after_sample_count += 1
		var after_metrics: Dictionary = metrics.duplicate(true) if not mitigation_enabled else _measure_after_for_source(source, elapsed_seconds, delta)
		_apply_measured_after_metrics(metrics, after_metrics, delta)
	else:
		metrics = analyzer.update_from_generated_source(source, delta, elapsed_seconds)
		metrics["metric_backend"] = "generated"
		shader_parameters = analyzer.shader_parameters(metrics)
		_apply_shader_parameter_metrics(metrics, shader_parameters)
	_apply_shader_parameters(shader_parameters)
	_update_hud(metrics)

func _build_visual_layers() -> void:
	if gpu_frame_pipeline != null and gpu_analyzer.is_ready() and gpu_after_analyzer.is_ready() and gpu_frame_pipeline.configure(_display_size(), _analysis_size):
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
	source_viewport.size = _analysis_size
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

	var post_layer := CanvasLayer.new()
	post_layer.name = "QuellPostProcess"
	post_layer.layer = 10
	add_child(post_layer)

	var post_rect := ColorRect.new()
	post_rect.name = "Mitigator"
	post_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	post_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	post_layer.add_child(post_rect)

	# quell_mitigator.gdshader is proprietary mitigation policy (kept out of the
	# public repo via .gitignore). Degrade to unmitigated Raw display if absent.
	var mitigator_path := "res://shaders/quell_mitigator.gdshader"
	if ResourceLoader.exists(mitigator_path):
		post_material = ShaderMaterial.new()
		post_material.shader = load(mitigator_path)
		post_rect.material = post_material

func _build_hud() -> void:
	var hud_layer := CanvasLayer.new()
	hud_layer.name = "HUD"
	hud_layer.layer = 20
	add_child(hud_layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(16.0, 16.0)
	panel.custom_minimum_size = Vector2(430.0, 0.0)
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
	local_correction_toggle.text = "Local current"
	local_correction_toggle.button_pressed = local_correction_enabled
	local_correction_toggle.toggled.connect(_on_local_correction_toggled)
	stack.add_child(local_correction_toggle)

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

	risk_graph = RiskGraphClass.new()
	risk_graph.headroom_margin = headroom_margin
	stack.add_child(risk_graph)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Color(0.70, 0.78, 0.82))
	stack.add_child(status_label)

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

func _apply_shader_parameters(parameters: Dictionary) -> void:
	if post_material == null:
		return
	for key in parameters.keys():
		post_material.set_shader_parameter(StringName(key), parameters[key])

func _apply_shader_parameter_metrics(metrics: Dictionary, parameters: Dictionary) -> void:
	metrics["controller_mitigation"] = float(metrics.get("mitigation", 0.0))
	metrics["mitigation"] = float(parameters.get("mitigation_strength", metrics.get("mitigation", 0.0)))
	metrics["temporal_hold"] = 1.0 if float(parameters.get("luminance_delta_limit", 1.0)) <= 0.000001 else 0.0
	metrics["brightness_control"] = float(parameters.get("brightness_reduction", 0.0))
	metrics["contrast_control"] = 1.0 - float(parameters.get("contrast_scale_limit", 1.0))
	metrics["feedback_control"] = 1.0 - float(parameters.get("temporal_blend_alpha", 1.0))
	metrics["local_correction"] = float(parameters.get("local_correction_strength", 0.0))

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

func _update_hud(metrics: Dictionary) -> void:
	risk_graph.add_sample(elapsed_seconds, metrics)

	for key in metric_bars.keys():
		if not metrics.has(key):
			continue
		var value := float(metrics[key])
		metric_bars[key].value = clamp(value, 0.0, 1.0)
		metric_labels[key].text = "%3d%%" % roundi(value * 100.0)

	var state := "off" if not mitigation_enabled else ("active" if float(metrics["mitigation"]) > 0.01 else "idle")
	var drop_percent := roundi(float(metrics["reduction_ratio"]) * 100.0)
	status_label.text = "%s / %s / spatial %s / %s / frames %d raw %d after %d / drop %d%% / G %d area %d%% / R %d area %d%% / %s / %s" % [
		state,
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
		content_material.set_shader_parameter("mode", current_mode)
		content_material.set_shader_parameter("flash_hz", float(config["flash_hz"]))
		content_material.set_shader_parameter("red_hz", float(config["red_hz"]))
		content_material.set_shader_parameter("stripe_cycles", float(config["stripe_cycles"]))
		content_material.set_shader_parameter("unsafe_area", float(config["unsafe_area"]))
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
	after_analyzer.spatial_sensitivity = spatial_sensitivity
	_apply_contribution_settings(after_analyzer)
	gpu_analyzer.viewing_distance_m = viewing_distance_m
	gpu_after_analyzer.viewing_distance_m = viewing_distance_m

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
	analyzer.reset()
	after_analyzer.reset()
	gpu_analyzer.reset()
	gpu_after_analyzer.reset()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.reset_output_history()
	analyzer.set_mitigation_strength(_prewarm_mitigation_for_mode(_current_source_config()))
	_process_frame_count = 0
	_raw_sample_count = 0
	_after_sample_count = 0
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

func _load_frame_sequence_image(config: Dictionary, time_seconds: float):
	var source_id := String(config.get("id", ""))
	var frame_paths: Array = _frame_sequence_paths.get(source_id, [])
	if frame_paths.is_empty():
		return null
	var fps: float = max(1.0, float(config.get("fps", 24.0)))
	var frame_index: int = int(floor(time_seconds * fps)) % frame_paths.size()
	var frame_path := String(frame_paths[frame_index])
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

func _measure_after_for_source(source: Dictionary, time_seconds: float, delta: float) -> Dictionary:
	var after_gpu_metrics: Dictionary = gpu_after_analyzer.analyze_texture(gpu_frame_pipeline.analysis_after_texture, time_seconds)
	after_gpu_metrics["source"] = "gpu-after"
	if _is_frame_sequence_source(source) and gpu_frame_pipeline.analysis_after_texture != null:
		var after_image: Image = gpu_frame_pipeline.analysis_after_texture.get_image()
		_apply_cpu_spatial_override(after_gpu_metrics, after_image, after_analyzer)
	return after_analyzer.update_from_metrics(after_gpu_metrics, delta, time_seconds)

func _apply_cpu_spatial_override(metrics: Dictionary, image: Image, spatial_analyzer) -> void:
	if image == null or image.is_empty() or spatial_analyzer == null:
		return
	var spatial_metrics: Dictionary = spatial_analyzer.analyze_spatial_image(image)
	metrics["spatial"] = clamp(float(spatial_metrics.get("risk", 0.0)), 0.0, 1.35)
	metrics["spatial_pattern_area"] = float(spatial_metrics.get("area", 0.0))
	metrics["spatial_pattern_pairs"] = float(spatial_metrics.get("pairs", 0.0))
	metrics["spatial_pattern_regularity"] = float(spatial_metrics.get("regularity", 0.0))
	metrics["spatial_backend"] = "cpu-regularity"

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
		and gpu_frame_pipeline.analysis_after_texture != null
		and gpu_analyzer.can_analyze_texture(gpu_frame_pipeline.analysis_source_texture)
		and gpu_after_analyzer.can_analyze_texture(gpu_frame_pipeline.analysis_after_texture)
	)

func _ensure_gpu_frame_pipeline_size() -> void:
	if gpu_frame_pipeline == null:
		return
	var display_size := _display_size()
	if gpu_frame_pipeline.get_display_size() == display_size and gpu_frame_pipeline.get_analysis_size() == _analysis_size:
		return
	if gpu_frame_pipeline.configure(display_size, _analysis_size):
		source_display.texture = gpu_frame_pipeline.after_texture
		_reset_analysis_state(false)

func _display_size() -> Vector2i:
	var viewport_size: Vector2 = get_viewport_rect().size
	return Vector2i(max(1, roundi(viewport_size.x)), max(1, roundi(viewport_size.y)))

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
