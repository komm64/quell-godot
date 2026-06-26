extends SceneTree

const RuntimeAnalyzerClass = preload("res://addons/quell_core/runtime/quell_analyzer.gd")
const GpuAnalyzerClass = preload("res://addons/quell_core/runtime/quell_gpu_analyzer.gd")
const FramePipelineClass = preload("res://addons/quell_core/runtime/quell_gpu_frame_pipeline.gd")
const CurrentFrameSolverClass = preload("res://addons/quell_core/runtime/quell_current_frame_solver.gd")

const CSV_HEADER := "Frame,TimeSeconds,QuellLuminance,QuellRed,QuellSpatial,QuellRawRisk,GeneralFlashCount,RedFlashCount,GeneralFlashArea,RedFlashArea,RedSaturationArea,FrameLuminanceContrast,TemporalLuminanceContrast"
const CONTROL_CSV_HEADER := "Frame,TimeSeconds,SourceFrame,RawRisk,AfterRisk,ControlRisk,RawSourceControlRisk,TemporalRawAfterActivity,TemporalAfterPressure,AnalyzerStrength,ShaderStrength,MitigationMode,RedSuppression,ContrastReduction,BlurStrength,LuminanceDeltaLimit,ContrastScaleLimit,SpatialContrastLimit,TemporalBlendAlpha,MitigationEnabledSignal,CorrectionMixAlpha,TemporalProjectionStrength,SolverCorrectionScale,SolverIdentityAfterRisk,SolverAfterRisk,EffectiveBrightness,EffectiveContrast,EffectiveFeedback,RawGeneralFlashCount,AfterGeneralFlashCount,RawRedFlashCount,AfterRedFlashCount,RawGeneralFlashArea,AfterGeneralFlashArea,RawRedFlashArea,AfterRedFlashArea,GameBudgetControlRisk,GameBudgetRawAfterActivity,GameBudgetHighAreaPressure,GameBudgetOutputHistoryPressure,GameBudgetLuminanceEventPressure,GameBudgetAfterHistoryHold,GameBudgetAfterHistoryPressure,GameBudgetBurstHold,GameBudgetFlashImpulse,GameBudgetFlashDebt,GameBudgetFlashDebtState,GameBudgetTargetPressure,GameBudgetReleaseSlowdown,GameBudgetReleaseRate"
const DEFAULT_INPUT_DIR := "res://validation/private/demo-videos/pokemon-shock/frames"
const DEFAULT_OUTPUT_DIR := "res://validation/private/mitigation/pokemon-shock-quell-after"
const DEFAULT_SOURCE_FPS := 1199.0 / 50.0
const DEFAULT_OUTPUT_FPS := 30.0
const DEFAULT_DISPLAY_SIZE := Vector2i(1280, 720)
const DEFAULT_ANALYSIS_SIZE := Vector2i(256, 144)
const DEFAULT_TARGET_RISK := 0.80
const GAME_BUDGET_ANALYSIS_SCALE_DIVISOR: int = 8
const GAME_BUDGET_RAW_SAMPLE_INTERVAL_FRAMES: int = 2
const GAME_BUDGET_AFTER_SAMPLE_INTERVAL_FRAMES: int = 6
const TEMPORAL_VISUAL_CONTROL_GAIN := 1.36
const CURRENT_VISUAL_CONTROL_GAIN := 1.10

var _input_dir := DEFAULT_INPUT_DIR
var _output_dir := DEFAULT_OUTPUT_DIR
var _source_fps := DEFAULT_SOURCE_FPS
var _output_fps := DEFAULT_OUTPUT_FPS
var _display_size := DEFAULT_DISPLAY_SIZE
var _analysis_size := DEFAULT_ANALYSIS_SIZE
var _mitigation_mode: int = RuntimeAnalyzerClass.MitigationMode.CURRENT_FRAME_ONLY
var _temporal_blend_alpha: float = 0.50
var _current_frame_solver_enabled := false
var _analytic_solver_enabled := false
var _game_budget_enabled := false
var _game_budget_skip_raw_risk := false
var _game_budget_policy: int = RuntimeAnalyzerClass.GameBudgetPolicy.ADAPTIVE_TEMPORAL_FILTER
var _raw_spatial_override_enabled := true
var _after_spatial_override_enabled := true
var _solver_preview_spatial_readback_enabled := true
var _match_source_size := false
var _live_cadence := false
var _max_seconds := 0.0
var _max_frames := 0
var _failed := false
var _rd: RenderingDevice

func _init() -> void:
	_parse_args()
	if DisplayServer.get_name() == "headless":
		push_error("GPU mitigation export requires a RenderingDevice renderer")
		quit(1)
		return

	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("RenderingDevice is unavailable")
		quit(1)
		return

	var input_abs := _globalize_path(_input_dir)
	var output_abs := _globalize_path(_output_dir)
	var raw_dir := output_abs.path_join("raw")
	var after_dir := output_abs.path_join("after")
	_make_dir(raw_dir)
	_make_dir(after_dir)
	if _failed:
		quit(1)
		return
	_clean_frame_dir(raw_dir)
	_clean_frame_dir(after_dir)
	_remove_file(output_abs.path_join("control_metrics.csv"))
	_remove_file(output_abs.path_join("manifest.json"))

	var frame_paths := _frame_paths(input_abs)
	if frame_paths.is_empty():
		push_error("No input frame_*.png files found: %s" % input_abs)
		quit(1)
		return
	if _match_source_size:
		var first_image := _load_image(String(frame_paths[0]))
		if first_image == null:
			_failed = true
			quit(1)
			return
		_display_size = Vector2i(first_image.get_width(), first_image.get_height())
		_analysis_size = _analysis_size_for_display(_display_size) if _game_budget_enabled else _display_size

	var manifest := _export_frames(frame_paths, raw_dir, after_dir, output_abs)
	_write_json(output_abs.path_join("manifest.json"), manifest)
	print(JSON.stringify(manifest, "\t"))
	quit(1 if _failed else 0)

func _export_frames(frame_paths: PackedStringArray, raw_dir: String, after_dir: String, output_abs: String) -> Dictionary:
	var duration: float = float(frame_paths.size()) / max(1.0, _source_fps)
	if _max_seconds > 0.0:
		duration = min(duration, _max_seconds)
	var output_frames := maxi(1, int(floor(duration * _output_fps)))
	if _max_frames > 0:
		output_frames = mini(output_frames, _max_frames)

	var pipeline = FramePipelineClass.new()
	var raw_gpu = GpuAnalyzerClass.new()
	var solver_after_gpu = GpuAnalyzerClass.new()
	var analyzer = RuntimeAnalyzerClass.new()
	var solver_after_analyzer = RuntimeAnalyzerClass.new()
	var current_frame_solver = CurrentFrameSolverClass.new()
	current_frame_solver.enabled = _current_frame_solver_enabled
	if _object_has_property(current_frame_solver, "analytic_enabled"):
		current_frame_solver.analytic_enabled = _analytic_solver_enabled
	if _object_has_property(current_frame_solver, "game_budget_enabled"):
		current_frame_solver.game_budget_enabled = _game_budget_enabled
	if _object_has_property(current_frame_solver, "fast_identity_enabled"):
		current_frame_solver.fast_identity_enabled = _game_budget_enabled
	analyzer.headroom_margin = DEFAULT_TARGET_RISK
	analyzer.local_correction_enabled = true
	analyzer.mitigation_mode = _mitigation_mode
	analyzer.temporal_blend_alpha = _temporal_blend_alpha
	analyzer.spatial_sensitivity = RuntimeAnalyzerClass.SpatialSensitivity.BALANCED
	if _object_has_property(analyzer, "game_budget_policy"):
		analyzer.game_budget_policy = _game_budget_policy
	_configure_after_measurement_analyzer(solver_after_analyzer)

	if not pipeline.configure(_display_size, _analysis_size):
		push_error("Failed to configure GPU mitigation pipeline")
		_failed = true
		return {}
	if not raw_gpu.is_ready() or not solver_after_gpu.is_ready():
		push_error("Failed to initialize GPU analyzers")
		_failed = true
		return {}

	var raw_csv_path := raw_dir.path_join("quell_metrics.csv")
	var after_csv_path := after_dir.path_join("quell_metrics.csv")
	var control_csv_path := output_abs.path_join("control_metrics.csv")
	var raw_csv := FileAccess.open(raw_csv_path, FileAccess.WRITE)
	var control_csv := FileAccess.open(control_csv_path, FileAccess.WRITE)
	if raw_csv == null or control_csv == null:
		push_error("Failed to open metrics CSV outputs")
		_failed = true
		return {}
	raw_csv.store_line(CSV_HEADER)
	control_csv.store_line(CONTROL_CSV_HEADER)

	var max_raw_risk := 0.0
	var max_after_risk := 0.0
	var max_after_luminance := 0.0
	var max_after_red := 0.0
	var max_after_spatial := 0.0
	var after_over_target_frames := 0
	var analyzed_frames := 0
	var sequence_index := 0
	var sequence_accumulator := 0.0
	var pending_analysis_delta := 0.0
	var has_live_sample := false
	var last_runtime_metrics: Dictionary = {}
	var last_shader_parameters: Dictionary = {}
	var last_measured_after: Dictionary = {}
	var last_source_index := -1
	var last_raw_sample_frame: int = -999999
	var last_after_sample_frame: int = -999999

	for out_index in range(output_frames):
		var time_seconds := float(out_index) / _output_fps
		var source_index := clampi(int(floor(time_seconds * _source_fps)), 0, frame_paths.size() - 1)
		var analysis_delta := 1.0 / _output_fps
		if _live_cadence:
			pending_analysis_delta += analysis_delta
			var frame_changed := false
			if not has_live_sample:
				frame_changed = true
				has_live_sample = true
			else:
				sequence_accumulator += analysis_delta
				var frame_duration := 1.0 / _source_fps
				if sequence_accumulator >= frame_duration:
					var advance_count := int(floor(sequence_accumulator / frame_duration))
					sequence_index = (sequence_index + advance_count) % frame_paths.size()
					sequence_accumulator = fmod(sequence_accumulator, frame_duration)
					frame_changed = advance_count > 0
			if not frame_changed:
				var held_raw_frame_path := raw_dir.path_join("frame_%06d.png" % [out_index + 1])
				var held_after_frame_path := after_dir.path_join("frame_%06d.png" % [out_index + 1])
				var held_source: Image = _read_texture_image(pipeline.source_texture)
				var held_after: Image = _read_texture_image(pipeline.after_texture)
				if held_source != null:
					_save_png(held_source, held_raw_frame_path)
				if held_after != null:
					_save_png(held_after, held_after_frame_path)
				if not last_runtime_metrics.is_empty() and held_after != null:
					var held_metrics := last_runtime_metrics.duplicate(true)
					var held_after_metrics: Dictionary
					if _should_measure_game_budget_after(out_index, last_after_sample_frame, last_measured_after, held_metrics):
						held_after_metrics = _measure_visible_after_frame(
							solver_after_gpu,
							solver_after_analyzer,
							pipeline.after_texture,
							held_after,
							analysis_delta,
							time_seconds,
							_after_spatial_override_enabled
						)
						last_measured_after = held_after_metrics.duplicate(true)
						last_after_sample_frame = out_index
					else:
						held_after_metrics = _held_game_budget_after_metrics(last_measured_after, held_metrics, time_seconds)
					analyzer.apply_after_feedback(float(held_after_metrics.get("raw_risk", 0.0)), analysis_delta, held_after_metrics)
					max_after_risk = max(max_after_risk, float(held_after_metrics.get("raw_risk", 0.0)))
					max_after_luminance = max(max_after_luminance, float(held_after_metrics.get("luminance", 0.0)))
					max_after_red = max(max_after_red, float(held_after_metrics.get("red", 0.0)))
					max_after_spatial = max(max_after_spatial, float(held_after_metrics.get("spatial", 0.0)))
					if float(held_after_metrics.get("raw_risk", 0.0)) > DEFAULT_TARGET_RISK:
						after_over_target_frames += 1
					raw_csv.store_line(_metrics_csv_row(out_index + 1, time_seconds, held_metrics))
					control_csv.store_line(_control_csv_row(out_index + 1, time_seconds, sequence_index + 1, held_metrics, held_after_metrics, analyzer.mitigation_strength, last_shader_parameters))
				continue
			source_index = sequence_index
			analysis_delta = max(pending_analysis_delta, analysis_delta)
			pending_analysis_delta = 0.0
		var source_image: Image = _load_image(String(frame_paths[source_index]))
		if source_image == null:
			_failed = true
			continue

		if not pipeline.upload_source_image(source_image, true):
			push_error("Failed to upload source frame %d" % source_index)
			_failed = true
			continue
		var source_changed := source_index != last_source_index
		if _game_budget_enabled and not source_changed and not last_runtime_metrics.is_empty() and not last_shader_parameters.is_empty() and out_index - last_raw_sample_frame < GAME_BUDGET_RAW_SAMPLE_INTERVAL_FRAMES:
			var held_runtime_metrics := last_runtime_metrics.duplicate(true)
			held_runtime_metrics["time"] = time_seconds
			held_runtime_metrics["metric_backend"] = "gpu-game-budget-raw-held"
			var held_shader_parameters := last_shader_parameters.duplicate(true)
			pipeline.apply_mitigation(held_shader_parameters)
			var held_output_image: Image = _read_texture_image(pipeline.after_texture)
			if held_output_image == null:
				_failed = true
				continue
			var held_raw_path := raw_dir.path_join("frame_%06d.png" % [out_index + 1])
			var held_after_path := after_dir.path_join("frame_%06d.png" % [out_index + 1])
			_save_png(_read_texture_image(pipeline.source_texture), held_raw_path)
			if not _save_png(held_output_image, held_after_path):
				continue
			var held_measured_after: Dictionary
			if _should_measure_game_budget_after(out_index, last_after_sample_frame, last_measured_after, held_runtime_metrics):
				held_measured_after = _measure_visible_after_frame(
					solver_after_gpu,
					solver_after_analyzer,
					pipeline.after_texture,
					held_output_image,
					1.0 / _output_fps,
					time_seconds,
					_after_spatial_override_enabled
				)
				last_measured_after = held_measured_after.duplicate(true)
				last_after_sample_frame = out_index
			else:
				held_measured_after = _held_game_budget_after_metrics(last_measured_after, held_runtime_metrics, time_seconds)
			analyzer.apply_after_feedback(float(held_measured_after.get("raw_risk", 0.0)), 1.0 / _output_fps, held_measured_after)
			max_after_risk = max(max_after_risk, float(held_measured_after.get("raw_risk", 0.0)))
			max_after_luminance = max(max_after_luminance, float(held_measured_after.get("luminance", 0.0)))
			max_after_red = max(max_after_red, float(held_measured_after.get("red", 0.0)))
			max_after_spatial = max(max_after_spatial, float(held_measured_after.get("spatial", 0.0)))
			if float(held_measured_after.get("raw_risk", 0.0)) > DEFAULT_TARGET_RISK:
				after_over_target_frames += 1
			raw_csv.store_line(_metrics_csv_row(out_index + 1, time_seconds, held_runtime_metrics))
			control_csv.store_line(_control_csv_row(out_index + 1, time_seconds, source_index + 1, held_runtime_metrics, held_measured_after, analyzer.mitigation_strength, held_shader_parameters))
			last_runtime_metrics = held_runtime_metrics.duplicate(true)
			last_shader_parameters = held_shader_parameters.duplicate(true)
			continue

		var raw_gpu_metrics: Dictionary = _analyze_raw_texture(raw_gpu, pipeline.analysis_source_texture, time_seconds)
		raw_gpu_metrics["source_kind"] = "frame_sequence"
		if _raw_spatial_override_enabled:
			analyzer.apply_spatial_image_override(raw_gpu_metrics, source_image)
		var runtime_metrics: Dictionary = analyzer.update_from_metrics(raw_gpu_metrics, analysis_delta, time_seconds)
		analyzed_frames += 1
		last_raw_sample_frame = out_index
		var shader_parameters: Dictionary = _shader_parameters_for_metrics(analyzer, runtime_metrics)
		var solver_result: Dictionary = current_frame_solver.solve(
			pipeline,
			solver_after_gpu,
			solver_after_analyzer,
			shader_parameters,
			DEFAULT_TARGET_RISK,
			1.0 / _output_fps,
			time_seconds,
			"frame_sequence",
			null,
			_solver_preview_spatial_readback_enabled,
			runtime_metrics
		)
		shader_parameters = solver_result.get("parameters", shader_parameters)
		_apply_current_frame_solver_metrics(runtime_metrics, solver_result)
		analyzer.apply_current_frame_shader_solution(shader_parameters, runtime_metrics)
		pipeline.apply_mitigation(shader_parameters)

		var after_output_image: Image = _read_texture_image(pipeline.after_texture)
		if after_output_image == null:
			_failed = true
			continue
		var raw_frame_path := raw_dir.path_join("frame_%06d.png" % [out_index + 1])
		var after_frame_path := after_dir.path_join("frame_%06d.png" % [out_index + 1])
		_save_png(_read_texture_image(pipeline.source_texture), raw_frame_path)
		if not _save_png(after_output_image, after_frame_path):
			continue
		var measured_after: Dictionary
		if _should_measure_game_budget_after(out_index, last_after_sample_frame, last_measured_after, runtime_metrics):
			measured_after = _measure_visible_after_frame(
				solver_after_gpu,
				solver_after_analyzer,
				pipeline.after_texture,
				after_output_image,
				1.0 / _output_fps,
				time_seconds,
				_after_spatial_override_enabled
			)
			last_measured_after = measured_after.duplicate(true)
			last_after_sample_frame = out_index
		else:
			measured_after = _held_game_budget_after_metrics(last_measured_after, runtime_metrics, time_seconds)
		analyzer.apply_after_feedback(float(measured_after.get("raw_risk", 0.0)), 1.0 / _output_fps, measured_after)

		max_raw_risk = max(max_raw_risk, float(runtime_metrics.get("raw_risk", 0.0)))
		max_after_risk = max(max_after_risk, float(measured_after.get("raw_risk", 0.0)))
		max_after_luminance = max(max_after_luminance, float(measured_after.get("luminance", 0.0)))
		max_after_red = max(max_after_red, float(measured_after.get("red", 0.0)))
		max_after_spatial = max(max_after_spatial, float(measured_after.get("spatial", 0.0)))
		if float(measured_after.get("raw_risk", 0.0)) > DEFAULT_TARGET_RISK:
			after_over_target_frames += 1

		raw_csv.store_line(_metrics_csv_row(out_index + 1, time_seconds, runtime_metrics))
		control_csv.store_line(_control_csv_row(out_index + 1, time_seconds, source_index + 1, runtime_metrics, measured_after, analyzer.mitigation_strength, shader_parameters))
		last_runtime_metrics = runtime_metrics.duplicate(true)
		last_shader_parameters = shader_parameters.duplicate(true)
		last_source_index = source_index

	raw_csv.close()
	control_csv.close()
	var saved_after_stats: Dictionary = _measure_saved_after_sequence(after_dir, after_csv_path)
	max_after_risk = float(saved_after_stats.get("max_after_risk", max_after_risk))
	max_after_luminance = float(saved_after_stats.get("max_after_luminance", max_after_luminance))
	max_after_red = float(saved_after_stats.get("max_after_red", max_after_red))
	max_after_spatial = float(saved_after_stats.get("max_after_spatial", max_after_spatial))
	after_over_target_frames = int(saved_after_stats.get("after_over_target_frames", after_over_target_frames))
	raw_gpu.dispose()
	solver_after_gpu.dispose()
	pipeline.dispose()

	return {
		"schema": "quell-mitigated-frame-export-v1",
		"measurement_backend": "saved-after-frame-sequence-detection-input",
		"local_correction_enabled": analyzer.local_correction_enabled,
		"current_frame_solver_enabled": _current_frame_solver_enabled,
		"game_budget_enabled": _game_budget_enabled,
		"game_budget_skip_raw_risk": _game_budget_skip_raw_risk,
		"game_budget_policy": _game_budget_policy,
		"game_budget_policy_label": _game_budget_policy_label(),
		"spatial_sensitivity": int(analyzer.spatial_sensitivity),
		"mitigation_mode": _mitigation_mode,
		"temporal_blend_alpha": _temporal_blend_alpha,
		"fps": int(round(_output_fps)),
		"source_fps": _source_fps,
		"input_dir": _input_dir,
		"output_dir": _output_dir,
		"target": DEFAULT_TARGET_RISK,
		"dangerous_area_fraction": 0.25,
		"display_width": _display_size.x,
		"display_height": _display_size.y,
		"analysis_width": _analysis_size.x,
		"analysis_height": _analysis_size.y,
		"source_frames": frame_paths.size(),
		"output_frames": output_frames,
		"analyzed_frames": analyzed_frames,
		"live_cadence": _live_cadence,
		"demo_runtime": _match_source_size and is_equal_approx(_output_fps, 60.0) and not _raw_spatial_override_enabled and not _after_spatial_override_enabled and not _solver_preview_spatial_readback_enabled,
		"raw_spatial_override_enabled": _raw_spatial_override_enabled,
		"after_spatial_override_enabled": _after_spatial_override_enabled,
		"solver_preview_spatial_readback_enabled": _solver_preview_spatial_readback_enabled,
		"summary": {
			"max_raw_risk": snapped(max_raw_risk, 0.001),
			"max_after_risk": snapped(max_after_risk, 0.001),
			"after_target_passed": max_after_risk <= DEFAULT_TARGET_RISK + 0.005,
			"after_over_target_frames": after_over_target_frames,
			"max_after_luminance": snapped(max_after_luminance, 0.001),
			"max_after_red": snapped(max_after_red, 0.001),
			"max_after_spatial": snapped(max_after_spatial, 0.001),
		},
		"cases": [
			_case_manifest("pokemon_shock_raw", "pokemon_private_raw", raw_dir, raw_csv_path, output_frames, true),
			_case_manifest("pokemon_shock_after", "pokemon_private_after", after_dir, after_csv_path, output_frames, false),
		],
		"control_metrics_csv": control_csv_path,
		"output_root": output_abs,
	}

func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var index := 0
	while index < args.size():
		var arg := String(args[index])
		if arg.begins_with("--input="):
			_input_dir = _argument_value(arg, "--input=", args, index)
			if arg == "--input=" and index + 1 < args.size():
				index += 1
		elif arg.begins_with("--output-dir="):
			_output_dir = _argument_value(arg, "--output-dir=", args, index)
			if arg == "--output-dir=" and index + 1 < args.size():
				index += 1
		elif arg.begins_with("--output="):
			_output_dir = _argument_value(arg, "--output=", args, index)
			if arg == "--output=" and index + 1 < args.size():
				index += 1
		elif arg.begins_with("--source-fps="):
			_source_fps = max(1.0, float(arg.trim_prefix("--source-fps=")))
		elif arg.begins_with("--output-fps="):
			_output_fps = max(1.0, float(arg.trim_prefix("--output-fps=")))
		elif arg.begins_with("--display="):
			_display_size = _parse_size(arg.trim_prefix("--display="), _display_size)
		elif arg.begins_with("--analysis="):
			_analysis_size = _parse_size(arg.trim_prefix("--analysis="), _analysis_size)
		elif arg.begins_with("--mode="):
			_mitigation_mode = clampi(int(arg.trim_prefix("--mode=")), RuntimeAnalyzerClass.MitigationMode.CURRENT_FRAME_ONLY, RuntimeAnalyzerClass.MitigationMode.ADAPTIVE)
		elif arg.begins_with("--alpha="):
			_temporal_blend_alpha = clamp(float(arg.trim_prefix("--alpha=")), 0.05, 1.0)
		elif arg == "--solver" or arg == "--current-frame-solver":
			_current_frame_solver_enabled = true
		elif arg == "--no-solver" or arg == "--no-current-frame-solver":
			_current_frame_solver_enabled = false
		elif arg == "--preview-solver" or arg == "--no-analytic-solver":
			_analytic_solver_enabled = false
		elif arg == "--analytic-solver":
			_analytic_solver_enabled = true
		elif arg == "--game-budget" or arg == "--quell-game-budget":
			_game_budget_enabled = true
			_current_frame_solver_enabled = true
		elif arg == "--game-budget-atf" or arg == "--quell-game-budget-atf":
			_game_budget_enabled = true
			_current_frame_solver_enabled = true
			_game_budget_policy = RuntimeAnalyzerClass.GameBudgetPolicy.ADAPTIVE_TEMPORAL_FILTER
		elif arg == "--game-budget-skip-raw-risk" or arg == "--quell-game-budget-skip-raw-risk" or arg == "--game-budget-control-only" or arg == "--quell-game-budget-control-only":
			_game_budget_enabled = true
			_game_budget_skip_raw_risk = true
			_current_frame_solver_enabled = true
		elif arg.begins_with("--game-budget-policy=") or arg.begins_with("--quell-game-budget-policy="):
			_game_budget_enabled = true
			_current_frame_solver_enabled = true
			_game_budget_policy = _parse_game_budget_policy(arg.get_slice("=", 1))
		elif arg == "--demo-runtime":
			_output_fps = 60.0
			_live_cadence = true
			_match_source_size = true
			_raw_spatial_override_enabled = false
			_after_spatial_override_enabled = false
			_solver_preview_spatial_readback_enabled = false
		elif arg == "--match-source-size":
			_match_source_size = true
		elif arg == "--no-raw-spatial-override":
			_raw_spatial_override_enabled = false
		elif arg == "--no-after-spatial-override":
			_after_spatial_override_enabled = false
		elif arg == "--no-solver-spatial-readback":
			_solver_preview_spatial_readback_enabled = false
		elif arg == "--live-cadence":
			_live_cadence = true
		elif arg.begins_with("--max-seconds="):
			_max_seconds = max(0.0, float(arg.trim_prefix("--max-seconds=")))
		elif arg.begins_with("--max-frames="):
			_max_frames = maxi(0, int(arg.trim_prefix("--max-frames=")))
		index += 1

func _argument_value(arg: String, prefix: String, args: PackedStringArray, index: int) -> String:
	var value := arg.trim_prefix(prefix)
	if value.is_empty() and index + 1 < args.size():
		return String(args[index + 1])
	return value

func _object_has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func _parse_game_budget_policy(value: String) -> int:
	var normalized := value.to_lower()
	if normalized == "atf" or normalized == "adaptive" or normalized == "adaptive_temporal_filter":
		return RuntimeAnalyzerClass.GameBudgetPolicy.ADAPTIVE_TEMPORAL_FILTER
	return RuntimeAnalyzerClass.GameBudgetPolicy.DIRECT_BRIGHTNESS

func _game_budget_policy_label() -> String:
	if _game_budget_policy == RuntimeAnalyzerClass.GameBudgetPolicy.ADAPTIVE_TEMPORAL_FILTER:
		return "atf"
	return "direct"

func _globalize_path(path: String) -> String:
	if path.begins_with("res://"):
		return ProjectSettings.globalize_path("res://").replace("\\", "/").path_join(path.trim_prefix("res://"))
	if path.is_absolute_path():
		return path.replace("\\", "/")
	if path.begins_with("/") or path.begins_with("\\\\"):
		return path.replace("\\", "/")
	return ProjectSettings.globalize_path(path).replace("\\", "/")

func _parse_size(text: String, fallback: Vector2i) -> Vector2i:
	var parts := text.split("x", false)
	if parts.size() != 2:
		return fallback
	return Vector2i(maxi(1, int(parts[0])), maxi(1, int(parts[1])))

func _analysis_size_for_display(display_size: Vector2i) -> Vector2i:
	return Vector2i(
		maxi(1, int(ceil(float(display_size.x) / float(GAME_BUDGET_ANALYSIS_SCALE_DIVISOR)))),
		maxi(1, int(ceil(float(display_size.y) / float(GAME_BUDGET_ANALYSIS_SCALE_DIVISOR))))
	)

func _make_dir(path: String) -> void:
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err != OK:
		_failed = true
		push_error("Could not create %s: %s" % [path, error_string(err)])

func _clean_frame_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var file_name := dir.get_next()
		if file_name.is_empty():
			break
		if dir.current_is_dir():
			continue
		if (file_name.begins_with("frame_") and file_name.ends_with(".png")) or file_name == "quell_metrics.csv":
			var err := dir.remove(file_name)
			if err != OK:
				_failed = true
				push_error("Could not remove stale export file %s: %s" % [path.path_join(file_name), error_string(err)])
	dir.list_dir_end()

func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		var err := DirAccess.remove_absolute(path)
		if err != OK:
			_failed = true
			push_error("Could not remove stale export file %s: %s" % [path, error_string(err)])

func _frame_paths(input_abs: String) -> PackedStringArray:
	var paths := PackedStringArray()
	var dir := DirAccess.open(input_abs)
	if dir == null:
		return paths
	dir.list_dir_begin()
	while true:
		var file_name := dir.get_next()
		if file_name.is_empty():
			break
		if not dir.current_is_dir() and file_name.begins_with("frame_") and file_name.ends_with(".png"):
			paths.append(input_abs.path_join(file_name))
	dir.list_dir_end()
	paths.sort()
	return paths

func _load_image(path: String) -> Image:
	var image := Image.new()
	var err := image.load(path)
	if err != OK:
		push_error("Could not load frame %s: %s" % [path, error_string(err)])
		return null
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image

func _read_texture_image(texture: Texture2DRD) -> Image:
	if texture == null or not texture.texture_rd_rid.is_valid():
		return null
	var size := texture.get_size()
	var bytes := _rd.texture_get_data(texture.texture_rd_rid, 0)
	if bytes.is_empty():
		push_error("Could not read texture data for %s" % str(size))
		_failed = true
		return null
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, bytes)

func _configure_after_measurement_analyzer(after_analyzer) -> void:
	after_analyzer.mitigation_enabled = false
	after_analyzer.local_correction_enabled = true
	after_analyzer.spatial_sensitivity = RuntimeAnalyzerClass.SpatialSensitivity.BALANCED

func _should_measure_game_budget_after(frame_index: int, last_after_sample_frame: int, last_measured_after: Dictionary, metrics: Dictionary) -> bool:
	if not _game_budget_enabled:
		return true
	if last_measured_after.is_empty():
		return true
	var frames_since_sample := frame_index - last_after_sample_frame
	if frames_since_sample >= GAME_BUDGET_AFTER_SAMPLE_INTERVAL_FRAMES:
		return true
	if float(metrics.get("solver_after_risk", metrics.get("raw_risk", 0.0))) >= DEFAULT_TARGET_RISK and frames_since_sample >= maxi(2, int(GAME_BUDGET_AFTER_SAMPLE_INTERVAL_FRAMES / 2)):
		return true
	return false

func _held_game_budget_after_metrics(last_measured_after: Dictionary, metrics: Dictionary, time_seconds: float) -> Dictionary:
	var after_metrics: Dictionary = last_measured_after.duplicate(true) if not last_measured_after.is_empty() else metrics.duplicate(true)
	if not after_metrics.has("raw_risk"):
		after_metrics["raw_risk"] = float(metrics.get("solver_after_risk", metrics.get("raw_risk", 0.0)))
	var solver_estimate: float = float(metrics.get("solver_after_risk", metrics.get("raw_risk", after_metrics.get("raw_risk", 0.0))))
	after_metrics["estimated_raw_risk"] = max(float(after_metrics.get("raw_risk", 0.0)), solver_estimate)
	after_metrics["source"] = "saved-after-held-skip"
	after_metrics["measurement_skipped"] = true
	after_metrics["time"] = time_seconds
	return after_metrics

func _measure_visible_after_frame(
	after_gpu,
	after_analyzer,
	after_texture: Texture2DRD,
	after_image: Image,
	delta: float,
	time_seconds: float,
	use_spatial_override: bool = true
) -> Dictionary:
	var after_gpu_metrics: Dictionary = after_gpu.analyze_texture(after_texture, time_seconds)
	after_gpu_metrics["source"] = "gpu-after-visible"
	after_gpu_metrics["source_kind"] = "frame_sequence"
	if use_spatial_override and after_image != null:
		after_analyzer.apply_spatial_image_override(after_gpu_metrics, after_image)
	return after_analyzer.update_from_metrics(after_gpu_metrics, delta, time_seconds)

func _measure_saved_after_sequence(after_dir: String, after_csv_path: String) -> Dictionary:
	var frame_paths := _frame_paths(after_dir)
	var pipeline = FramePipelineClass.new()
	var after_gpu = GpuAnalyzerClass.new()
	var after_analyzer = RuntimeAnalyzerClass.new()
	_configure_after_measurement_analyzer(after_analyzer)

	if not pipeline.configure(_display_size, _analysis_size):
		push_error("Failed to configure saved After detection pipeline")
		_failed = true
		return {}
	if not after_gpu.is_ready():
		push_error("Failed to initialize saved After GPU analyzer")
		_failed = true
		pipeline.dispose()
		return {}

	var csv := FileAccess.open(after_csv_path, FileAccess.WRITE)
	if csv == null:
		push_error("Failed to open saved After metrics CSV: %s" % after_csv_path)
		_failed = true
		after_gpu.dispose()
		pipeline.dispose()
		return {}
	csv.store_line(CSV_HEADER)

	var max_after_risk := 0.0
	var max_after_luminance := 0.0
	var max_after_red := 0.0
	var max_after_spatial := 0.0
	var after_over_target_frames := 0
	for frame_index in range(frame_paths.size()):
		var image: Image = _load_image(String(frame_paths[frame_index]))
		if image == null:
			_failed = true
			continue
		if not pipeline.upload_source_image(image, true):
			push_error("Failed to feed saved After frame %d into detection pipeline" % [frame_index + 1])
			_failed = true
			continue
		var time_seconds := float(frame_index) / _output_fps
		var measured_after: Dictionary = _measure_visible_after_frame(
			after_gpu,
			after_analyzer,
			pipeline.analysis_source_texture,
			image,
			1.0 / _output_fps,
			time_seconds,
			_after_spatial_override_enabled
		)
		max_after_risk = max(max_after_risk, float(measured_after.get("raw_risk", 0.0)))
		max_after_luminance = max(max_after_luminance, float(measured_after.get("luminance", 0.0)))
		max_after_red = max(max_after_red, float(measured_after.get("red", 0.0)))
		max_after_spatial = max(max_after_spatial, float(measured_after.get("spatial", 0.0)))
		if float(measured_after.get("raw_risk", 0.0)) > DEFAULT_TARGET_RISK:
			after_over_target_frames += 1
		csv.store_line(_metrics_csv_row(frame_index + 1, time_seconds, measured_after))

	csv.close()
	after_gpu.dispose()
	pipeline.dispose()
	return {
		"max_after_risk": max_after_risk,
		"max_after_luminance": max_after_luminance,
		"max_after_red": max_after_red,
		"max_after_spatial": max_after_spatial,
		"after_over_target_frames": after_over_target_frames,
		"measured_frames": frame_paths.size(),
	}

func _apply_current_frame_solver_metrics(metrics: Dictionary, solver_result: Dictionary) -> void:
	var solver_info = solver_result.get("solver", {})
	if not (solver_info is Dictionary) or not bool(solver_info.get("active", false)):
		return
	metrics["solver_correction_scale"] = float(solver_info.get("correction_scale", 1.0))
	metrics["solver_identity_after_risk"] = float(solver_info.get("identity_after_risk", 0.0))
	metrics["solver_after_risk"] = float(solver_info.get("after_risk", solver_info.get("upper_after_risk", 0.0)))
	metrics["solver_identity"] = bool(solver_info.get("identity", false))
	metrics["solver_upper_bound_exceeded"] = bool(solver_info.get("upper_bound_exceeded", false))

func _shader_parameters_for_metrics(analyzer, metrics: Dictionary) -> Dictionary:
	if _game_budget_enabled and analyzer != null and analyzer.has_method("game_budget_shader_parameters"):
		return analyzer.game_budget_shader_parameters(metrics)
	return analyzer.shader_parameters(metrics)

func _analyze_raw_texture(raw_gpu, texture: Texture2D, time_seconds: float) -> Dictionary:
	if _game_budget_enabled and _game_budget_skip_raw_risk and raw_gpu.has_method("analyze_current_signals"):
		return raw_gpu.analyze_current_signals(texture, time_seconds)
	return raw_gpu.analyze_texture(texture, time_seconds)

func _prepare_analysis_image(image: Image, target_size: Vector2i) -> Image:
	if image.get_width() == target_size.x and image.get_height() == target_size.y:
		return image
	var prepared := image.duplicate()
	if prepared.get_format() != Image.FORMAT_RGBA8:
		prepared.convert(Image.FORMAT_RGBA8)
	var scale: float = min(
		float(target_size.x) / float(max(1, prepared.get_width())),
		float(target_size.y) / float(max(1, prepared.get_height()))
	)
	var fitted_size := Vector2i(
		max(1, roundi(float(prepared.get_width()) * scale)),
		max(1, roundi(float(prepared.get_height()) * scale))
	)
	if prepared.get_width() != fitted_size.x or prepared.get_height() != fitted_size.y:
		prepared.resize(fitted_size.x, fitted_size.y, Image.INTERPOLATE_BILINEAR)
	var output := Image.create_empty(target_size.x, target_size.y, false, Image.FORMAT_RGBA8)
	output.fill(Color.BLACK)
	var offset := Vector2i(
		int((target_size.x - fitted_size.x) / 2),
		int((target_size.y - fitted_size.y) / 2)
	)
	output.blit_rect(prepared, Rect2i(Vector2i.ZERO, fitted_size), offset)
	return output

func _save_png(image, path: String) -> bool:
	if image == null:
		_failed = true
		return false
	var err: Error = image.save_png(path)
	if err != OK:
		_failed = true
		push_error("Could not save %s: %s" % [path, error_string(err)])
		return false
	return true

func _metrics_csv_row(frame: int, time_seconds: float, metrics: Dictionary) -> String:
	var values := [
		frame,
		time_seconds,
		float(metrics.get("luminance", 0.0)),
		float(metrics.get("red", 0.0)),
		float(metrics.get("spatial", 0.0)),
		float(metrics.get("raw_risk", 0.0)),
		int(metrics.get("general_flash_count", 0)),
		int(metrics.get("red_flash_count", 0)),
		float(metrics.get("general_flash_area", 0.0)),
		float(metrics.get("red_flash_area", 0.0)),
		float(metrics.get("red_current_area", metrics.get("red_saturation_area", 0.0))),
		float(metrics.get("frame_luminance_contrast", metrics.get("luminance_contrast", 0.0))),
		float(metrics.get("temporal_luminance_contrast", 0.0)),
	]
	var cells := PackedStringArray()
	for value in values:
		if value is float:
			cells.append("%.6f" % float(value))
		else:
			cells.append(str(value))
	return ",".join(cells)

func _control_csv_row(frame: int, time_seconds: float, source_frame: int, raw_metrics: Dictionary, after_metrics: Dictionary, analyzer_strength: float, shader_parameters: Dictionary) -> String:
	var mitigation_mode: int = int(shader_parameters.get("mitigation_mode", RuntimeAnalyzerClass.MitigationMode.CURRENT_FRAME_ONLY))
	var visual_control_gain: float = CURRENT_VISUAL_CONTROL_GAIN if mitigation_mode == RuntimeAnalyzerClass.MitigationMode.CURRENT_FRAME_ONLY else TEMPORAL_VISUAL_CONTROL_GAIN
	var visual_control: float = clamp(float(shader_parameters.get("mitigation_strength", 0.0)) * visual_control_gain, 0.0, 1.0)
	var visible_after_risk: float = float(after_metrics.get("raw_risk", 0.0))
	if _game_budget_enabled and bool(after_metrics.get("measurement_skipped", false)):
		visible_after_risk = float(after_metrics.get("estimated_raw_risk", visible_after_risk))
	var values := [
		frame,
		time_seconds,
		source_frame,
		float(raw_metrics.get("raw_risk", 0.0)),
		visible_after_risk,
		float(raw_metrics.get("control_risk", 0.0)),
		float(raw_metrics.get("raw_source_control_risk", 0.0)),
		float(raw_metrics.get("temporal_raw_after_activity", 0.0)),
		float(raw_metrics.get("temporal_after_pressure", 0.0)),
		analyzer_strength,
		float(shader_parameters.get("mitigation_strength", 0.0)),
		int(shader_parameters.get("mitigation_mode", 0)),
		float(shader_parameters.get("red_suppression", 0.0)),
		float(shader_parameters.get("contrast_reduction", 0.0)),
		float(shader_parameters.get("blur_strength", 0.0)),
		float(shader_parameters.get("luminance_delta_limit", 1.0)),
		float(shader_parameters.get("contrast_scale_limit", 1.0)),
		float(shader_parameters.get("spatial_contrast_limit", 1.0)),
		float(shader_parameters.get("temporal_blend_alpha", 1.0)),
		float(shader_parameters.get("mitigation_enabled_signal", 0.0)),
		float(shader_parameters.get("correction_mix_alpha", 1.0)),
		float(shader_parameters.get("temporal_projection_strength", 0.0)),
		float(raw_metrics.get("solver_correction_scale", shader_parameters.get("solver_correction_scale", 1.0))),
		float(raw_metrics.get("solver_identity_after_risk", 0.0)),
		float(raw_metrics.get("solver_after_risk", shader_parameters.get("solver_after_risk", 0.0))),
		clamp(float(shader_parameters.get("brightness_reduction", 0.0)) * visual_control, 0.0, 1.0),
		clamp((1.0 - float(shader_parameters.get("contrast_scale_limit", 1.0))) * visual_control, 0.0, 1.0),
		clamp((1.0 - float(shader_parameters.get("temporal_blend_alpha", 1.0))) * visual_control, 0.0, 1.0),
		int(raw_metrics.get("general_flash_count", 0)),
		int(after_metrics.get("general_flash_count", 0)),
		int(raw_metrics.get("red_flash_count", 0)),
		int(after_metrics.get("red_flash_count", 0)),
		float(raw_metrics.get("general_flash_area", 0.0)),
		float(after_metrics.get("general_flash_area", 0.0)),
		float(raw_metrics.get("red_flash_area", 0.0)),
		float(after_metrics.get("red_flash_area", 0.0)),
		float(shader_parameters.get("game_budget_control_risk", 0.0)),
		float(shader_parameters.get("game_budget_raw_after_activity", 0.0)),
		float(shader_parameters.get("game_budget_high_area_pressure", 0.0)),
		float(shader_parameters.get("game_budget_output_history_pressure", 0.0)),
		float(shader_parameters.get("game_budget_luminance_event_pressure", 0.0)),
		float(shader_parameters.get("game_budget_after_history_hold", 0.0)),
		float(shader_parameters.get("game_budget_after_history_pressure", 0.0)),
		float(shader_parameters.get("game_budget_burst_hold", 0.0)),
		float(shader_parameters.get("game_budget_flash_impulse", 0.0)),
		float(shader_parameters.get("game_budget_flash_debt", 0.0)),
		float(shader_parameters.get("game_budget_flash_debt_state", 0.0)),
		float(shader_parameters.get("game_budget_target_pressure", 0.0)),
		float(shader_parameters.get("game_budget_release_slowdown", 0.0)),
		float(shader_parameters.get("game_budget_release_rate", 0.0)),
	]
	var cells := PackedStringArray()
	for value in values:
		if value is float:
			cells.append("%.6f" % float(value))
		else:
			cells.append(str(value))
	return ",".join(cells)

func _case_manifest(case_name: String, group: String, frames_dir: String, csv_path: String, frame_count: int, expected_fail) -> Dictionary:
	return {
		"name": case_name,
		"id": case_name,
		"group": group,
		"source": "pokemon_shock_private",
		"frames_dir": frames_dir,
		"quell_metrics_csv": csv_path,
		"fps": int(round(_output_fps)),
		"frame_count": frame_count,
		"dangerous_area_fraction": 0.25,
		"expected_luminance": expected_fail,
		"expected_red": null,
		"expected_pattern": null,
		"strict_quell_expected": false,
		"strict_reference_expected": false,
	}

func _write_json(path: String, payload: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failed = true
		push_error("Could not write manifest: %s" % path)
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
