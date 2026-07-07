extends SceneTree

const RuntimeAnalyzerClass = preload("res://addons/quell_core/runtime/quell_analyzer.gd")
const GpuAnalyzerClass = preload("res://addons/quell_core/runtime/quell_gpu_analyzer.gd")
const FramePipelineClass = preload("res://addons/quell_core/runtime/quell_gpu_frame_pipeline.gd")
const CurrentFrameSolverClass = preload("res://addons/quell_core/runtime/quell_current_frame_solver.gd")
const NativeBridgeClass = preload("res://addons/quell_core/runtime/quell_native_bridge.gd")
const ProjectionReferenceClass = preload("res://addons/quell_core/runtime/quell_projection_reference.gd")
const SpatialReferenceClass = preload("res://addons/quell_core/runtime/quell_spatial_reference.gd")

const CSV_HEADER := "Frame,TimeSeconds,QuellLuminance,QuellRed,QuellSpatial,QuellRawRisk,GeneralFlashCount,RedFlashCount,GeneralFlashArea,RedFlashArea,RedSaturationArea,FrameLuminanceContrast,TemporalLuminanceContrast"
const CONTROL_CSV_HEADER := "Frame,TimeSeconds,SourceFrame,RawRisk,AfterRisk,ControlRisk,RawSourceControlRisk,CurrentRawDetectorRisk,OutputRisk,PreviousAfterRisk,TemporalRawAfterActivity,TemporalAfterPressure,CurrentFrameAfterBudgetGuardActivity,TemporalSourceActivity,TemporalAfterActivity,TemporalAfterFeedbackActivity,RedCurrentArea,CurrentHighLuminanceArea,FrameLuminanceContrast,TemporalLuminanceContrast,AnalyzerStrength,ShaderStrength,MitigationMode,RedSuppression,ContrastReduction,BlurStrength,LuminanceDeltaLimit,ContrastScaleLimit,SpatialContrastLimit,TemporalBlendAlpha,MitigationEnabledSignal,CorrectionMixAlpha,TemporalProjectionStrength,SolverCorrectionScale,SolverIdentityAfterRisk,SolverAfterRisk,EffectiveBrightness,EffectiveContrast,EffectiveFeedback,RawGeneralFlashCount,AfterGeneralFlashCount,RawRedFlashCount,AfterRedFlashCount,RawGeneralFlashArea,AfterGeneralFlashArea,RawRedFlashArea,AfterRedFlashArea,GameBudgetControlRisk,GameBudgetRawAfterActivity,GameBudgetHighAreaPressure,GameBudgetOutputHistoryPressure,GameBudgetLuminanceEventPressure,GameBudgetAfterHistoryHold,GameBudgetAfterHistoryPressure,GameBudgetBurstHold,GameBudgetFlashImpulse,GameBudgetFlashDebt,GameBudgetFlashDebtState,GameBudgetTargetPressure,GameBudgetReleaseSlowdown,GameBudgetReleaseRate"
const DEFAULT_INPUT_DIR := "res://validation/private/demo-videos/pokemon-shock/frames"
const DEFAULT_OUTPUT_DIR := "res://validation/private/mitigation/pokemon-shock-quell-after"
const DEFAULT_SOURCE_FPS := 1199.0 / 50.0
const DEFAULT_OUTPUT_FPS := 30.0
const DEFAULT_DISPLAY_SIZE := Vector2i(1280, 720)
const DEFAULT_ANALYSIS_SIZE := Vector2i(256, 144)
const DEFAULT_TARGET_RISK := 0.80
const GAME_BUDGET_ANALYSIS_SCALE_DIVISOR: int = 16
const GAME_BUDGET_RAW_SAMPLE_INTERVAL_FRAMES: int = 2
const GAME_BUDGET_AFTER_SAMPLE_INTERVAL_FRAMES: int = 1
const TEMPORAL_VISUAL_CONTROL_GAIN := 1.36
const CURRENT_VISUAL_CONTROL_GAIN := 1.10
const GAME_BUDGET_PROJECTION_LEGACY := 0
const GAME_BUDGET_PROJECTION_CLOSED_FORM := 1

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
var _game_budget_projection_mode: int = GAME_BUDGET_PROJECTION_CLOSED_FORM
var _solver_fast_identity := -1
var _raw_spatial_override_enabled := true
var _after_spatial_override_enabled := true
var _solver_preview_spatial_readback_enabled := true
var _match_source_size := false
var _live_cadence := false
var _max_seconds := 0.0
var _max_frames := 0
var _native_enabled := false
var _hard_projection_enabled := false
var _oracle_projection_enabled := false
# Oracle mitigation style: "risecap" (sharp/dark, default) or "lowpass" (bright glow).
var _mitigation_style := "risecap"
var _regional_luminance := false
var _lookahead := 0   # buffered-analysis depth (frames) for regional luminance
var _save_visible_after_output := false
var _solver_bisection_steps := -1
var _debug_preview_frame := -1
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
	var visible_after_dir := output_abs.path_join("visible_after")
	_make_dir(raw_dir)
	_make_dir(after_dir)
	if _save_visible_after_output:
		_make_dir(visible_after_dir)
	if _failed:
		quit(1)
		return
	_clean_frame_dir(raw_dir)
	_clean_frame_dir(after_dir)
	if _save_visible_after_output:
		_clean_frame_dir(visible_after_dir)
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

	var manifest := _export_frames(frame_paths, raw_dir, after_dir, visible_after_dir if _save_visible_after_output else "", output_abs)
	_write_json(output_abs.path_join("manifest.json"), manifest)
	print(JSON.stringify(manifest, "\t"))
	quit(1 if _failed else 0)

func _export_frames_oracle_projection(frame_paths: PackedStringArray, raw_dir: String, after_dir: String, output_abs: String) -> Dictionary:
	# Validates the verified GDScript projection oracle (QuellProjectionReference)
	# end-to-end against the REAL analyzer. Mitigation runs on CPU at analysis
	# resolution; saved frames are re-measured by the same analyzer the gate uses.
	# Not a realtime path — this proves the algorithm before the GPU/native port.
	_display_size = _analysis_size
	var duration: float = float(frame_paths.size()) / max(1.0, _source_fps)
	if _max_seconds > 0.0:
		duration = min(duration, _max_seconds)
	var output_frames := maxi(1, int(floor(duration * _output_fps)))
	if _max_frames > 0:
		output_frames = mini(output_frames, _max_frames)

	var projection = ProjectionReferenceClass.new()
	projection.target_risk = DEFAULT_TARGET_RISK
	projection.mitigation_style = ProjectionReferenceClass.STYLE_TEMPORAL_LOWPASS if _mitigation_style == "lowpass" else ProjectionReferenceClass.STYLE_RISE_CAP
	projection.regional_luminance = _regional_luminance
	projection.reset()

	# Pass 1 (LOOKAHEAD): prepare every output frame's analysis image and, if a
	# lookahead depth is set, compute a per-frame regional hazard over a window
	# that includes FUTURE frames (the buffered-analysis idea). This lets regional
	# luminance mitigate a fresh flashing region the instant it appears, with no
	# cut-onset leak, at the cost of the buffer's display delay.
	var analysis_images: Array = []
	for out_index in range(output_frames):
		var t := float(out_index) / _output_fps
		var si := clampi(int(floor(t * _source_fps)), 0, frame_paths.size() - 1)
		var src: Image = _load_image(String(frame_paths[si]))
		analysis_images.append(_prepare_analysis_image(src, _analysis_size) if src != null else null)
	var lookahead_hazards: Array = []
	if _lookahead > 0 and _regional_luminance:
		lookahead_hazards = _compute_lookahead_hazards(analysis_images, _lookahead)

	for out_index in range(output_frames):
		var time_seconds := float(out_index) / _output_fps
		var analysis_source: Image = analysis_images[out_index]
		if analysis_source == null:
			_failed = true
			continue
		if out_index < lookahead_hazards.size():
			projection.set_external_hazard(lookahead_hazards[out_index])
		var projected: Image = projection.step(analysis_source, time_seconds)
		_save_png(analysis_source, raw_dir.path_join("frame_%06d.png" % [out_index + 1]))
		_save_png(projected, after_dir.path_join("frame_%06d.png" % [out_index + 1]))

	var raw_csv_path := raw_dir.path_join("quell_metrics.csv")
	var after_csv_path := after_dir.path_join("quell_metrics.csv")
	var raw_stats: Dictionary = _measure_saved_after_sequence(raw_dir, raw_csv_path)
	var after_stats: Dictionary = _measure_saved_after_sequence(after_dir, after_csv_path)

	var cases := [
		_case_manifest("pokemon_shock_raw", "pokemon_private_raw", raw_dir, raw_csv_path, output_frames, true),
		_case_manifest("pokemon_shock_after", "pokemon_private_after", after_dir, after_csv_path, output_frames, false),
	]
	var max_after_risk := float(after_stats.get("max_after_risk", 0.0))
	return {
		"schema": "quell-mitigated-frame-export-v1",
		"mitigation_algorithm": "hard-constrained-projection-oracle",
		"mitigation_style": _mitigation_style,
		"measurement_backend": "saved-after-frame-sequence-detection-input",
		"runtime_backend": "native" if _native_enabled else "gdscript",
		"game_budget_enabled": false,
		"mitigation_mode": 3,
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
		"summary": {
			"max_raw_risk": snapped(float(raw_stats.get("max_after_risk", 0.0)), 0.001),
			"max_after_risk": snapped(max_after_risk, 0.001),
			"after_target_passed": max_after_risk <= DEFAULT_TARGET_RISK + 0.005,
			"after_over_target_frames": int(after_stats.get("after_over_target_frames", 0)),
			"max_after_luminance": snapped(float(after_stats.get("max_after_luminance", 0.0)), 0.001),
			"max_after_red": snapped(float(after_stats.get("max_after_red", 0.0)), 0.001),
			"max_after_spatial": snapped(float(after_stats.get("max_after_spatial", 0.0)), 0.001),
		},
		"cases": cases,
		"output_root": output_abs,
	}

# LOOKAHEAD hazard: for each output frame, a per-tile regional hazard computed
# over a window [frame-depth .. frame+depth] (so it sees future frames). A tile
# that flashes anywhere in that window is hazardous NOW, which is what removes the
# cut-onset leak of the causal regional hazard. Matches the oracle's tile grid.
func _compute_lookahead_hazards(analysis_images: Array, depth: int) -> Array:
	var W: int = _analysis_size.x
	var H: int = _analysis_size.y
	var TS := 16
	var cols := int(ceil(float(W) / float(TS)))
	var rows := int(ceil(float(H) / float(TS)))
	var n := analysis_images.size()
	const DELTA := 0.10
	const DARK := 0.80
	const KNEE := 0.05
	const FULL := 0.2
	# Per-frame linear-luma arrays.
	var lumas: Array = []
	for f in range(n):
		var img: Image = analysis_images[f]
		var la := PackedFloat32Array()
		la.resize(W * H)
		if img != null:
			for y in range(H):
				for x in range(W):
					la[y * W + x] = _lin_luma(img.get_pixel(x, y))
		lumas.append(la)
	# Per-frame per-tile flashing area (qualifying transition vs previous frame).
	var flash: Array = []
	for f in range(n):
		var fa := PackedFloat32Array()
		fa.resize(cols * rows)
		if f > 0:
			var cur: PackedFloat32Array = lumas[f]
			var prev: PackedFloat32Array = lumas[f - 1]
			var cnt := PackedInt32Array()
			cnt.resize(cols * rows)
			for y in range(H):
				var tr := (y / TS) * cols
				for x in range(W):
					var i := y * W + x
					if absf(cur[i] - prev[i]) >= DELTA and minf(cur[i], prev[i]) < DARK:
						cnt[tr + (x / TS)] += 1
			for t in range(cols * rows):
				fa[t] = float(cnt[t]) / float(TS * TS)
		flash.append(fa)
	# Windowed (past+future) box sum -> knee/full -> blur.
	var hazards: Array = []
	for f in range(n):
		var raw := PackedFloat32Array()
		raw.resize(cols * rows)
		for t in range(cols * rows):
			var s := 0.0
			for w in range(maxi(0, f - depth), mini(n, f + depth + 1)):
				s += float((flash[w] as PackedFloat32Array)[t])
			raw[t] = clampf((s - KNEE) / (FULL - KNEE), 0.0, 1.0)
		hazards.append(_blur_tile_grid(raw, cols, rows))
	return hazards

func _lin_luma(c: Color) -> float:
	return _srgb_lin(c.r) * 0.2126 + _srgb_lin(c.g) * 0.7152 + _srgb_lin(c.b) * 0.0722

func _srgb_lin(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)

func _blur_tile_grid(field: PackedFloat32Array, cols: int, rows: int) -> PackedFloat32Array:
	if cols <= 1 and rows <= 1:
		return field
	var current := field.duplicate()
	for _pass in range(2):
		var horizontal := current.duplicate()
		for row in range(rows):
			for col in range(cols):
				var acc := 0.0
				var num := 0
				for dc in range(-1, 2):
					var cc := col + dc
					if cc < 0 or cc >= cols:
						continue
					acc += current[row * cols + cc]
					num += 1
				horizontal[row * cols + col] = acc / float(num)
		for row in range(rows):
			for col in range(cols):
				var acc := 0.0
				var num := 0
				for dr in range(-1, 2):
					var rr := row + dr
					if rr < 0 or rr >= rows:
						continue
					acc += horizontal[rr * cols + col]
					num += 1
				current[row * cols + col] = acc / float(num)
	return current

func _export_frames_hard_projection(frame_paths: PackedStringArray, raw_dir: String, after_dir: String, output_abs: String) -> Dictionary:
	var duration: float = float(frame_paths.size()) / max(1.0, _source_fps)
	if _max_seconds > 0.0:
		duration = min(duration, _max_seconds)
	var output_frames := maxi(1, int(floor(duration * _output_fps)))
	if _max_frames > 0:
		output_frames = mini(output_frames, _max_frames)

	var pipeline = _make_frame_pipeline()
	if pipeline == null:
		_failed = true
		return {}
	if not pipeline.configure(_display_size, _analysis_size):
		push_error("Failed to configure hard-projection pipeline")
		_failed = true
		return {}
	# The oracle runs as a CPU shadow at analysis resolution: it solves the
	# per-frame event budget, tone map, and spatial scale, and the GPU pass
	# (quell_hard_projection.glsl) applies the same solution at display
	# resolution. Safety does not rest on the shadow being exact — the GPU
	# finisher clamps against the GPU's own previous-after texture, and the
	# gate re-measures the saved frames.
	var solver = ProjectionReferenceClass.new()
	solver.target_risk = DEFAULT_TARGET_RISK
	solver.reset()

	for out_index in range(output_frames):
		var time_seconds := float(out_index) / _output_fps
		var source_index := clampi(int(floor(time_seconds * _source_fps)), 0, frame_paths.size() - 1)
		var source_image: Image = _load_image(String(frame_paths[source_index]))
		if source_image == null:
			_failed = true
			continue
		if not pipeline.upload_source_image(source_image, true):
			push_error("Failed to upload source frame %d" % source_index)
			_failed = true
			continue
		var analysis_image := _prepare_analysis_image(source_image, _analysis_size)
		solver.step(analysis_image, time_seconds)
		var shader_parameters := {
			"mitigation_mode": 3,
			"mitigation_strength": 1.0,
			"mitigation_enabled_signal": 1.0,
			"tone_enforced": 1.0 if bool(solver.last_solution.get("enforced", false)) else 0.0,
			"tone_gain": float(solver.last_solution.get("tone_gain", 1.0)),
			"tone_floor": float(solver.last_solution.get("tone_floor", 0.0)),
			"spatial_contrast_scale": solver.last_spatial_scale,
			"spatial_mean_luma": solver.last_spatial_mean,
		}
		pipeline.apply_mitigation(shader_parameters)
		var clean_after: Image = _read_texture_image(_after_output_texture(pipeline))
		if clean_after == null:
			_failed = true
			continue
		_save_png(_read_texture_image(pipeline.source_texture), raw_dir.path_join("frame_%06d.png" % [out_index + 1]))
		_save_png(clean_after, after_dir.path_join("frame_%06d.png" % [out_index + 1]))

	pipeline.dispose()

	var raw_csv_path := raw_dir.path_join("quell_metrics.csv")
	var after_csv_path := after_dir.path_join("quell_metrics.csv")
	var raw_stats: Dictionary = _measure_saved_after_sequence(raw_dir, raw_csv_path)
	var after_stats: Dictionary = _measure_saved_after_sequence(after_dir, after_csv_path)

	var cases := [
		_case_manifest("pokemon_shock_raw", "pokemon_private_raw", raw_dir, raw_csv_path, output_frames, true),
		_case_manifest("pokemon_shock_after", "pokemon_private_after", after_dir, after_csv_path, output_frames, false),
	]
	var max_after_risk := float(after_stats.get("max_after_risk", 0.0))
	return {
		"schema": "quell-mitigated-frame-export-v1",
		"mitigation_algorithm": "hard-constrained-projection",
		"measurement_backend": "saved-after-frame-sequence-detection-input",
		"runtime_backend": "native" if _native_enabled else "gdscript",
		"game_budget_enabled": false,
		"mitigation_mode": 3,
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
		"raw_spatial_override_enabled": _raw_spatial_override_enabled,
		"after_spatial_override_enabled": _after_spatial_override_enabled,
		"summary": {
			"max_raw_risk": snapped(float(raw_stats.get("max_after_risk", 0.0)), 0.001),
			"max_after_risk": snapped(max_after_risk, 0.001),
			"after_target_passed": max_after_risk <= DEFAULT_TARGET_RISK + 0.005,
			"after_over_target_frames": int(after_stats.get("after_over_target_frames", 0)),
			"max_after_luminance": snapped(float(after_stats.get("max_after_luminance", 0.0)), 0.001),
			"max_after_red": snapped(float(after_stats.get("max_after_red", 0.0)), 0.001),
			"max_after_spatial": snapped(float(after_stats.get("max_after_spatial", 0.0)), 0.001),
		},
		"cases": cases,
		"output_root": output_abs,
	}

func _export_frames(frame_paths: PackedStringArray, raw_dir: String, after_dir: String, visible_after_dir: String, output_abs: String) -> Dictionary:
	if _oracle_projection_enabled:
		return _export_frames_oracle_projection(frame_paths, raw_dir, after_dir, output_abs)
	if _hard_projection_enabled:
		return _export_frames_hard_projection(frame_paths, raw_dir, after_dir, output_abs)
	var duration: float = float(frame_paths.size()) / max(1.0, _source_fps)
	if _max_seconds > 0.0:
		duration = min(duration, _max_seconds)
	var output_frames := maxi(1, int(floor(duration * _output_fps)))
	if _max_frames > 0:
		output_frames = mini(output_frames, _max_frames)

	var pipeline = _make_frame_pipeline()
	var raw_gpu = _make_gpu_analyzer()
	var solver_after_gpu = _make_gpu_analyzer()
	var analyzer = _make_analyzer()
	var solver_after_analyzer = _make_analyzer()
	var current_frame_solver = _make_current_frame_solver()
	if pipeline == null or raw_gpu == null or solver_after_gpu == null or analyzer == null or solver_after_analyzer == null or current_frame_solver == null:
		_failed = true
		return {}
	current_frame_solver.enabled = _current_frame_solver_enabled
	if _object_has_property(current_frame_solver, "analytic_enabled"):
		current_frame_solver.analytic_enabled = _analytic_solver_enabled
	if _solver_bisection_steps >= 0 and _object_has_property(current_frame_solver, "bisection_steps"):
		current_frame_solver.bisection_steps = _solver_bisection_steps
	if _object_has_property(current_frame_solver, "game_budget_enabled"):
		current_frame_solver.game_budget_enabled = _game_budget_enabled
	if _object_has_property(current_frame_solver, "game_budget_projection_mode"):
		current_frame_solver.game_budget_projection_mode = _game_budget_projection_mode
	if _object_has_property(current_frame_solver, "fast_identity_enabled"):
		current_frame_solver.fast_identity_enabled = _game_budget_enabled if _solver_fast_identity < 0 else _solver_fast_identity > 0
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
				var held_visible_after_frame_path := visible_after_dir.path_join("frame_%06d.png" % [out_index + 1]) if _save_visible_after_output else ""
				var held_source: Image = _read_texture_image(pipeline.source_texture)
				var held_clean_after: Image = _read_texture_image(_after_output_texture(pipeline))
				if held_source != null:
					_save_png(held_source, held_raw_frame_path)
				if not last_runtime_metrics.is_empty() and held_clean_after != null:
					var held_metrics := last_runtime_metrics.duplicate(true)
					held_metrics["time"] = time_seconds
					var held_after_metrics: Dictionary
					if _should_measure_game_budget_after(out_index, last_after_sample_frame, last_measured_after, held_metrics):
						held_after_metrics = _measure_visible_after_frame(
							solver_after_gpu,
							solver_after_analyzer,
							_after_measurement_texture(pipeline),
							held_clean_after,
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
					_apply_after_output_metrics(held_metrics, held_after_metrics)
					_refresh_visible_after_overlay(pipeline, last_shader_parameters, held_metrics)
					raw_csv.store_line(_metrics_csv_row(out_index + 1, time_seconds, held_metrics))
					control_csv.store_line(_control_csv_row(out_index + 1, time_seconds, sequence_index + 1, held_metrics, held_after_metrics, analyzer.mitigation_strength, last_shader_parameters))
				if held_clean_after != null:
					_save_after_outputs(pipeline, held_clean_after, held_after_frame_path, held_visible_after_frame_path)
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
			var held_clean_output_image: Image = _read_texture_image(_after_output_texture(pipeline))
			if held_clean_output_image == null:
				_failed = true
				continue
			var held_raw_path := raw_dir.path_join("frame_%06d.png" % [out_index + 1])
			var held_after_path := after_dir.path_join("frame_%06d.png" % [out_index + 1])
			var held_visible_after_path := visible_after_dir.path_join("frame_%06d.png" % [out_index + 1]) if _save_visible_after_output else ""
			_save_png(_read_texture_image(pipeline.source_texture), held_raw_path)
			var held_measured_after: Dictionary
			if _should_measure_game_budget_after(out_index, last_after_sample_frame, last_measured_after, held_runtime_metrics):
				held_measured_after = _measure_visible_after_frame(
					solver_after_gpu,
					solver_after_analyzer,
					_after_measurement_texture(pipeline),
					held_clean_output_image,
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
			_apply_after_output_metrics(held_runtime_metrics, held_measured_after)
			_refresh_visible_after_overlay(pipeline, held_shader_parameters, held_runtime_metrics)
			if not _save_after_outputs(pipeline, held_clean_output_image, held_after_path, held_visible_after_path):
				continue
			raw_csv.store_line(_metrics_csv_row(out_index + 1, time_seconds, held_runtime_metrics))
			control_csv.store_line(_control_csv_row(out_index + 1, time_seconds, source_index + 1, held_runtime_metrics, held_measured_after, analyzer.mitigation_strength, held_shader_parameters))
			last_runtime_metrics = held_runtime_metrics.duplicate(true)
			last_shader_parameters = held_shader_parameters.duplicate(true)
			continue

		var raw_gpu_metrics: Dictionary = _analyze_raw_texture(raw_gpu, pipeline.analysis_source_texture, time_seconds)
		raw_gpu_metrics["source_kind"] = "frame_sequence"
		if _raw_spatial_override_enabled and analyzer.has_method("apply_spatial_image_override"):
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
		var debug_preview_analysis_image: Image = null
		var debug_preview_metrics: Dictionary = {}
		var debug_gpu_state: Dictionary = {}
		var debug_after_state: Dictionary = {}
		if _debug_preview_frame == out_index + 1 and pipeline.has_method("preview_mitigation"):
			if solver_after_gpu.has_method("capture_runtime_state"):
				debug_gpu_state = solver_after_gpu.capture_runtime_state()
			if solver_after_analyzer.has_method("capture_runtime_state"):
				debug_after_state = solver_after_analyzer.capture_runtime_state()
			if pipeline.preview_mitigation(shader_parameters):
				var preview_texture = pipeline.preview_analysis_after_texture if pipeline.preview_analysis_after_texture != null else pipeline.preview_after_texture
				debug_preview_analysis_image = _read_texture_image(preview_texture)
				if debug_preview_analysis_image != null:
					debug_preview_metrics = _measure_visible_after_frame(
						solver_after_gpu,
						solver_after_analyzer,
						preview_texture,
						debug_preview_analysis_image,
						1.0 / _output_fps,
						time_seconds,
						_after_spatial_override_enabled
					)
			_restore_debug_analyzer_state(solver_after_gpu, debug_gpu_state)
			_restore_debug_analyzer_state(solver_after_analyzer, debug_after_state)
		pipeline.apply_mitigation(shader_parameters)
		if _debug_preview_frame == out_index + 1:
			var apply_analysis_image: Image = _read_texture_image(pipeline.analysis_after_texture)
			var apply_analysis_metrics: Dictionary = {}
			if apply_analysis_image != null:
				if solver_after_gpu.has_method("capture_runtime_state"):
					debug_gpu_state = solver_after_gpu.capture_runtime_state()
				if solver_after_analyzer.has_method("capture_runtime_state"):
					debug_after_state = solver_after_analyzer.capture_runtime_state()
				apply_analysis_metrics = _measure_visible_after_frame(
					solver_after_gpu,
					solver_after_analyzer,
					pipeline.analysis_after_texture,
					apply_analysis_image,
					1.0 / _output_fps,
					time_seconds,
					_after_spatial_override_enabled
				)
				_restore_debug_analyzer_state(solver_after_gpu, debug_gpu_state)
				_restore_debug_analyzer_state(solver_after_analyzer, debug_after_state)
			var diff_summary := _image_diff_summary(debug_preview_analysis_image, apply_analysis_image)
			print("[preview-apply-debug] frame=%d preview_risk=%.6f apply_risk=%.6f solver_risk=%.6f diff_pixels=%d max_channel_delta=%d mean_channel_delta=%.6f params=%s" % [
				out_index + 1,
				float(debug_preview_metrics.get("raw_risk", -1.0)),
				float(apply_analysis_metrics.get("raw_risk", -1.0)),
				float(runtime_metrics.get("solver_after_risk", -1.0)),
				int(diff_summary.get("diff_pixels", -1)),
				int(diff_summary.get("max_channel_delta", -1)),
				float(diff_summary.get("mean_channel_delta", -1.0)),
				JSON.stringify({
					"mitigation_strength": shader_parameters.get("mitigation_strength", null),
					"mitigation_enabled_signal": shader_parameters.get("mitigation_enabled_signal", null),
					"correction_mix_alpha": shader_parameters.get("correction_mix_alpha", null),
					"temporal_projection_strength": shader_parameters.get("temporal_projection_strength", null),
					"luminance_delta_limit": shader_parameters.get("luminance_delta_limit", null),
					"solver_correction_scale": shader_parameters.get("solver_correction_scale", null),
				})
			])

		var clean_after_output_image: Image = _read_texture_image(_after_output_texture(pipeline))
		if clean_after_output_image == null:
			_failed = true
			continue
		var raw_frame_path := raw_dir.path_join("frame_%06d.png" % [out_index + 1])
		var after_frame_path := after_dir.path_join("frame_%06d.png" % [out_index + 1])
		var visible_after_frame_path := visible_after_dir.path_join("frame_%06d.png" % [out_index + 1]) if _save_visible_after_output else ""
		_save_png(_read_texture_image(pipeline.source_texture), raw_frame_path)
		var measured_after: Dictionary
		if _should_measure_game_budget_after(out_index, last_after_sample_frame, last_measured_after, runtime_metrics):
			measured_after = _measure_visible_after_frame(
				solver_after_gpu,
				solver_after_analyzer,
				_after_measurement_texture(pipeline),
				clean_after_output_image,
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

		_apply_after_output_metrics(runtime_metrics, measured_after)
		_refresh_visible_after_overlay(pipeline, shader_parameters, runtime_metrics)
		if not _save_after_outputs(pipeline, clean_after_output_image, after_frame_path, visible_after_frame_path):
			continue
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

	var cases := [
		_case_manifest("pokemon_shock_raw", "pokemon_private_raw", raw_dir, raw_csv_path, output_frames, true),
		_case_manifest("pokemon_shock_after", "pokemon_private_after", after_dir, after_csv_path, output_frames, false),
	]
	if _save_visible_after_output and not visible_after_dir.is_empty():
		cases.append(_case_manifest("pokemon_shock_visible_after", "pokemon_private_visible_after", visible_after_dir, "", output_frames, false))

	return {
		"schema": "quell-mitigated-frame-export-v1",
		"measurement_backend": "saved-after-frame-sequence-detection-input",
		"local_correction_enabled": analyzer.local_correction_enabled,
		"current_frame_solver_enabled": _current_frame_solver_enabled,
		"game_budget_enabled": _game_budget_enabled,
		"game_budget_skip_raw_risk": _game_budget_skip_raw_risk,
		"game_budget_policy": _game_budget_policy,
		"game_budget_policy_label": _game_budget_policy_label(),
		"game_budget_projection_mode": _game_budget_projection_mode,
		"game_budget_projection_label": _game_budget_projection_label(),
		"runtime_backend": "native" if _native_enabled else "gdscript",
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
		"solver_bisection_steps": _solver_bisection_steps,
		"visible_after_output_saved": _save_visible_after_output,
		"summary": {
			"max_raw_risk": snapped(max_raw_risk, 0.001),
			"max_after_risk": snapped(max_after_risk, 0.001),
			"after_target_passed": max_after_risk <= DEFAULT_TARGET_RISK + 0.005,
			"after_over_target_frames": after_over_target_frames,
			"max_after_luminance": snapped(max_after_luminance, 0.001),
			"max_after_red": snapped(max_after_red, 0.001),
			"max_after_spatial": snapped(max_after_spatial, 0.001),
		},
		"cases": cases,
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
		elif arg == "--game-budget-legacy" or arg == "--quell-game-budget-legacy" or arg == "--game-budget-old" or arg == "--quell-game-budget-old":
			_game_budget_enabled = true
			_current_frame_solver_enabled = true
			_game_budget_projection_mode = GAME_BUDGET_PROJECTION_LEGACY
		elif arg == "--game-budget-closed-form" or arg == "--quell-game-budget-closed-form" or arg == "--game-budget-projection-closed-form" or arg == "--quell-game-budget-projection-closed-form":
			_game_budget_enabled = true
			_current_frame_solver_enabled = true
			_game_budget_projection_mode = GAME_BUDGET_PROJECTION_CLOSED_FORM
		elif arg == "--game-budget-skip-raw-risk" or arg == "--quell-game-budget-skip-raw-risk" or arg == "--game-budget-control-only" or arg == "--quell-game-budget-control-only":
			_game_budget_enabled = true
			_game_budget_skip_raw_risk = true
			_current_frame_solver_enabled = true
		elif arg.begins_with("--game-budget-policy=") or arg.begins_with("--quell-game-budget-policy="):
			_game_budget_enabled = true
			_current_frame_solver_enabled = true
			_game_budget_policy = _parse_game_budget_policy(arg.get_slice("=", 1))
		elif arg.begins_with("--game-budget-projection=") or arg.begins_with("--quell-game-budget-projection=") or arg.begins_with("--game-budget-solver=") or arg.begins_with("--quell-game-budget-solver="):
			_game_budget_enabled = true
			_current_frame_solver_enabled = true
			_game_budget_projection_mode = _parse_game_budget_projection_mode(arg.get_slice("=", 1))
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
		elif arg == "--native":
			_native_enabled = true
		elif arg == "--no-native":
			_native_enabled = false
		elif arg == "--hard-projection" or arg == "--hard-constrained-projection":
			_hard_projection_enabled = true
		elif arg == "--oracle-projection":
			_oracle_projection_enabled = true
		elif arg == "--regional-luminance" or arg == "--regional-luma":
			_regional_luminance = true
		elif arg.begins_with("--lookahead="):
			_lookahead = maxi(0, int(arg.trim_prefix("--lookahead=")))
			_regional_luminance = true
		elif arg == "--lowpass" or arg == "--mitigation-style=lowpass":
			_mitigation_style = "lowpass"
		elif arg == "--rise-cap" or arg == "--mitigation-style=risecap":
			_mitigation_style = "risecap"
		elif arg == "--save-visible-after" or arg == "--visible-after-output" or arg == "--record-visible-output":
			_save_visible_after_output = true
		elif arg == "--solver-fast-identity":
			_solver_fast_identity = 1
		elif arg == "--no-solver-fast-identity":
			_solver_fast_identity = 0
		elif arg.begins_with("--solver-bisection=") or arg.begins_with("--solver-bisection-steps="):
			_solver_bisection_steps = maxi(0, int(arg.get_slice("=", 1)))
		elif arg.begins_with("--debug-preview-frame="):
			_debug_preview_frame = maxi(1, int(arg.get_slice("=", 1)))
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

func _make_analyzer():
	if _native_enabled:
		var analyzer = NativeBridgeClass.instantiate_native_analyzer()
		if analyzer == null:
			push_error("QuellNativeAnalyzer is unavailable")
		return analyzer
	return RuntimeAnalyzerClass.new()

func _make_gpu_analyzer():
	if _native_enabled:
		var analyzer = NativeBridgeClass.instantiate_native_gpu_analyzer()
		if analyzer == null:
			push_error("QuellNativeGpuAnalyzer is unavailable")
		return analyzer
	return GpuAnalyzerClass.new()

func _make_frame_pipeline():
	if _native_enabled:
		var pipeline = NativeBridgeClass.instantiate_native_gpu_frame_pipeline()
		if pipeline == null:
			push_error("QuellNativeGpuFramePipeline is unavailable")
		return pipeline
	return FramePipelineClass.new()

func _make_current_frame_solver():
	if _native_enabled:
		var solver = NativeBridgeClass.instantiate_native_current_frame_solver()
		if solver == null:
			push_error("QuellNativeCurrentFrameSolver is unavailable")
		return solver
	return CurrentFrameSolverClass.new()

func _parse_game_budget_policy(value: String) -> int:
	var normalized := value.to_lower()
	if normalized == "atf" or normalized == "adaptive" or normalized == "adaptive_temporal_filter":
		return RuntimeAnalyzerClass.GameBudgetPolicy.ADAPTIVE_TEMPORAL_FILTER
	return RuntimeAnalyzerClass.GameBudgetPolicy.DIRECT_BRIGHTNESS

func _parse_game_budget_projection_mode(value: String) -> int:
	var normalized := value.to_lower().replace("-", "_")
	if normalized == "legacy" or normalized == "old" or normalized == "previous":
		return GAME_BUDGET_PROJECTION_LEGACY
	return GAME_BUDGET_PROJECTION_CLOSED_FORM

func _game_budget_policy_label() -> String:
	if _game_budget_policy == RuntimeAnalyzerClass.GameBudgetPolicy.ADAPTIVE_TEMPORAL_FILTER:
		return "atf"
	return "direct"

func _game_budget_projection_label() -> String:
	if _game_budget_projection_mode == GAME_BUDGET_PROJECTION_LEGACY:
		return "legacy"
	return "closed-form"

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

func _after_output_texture(pipeline) -> Texture2DRD:
	if _object_has_property(pipeline, "mitigated_after_texture"):
		var texture = pipeline.mitigated_after_texture
		if texture != null:
			return texture
	return pipeline.after_texture

func _after_measurement_texture(pipeline) -> Texture2DRD:
	if pipeline != null and pipeline.analysis_after_texture != null:
		return pipeline.analysis_after_texture
	return _after_output_texture(pipeline)

func _visible_after_texture(pipeline) -> Texture2DRD:
	if pipeline != null and _object_has_property(pipeline, "after_texture"):
		var texture = pipeline.after_texture
		if texture != null:
			return texture
	return _after_output_texture(pipeline)

func _visible_after_risk_for_metrics(metrics: Dictionary, after_metrics: Dictionary) -> float:
	var measured_risk: float = float(after_metrics.get("raw_risk", 0.0))
	if _game_budget_enabled and bool(after_metrics.get("measurement_skipped", false)):
		return float(after_metrics.get("estimated_raw_risk", measured_risk))
	return measured_risk

func _apply_after_output_metrics(metrics: Dictionary, after_metrics: Dictionary) -> void:
	var raw_risk: float = float(metrics.get("raw_risk", 0.0))
	var output_risk: float = _visible_after_risk_for_metrics(metrics, after_metrics)
	var risk_reduction: float = max(0.0, raw_risk - output_risk)
	metrics["output_risk"] = output_risk
	metrics["risk_reduction"] = risk_reduction
	metrics["reduction_ratio"] = risk_reduction / max(raw_risk, 0.001)

func _apply_overlay_metrics_to_shader_parameters(parameters: Dictionary, metrics: Dictionary, output_risk: float) -> void:
	parameters["raw_risk_for_overlay"] = clamp(float(metrics.get("raw_risk", 0.0)), 0.0, 1.50)
	parameters["output_risk_for_overlay"] = clamp(output_risk, 0.0, 1.50)
	parameters["target_risk_for_overlay"] = DEFAULT_TARGET_RISK
	parameters["time_for_overlay"] = float(metrics.get("time", 0.0))

func _refresh_visible_after_overlay(pipeline, shader_parameters: Dictionary, metrics: Dictionary) -> void:
	if pipeline == null or shader_parameters.is_empty():
		return
	var output_risk: float = float(metrics.get("output_risk", metrics.get("solver_after_risk", metrics.get("raw_risk", 0.0))))
	_apply_overlay_metrics_to_shader_parameters(shader_parameters, metrics, output_risk)
	if pipeline.has_method("refresh_developer_alpha_overlay"):
		pipeline.refresh_developer_alpha_overlay(shader_parameters)

func _save_after_outputs(pipeline, clean_after_image: Image, clean_after_path: String, visible_after_path: String) -> bool:
	if not _save_png(clean_after_image, clean_after_path):
		return false
	if visible_after_path.is_empty():
		return true
	var visible_after_image: Image = _read_texture_image(_visible_after_texture(pipeline))
	return _save_png(visible_after_image, visible_after_path)

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
		if after_analyzer.has_method("apply_spatial_image_override"):
			after_analyzer.apply_spatial_image_override(after_gpu_metrics, after_image)
		else:
			# The native analyzer has no port of the reference spatial detector
			# yet, so without this the score silently falls back to the runtime
			# GPU edge heuristic (documented as unreliable in issue #1). The
			# gate must score spatial with the reference-grade detector.
			_apply_reference_spatial_override(after_gpu_metrics, after_image)
	return after_analyzer.update_from_metrics(after_gpu_metrics, delta, time_seconds)

var _spatial_reference_override = null

# Mirrors quell_analyzer.apply_spatial_image_override using the offline
# reference detector (quell_spatial_reference.gd) on a downscaled copy: the
# reference's projections bin to <= 192 columns anyway, and stripe hazards at
# the >5 light-dark-pair scale (ITU-BT1702 / EFA-2005) survive 192-wide
# sampling, so this keeps the saved-frame re-analysis affordable.
func _apply_reference_spatial_override(metrics: Dictionary, image: Image) -> void:
	if _spatial_reference_override == null:
		_spatial_reference_override = SpatialReferenceClass.new()
	var sample := image
	if image.get_width() > 192:
		sample = image.duplicate()
		var sample_height := maxi(16, int(round(192.0 * float(image.get_height()) / float(maxi(1, image.get_width())))))
		sample.resize(192, sample_height, Image.INTERPOLATE_BILINEAR)
	var spatial_metrics: Dictionary = _spatial_reference_override.analyze_image(sample)
	metrics["spatial"] = clampf(float(spatial_metrics.get("risk", 0.0)), 0.0, 1.35)
	metrics["spatial_pattern_area"] = float(spatial_metrics.get("area", 0.0))
	metrics["spatial_pattern_pairs"] = float(spatial_metrics.get("pairs", 0.0))
	metrics["spatial_pattern_regularity"] = float(spatial_metrics.get("regularity", 0.0))
	metrics["spatial_backend"] = "cpu-regularity-reference"

func _restore_debug_analyzer_state(analyzer, state: Dictionary) -> void:
	if analyzer != null and not state.is_empty() and analyzer.has_method("restore_runtime_state"):
		analyzer.restore_runtime_state(state)

func _image_diff_summary(a: Image, b: Image) -> Dictionary:
	if a == null or b == null or a.is_empty() or b.is_empty():
		return {"diff_pixels": -1, "max_channel_delta": -1, "mean_channel_delta": -1.0}
	if a.get_width() != b.get_width() or a.get_height() != b.get_height():
		return {"diff_pixels": -1, "max_channel_delta": -1, "mean_channel_delta": -1.0}
	if a.get_format() != Image.FORMAT_RGBA8:
		a = a.duplicate()
		a.convert(Image.FORMAT_RGBA8)
	if b.get_format() != Image.FORMAT_RGBA8:
		b = b.duplicate()
		b.convert(Image.FORMAT_RGBA8)
	var ad := a.get_data()
	var bd := b.get_data()
	if ad.size() != bd.size():
		return {"diff_pixels": -1, "max_channel_delta": -1, "mean_channel_delta": -1.0}
	var diff_pixels := 0
	var max_delta := 0
	var total_delta := 0
	for i in range(0, ad.size(), 4):
		var pixel_diff := false
		for c in range(4):
			var delta := absi(int(ad[i + c]) - int(bd[i + c]))
			if delta > 0:
				pixel_diff = true
				total_delta += delta
				max_delta = maxi(max_delta, delta)
		if pixel_diff:
			diff_pixels += 1
	return {
		"diff_pixels": diff_pixels,
		"max_channel_delta": max_delta,
		"mean_channel_delta": float(total_delta) / float(maxi(1, ad.size())),
	}

func _measure_saved_after_sequence(after_dir: String, after_csv_path: String) -> Dictionary:
	var frame_paths := _frame_paths(after_dir)
	var pipeline = _make_frame_pipeline()
	var after_gpu = _make_gpu_analyzer()
	var after_analyzer = _make_analyzer()
	if pipeline == null or after_gpu == null or after_analyzer == null:
		_failed = true
		return {}
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
		float(raw_metrics.get("current_raw_detector_risk", 0.0)),
		float(raw_metrics.get("output_risk", raw_metrics.get("solver_after_risk", 0.0))),
		float(raw_metrics.get("previous_after_risk", raw_metrics.get("last_after_risk", -1.0))),
		float(raw_metrics.get("temporal_raw_after_activity", 0.0)),
		float(raw_metrics.get("temporal_after_pressure", 0.0)),
		float(raw_metrics.get("current_frame_after_budget_guard_activity", 0.0)),
		float(raw_metrics.get("temporal_source_activity", 0.0)),
		float(raw_metrics.get("temporal_after_activity", 0.0)),
		float(raw_metrics.get("temporal_after_feedback_activity", 0.0)),
		float(raw_metrics.get("red_current_area", raw_metrics.get("red_saturation_area", 0.0))),
		float(raw_metrics.get("current_high_luminance_area", 0.0)),
		float(raw_metrics.get("frame_luminance_contrast", raw_metrics.get("luminance_contrast", 0.0))),
		float(raw_metrics.get("temporal_luminance_contrast", 0.0)),
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
