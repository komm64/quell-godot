extends Control

const RiskGraphClass = preload("res://scripts/quell_risk_graph.gd")

const CORE_ANALYZER_PATH := "res://addons/quell_core/runtime/quell_analyzer.gd"
const CORE_GPU_ANALYZER_PATH := "res://addons/quell_core/runtime/quell_gpu_analyzer.gd"
const CORE_GPU_FRAME_PIPELINE_PATH := "res://addons/quell_core/runtime/quell_gpu_frame_pipeline.gd"

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
	},
]

var elapsed_seconds := 0.0
var current_mode := 0
var mitigation_enabled := true
var correction_mode := 1
var viewing_distance_m := 0.60
var headroom_margin := 0.80

var QuellAnalyzerClass
var GpuAnalyzerClass
var GpuFramePipelineClass
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
var correction_mode_select: OptionButton
var mitigation_toggle: CheckButton
var distance_value_label: Label
var headroom_value_label: Label
var status_label: Label
var risk_graph: Control
var metric_labels: Dictionary = {}
var metric_bars: Dictionary = {}
var _analysis_size := Vector2i(256, 144)
var _process_frame_count: int = 0
var _raw_sample_count: int = 0
var _after_sample_count: int = 0
var _core_available := false

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	get_window().title = "Quell Godot"
	if not _load_core_classes():
		_build_notice("Quell private core is not installed.\nPlace quell-core/engines/godot/addons/quell_core at res://addons/quell_core.")
		return
	analyzer = QuellAnalyzerClass.new()
	after_analyzer = QuellAnalyzerClass.new()
	gpu_analyzer = GpuAnalyzerClass.new()
	gpu_after_analyzer = GpuAnalyzerClass.new()
	gpu_frame_pipeline = GpuFramePipelineClass.new()
	_sync_analyzer_settings()
	_build_visual_layers()
	_build_hud()
	_apply_mode(0)

func _exit_tree() -> void:
	if gpu_analyzer != null:
		gpu_analyzer.dispose()
	if gpu_after_analyzer != null:
		gpu_after_analyzer.dispose()
	if gpu_frame_pipeline != null:
		gpu_frame_pipeline.dispose()

func _process(delta: float) -> void:
	if not _core_available:
		return
	_process_frame_count += 1
	elapsed_seconds += delta
	var source: Dictionary = MODE_CONFIGS[current_mode]
	var envelope: float = _demo_risk_envelope(float(source.get("risk_cycle_hz", 0.10)))
	if content_material != null:
		content_material.set_shader_parameter("time_seconds", elapsed_seconds)
		content_material.set_shader_parameter("risk_envelope", envelope)

	var metrics: Dictionary
	var shader_parameters: Dictionary
	if DisplayServer.get_name() == "headless":
		metrics = analyzer.update_from_generated_source(source, delta, elapsed_seconds)
		metrics["metric_backend"] = "generated"
		shader_parameters = analyzer.shader_parameters(metrics)
	elif _has_gpu_frame_pipeline():
		_ensure_gpu_frame_pipeline_size()
		var source_config := source.duplicate(true)
		source_config["index"] = current_mode
		gpu_frame_pipeline.generate_source(source_config, elapsed_seconds, envelope)
		var raw_gpu_metrics: Dictionary = gpu_analyzer.analyze_texture(gpu_frame_pipeline.analysis_source_texture, elapsed_seconds)
		_raw_sample_count += 1
		metrics = analyzer.update_from_metrics(raw_gpu_metrics, delta, elapsed_seconds)
		metrics["metric_backend"] = "gpu-rd"
		shader_parameters = analyzer.shader_parameters(metrics)
		gpu_frame_pipeline.apply_mitigation(shader_parameters)
		source_display.texture = gpu_frame_pipeline.after_texture
		var after_gpu_metrics: Dictionary = gpu_after_analyzer.analyze_texture(gpu_frame_pipeline.analysis_after_texture, elapsed_seconds)
		_after_sample_count += 1
		var after_metrics: Dictionary = after_analyzer.update_from_metrics(after_gpu_metrics, delta, elapsed_seconds)
		_apply_measured_after_metrics(metrics, after_metrics, delta)
	else:
		metrics = analyzer.update_from_generated_source(source, delta, elapsed_seconds)
		metrics["metric_backend"] = "generated"
		shader_parameters = analyzer.shader_parameters(metrics)
	_apply_shader_parameters(shader_parameters)
	_update_hud(metrics)

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

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.09, 0.105, 0.115, 0.94)
	panel_style.border_color = Color(0.36, 0.43, 0.46, 0.85)
	panel_style.border_width_left = 1
	panel_style.border_width_top = 1
	panel_style.border_width_right = 1
	panel_style.border_width_bottom = 1
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	panel.add_theme_stylebox_override("panel", panel_style)

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

	_build_notice("RenderingDevice backend is unavailable.\nMetrics can still update, but the GPU demo surface is disabled.")

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

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 10)
	margin.add_child(stack)

	var title := Label.new()
	title.text = "Quell / Godot prototype"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.92, 0.96, 0.98))
	stack.add_child(title)

	mode_select = OptionButton.new()
	for config in MODE_CONFIGS:
		mode_select.add_item(config["name"])
	mode_select.item_selected.connect(_on_mode_selected)
	stack.add_child(_with_caption("Source", mode_select))

	mitigation_toggle = CheckButton.new()
	mitigation_toggle.text = "Mitigation"
	mitigation_toggle.button_pressed = mitigation_enabled
	mitigation_toggle.toggled.connect(_on_mitigation_toggled)
	stack.add_child(mitigation_toggle)

	correction_mode_select = OptionButton.new()
	correction_mode_select.add_item("Current frame only")
	correction_mode_select.add_item("Temporal blend")
	correction_mode_select.selected = correction_mode
	correction_mode_select.item_selected.connect(_on_correction_mode_selected)
	stack.add_child(_with_caption("Correction", correction_mode_select))

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

	_add_metric_row(stack, "luminance", "Luminance")
	_add_metric_row(stack, "red", "Red")
	_add_metric_row(stack, "spatial", "Spatial")
	_add_metric_row(stack, "trend", "Trend")
	_add_metric_row(stack, "raw_risk", "Raw risk")
	_add_metric_row(stack, "output_risk", "After")
	_add_metric_row(stack, "reduction_ratio", "Drop")
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

func _apply_shader_parameters(parameters: Dictionary) -> void:
	if post_material == null:
		return
	for key in parameters.keys():
		post_material.set_shader_parameter(StringName(key), parameters[key])

func _apply_measured_after_metrics(metrics: Dictionary, after_metrics: Dictionary, delta: float) -> void:
	analyzer.combine_after_metrics(metrics, after_metrics, delta)
	metrics["next_mitigation"] = analyzer.mitigation_strength

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
	status_label.text = "%s / %s / %s / frames %d raw %d after %d / drop %d%% / G %d area %d%% / R %d area %d%%" % [
		state,
		_correction_mode_name(),
		String(metrics.get("metric_backend", "generated")),
		_process_frame_count,
		_raw_sample_count,
		_after_sample_count,
		drop_percent,
		int(metrics.get("general_flash_count", 0)),
		roundi(float(metrics.get("general_flash_area", 0.0)) * 100.0),
		int(metrics.get("red_flash_count", 0)),
		roundi(float(metrics.get("red_flash_area", 0.0)) * 100.0),
	]

func _apply_mode(index: int) -> void:
	current_mode = clampi(index, 0, MODE_CONFIGS.size() - 1)
	var config := MODE_CONFIGS[current_mode]
	if content_material != null:
		content_material.set_shader_parameter("mode", current_mode)
		content_material.set_shader_parameter("flash_hz", float(config["flash_hz"]))
		content_material.set_shader_parameter("red_hz", float(config["red_hz"]))
		content_material.set_shader_parameter("stripe_cycles", float(config["stripe_cycles"]))
		content_material.set_shader_parameter("unsafe_area", float(config["unsafe_area"]))
	_reset_runtime_state()

func _reset_runtime_state() -> void:
	if analyzer == null:
		return
	analyzer.reset()
	after_analyzer.reset()
	gpu_analyzer.reset()
	gpu_after_analyzer.reset()
	analyzer.set_mitigation_strength(_prewarm_mitigation_for_mode(MODE_CONFIGS[current_mode]) if mitigation_enabled else 0.0)
	_process_frame_count = 0
	_raw_sample_count = 0
	_after_sample_count = 0
	if risk_graph != null:
		risk_graph.reset()

func _demo_risk_envelope(cycle_hz: float) -> float:
	var phase: float = sin(elapsed_seconds * TAU * cycle_hz) * 0.5 + 0.5
	return lerpf(0.58, 1.0, smoothstep(0.0, 1.0, phase))

func _sync_analyzer_settings() -> void:
	analyzer.viewing_distance_m = viewing_distance_m
	analyzer.headroom_margin = headroom_margin
	analyzer.mitigation_enabled = mitigation_enabled
	if analyzer.has_method("set_correction_mode"):
		analyzer.set_correction_mode(correction_mode)
	else:
		analyzer.correction_mode = correction_mode
	after_analyzer.viewing_distance_m = viewing_distance_m
	after_analyzer.headroom_margin = headroom_margin
	after_analyzer.mitigation_enabled = false
	if after_analyzer.has_method("set_correction_mode"):
		after_analyzer.set_correction_mode(correction_mode)
	else:
		after_analyzer.correction_mode = correction_mode
	gpu_analyzer.viewing_distance_m = viewing_distance_m
	gpu_after_analyzer.viewing_distance_m = viewing_distance_m

func _prewarm_mitigation_for_mode(config: Dictionary) -> float:
	return analyzer.required_mitigation_for_risk(_estimate_mode_risk(config))

func _estimate_mode_risk(config: Dictionary) -> float:
	var area_risk: float = analyzer.visual_area_risk(float(config.get("unsafe_area", 0.0)))
	var luminance: float = area_risk * float(config.get("flash_amplitude", 0.0)) * analyzer.frequency_gate(float(config.get("flash_hz", 0.0)))
	var red: float = area_risk * float(config.get("red_amplitude", 0.0)) * analyzer.frequency_gate(float(config.get("red_hz", 0.0)))
	var stripe_cycles: float = float(config.get("stripe_cycles", 0.0))
	var spatial: float = float(config.get("spatial_contrast", 0.0)) * clamp((stripe_cycles - 2.0) / 1.2, 0.0, 1.25)
	return clamp(max(luminance, max(red, spatial)), 0.0, 1.35)

func _estimate_mode_temporal_contrast(config: Dictionary) -> float:
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
		_reset_runtime_state()

func _display_size() -> Vector2i:
	var viewport_size: Vector2 = get_viewport_rect().size
	return Vector2i(max(1, roundi(viewport_size.x)), max(1, roundi(viewport_size.y)))

func _refresh_static_labels() -> void:
	distance_value_label.text = "%.2f m" % viewing_distance_m
	headroom_value_label.text = "%d%%" % roundi(headroom_margin * 100.0)
	if correction_mode_select != null:
		correction_mode_select.selected = correction_mode
	if risk_graph != null:
		risk_graph.headroom_margin = headroom_margin
		risk_graph.queue_redraw()

func _correction_mode_name() -> String:
	return "current" if correction_mode == 0 else "temporal"

func _on_mode_selected(index: int) -> void:
	_apply_mode(index)

func _on_mitigation_toggled(enabled: bool) -> void:
	mitigation_enabled = enabled
	_sync_analyzer_settings()
	_reset_runtime_state()

func _on_correction_mode_selected(index: int) -> void:
	correction_mode = clampi(index, 0, 1)
	_sync_analyzer_settings()
	_reset_runtime_state()
	_refresh_static_labels()

func _on_viewing_distance_changed(value: float) -> void:
	viewing_distance_m = value
	_sync_analyzer_settings()
	_refresh_static_labels()

func _on_headroom_changed(value: float) -> void:
	headroom_margin = value
	_sync_analyzer_settings()
	_refresh_static_labels()
