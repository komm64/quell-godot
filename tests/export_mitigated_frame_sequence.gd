extends SceneTree

const RuntimeAnalyzerClass = preload("res://addons/quell_core/runtime/quell_analyzer.gd")
const GpuAnalyzerClass = preload("res://addons/quell_core/runtime/quell_gpu_analyzer.gd")
const FramePipelineClass = preload("res://addons/quell_core/runtime/quell_gpu_frame_pipeline.gd")
const NativeBridgeClass = preload("res://addons/quell_core/runtime/quell_native_bridge.gd")
const ProjectionReferenceClass = preload("res://addons/quell_core/runtime/quell_projection_reference.gd")
const SpatialReferenceClass = preload("res://addons/quell_core/runtime/quell_spatial_reference.gd")

const CSV_HEADER := "Frame,TimeSeconds,QuellLuminance,QuellRed,QuellSpatial,QuellRawRisk,GeneralFlashCount,RedFlashCount,GeneralFlashArea,RedFlashArea,RedSaturationArea,FrameLuminanceContrast,TemporalLuminanceContrast"
const DEFAULT_INPUT_DIR := "res://validation/private/demo-videos/pokemon-shock/frames"
const DEFAULT_OUTPUT_DIR := "res://validation/private/mitigation/pokemon-shock-quell-after"
const DEFAULT_SOURCE_FPS := 1199.0 / 50.0
const DEFAULT_OUTPUT_FPS := 30.0
const DEFAULT_DISPLAY_SIZE := Vector2i(1280, 720)
const DEFAULT_ANALYSIS_SIZE := Vector2i(256, 144)
const DEFAULT_TARGET_RISK := 0.80

var _input_dir := DEFAULT_INPUT_DIR
var _output_dir := DEFAULT_OUTPUT_DIR
var _source_fps := DEFAULT_SOURCE_FPS
var _output_fps := DEFAULT_OUTPUT_FPS
var _display_size := DEFAULT_DISPLAY_SIZE
var _analysis_size := DEFAULT_ANALYSIS_SIZE
var _raw_spatial_override_enabled := true
var _after_spatial_override_enabled := true
var _match_source_size := false
var _max_seconds := 0.0
var _max_frames := 0
var _native_enabled := false
var _hard_projection_enabled := false
var _oracle_projection_enabled := false
# Oracle mitigation style: "risecap" (sharp/dark, default) or "lowpass" (bright glow).
var _mitigation_style := "lowpass"
var _regional_luminance := false
var _lookahead := 0   # buffered-analysis depth (frames) for regional luminance
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
		_analysis_size = _display_size

	var manifest := _export_frames(frame_paths, raw_dir, after_dir, output_abs)
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
	# CONTENT MASK: the letterbox/pillarbox bars are constant black. A tile that is
	# near-black in EVERY frame is a bar (never flashes, needs no mitigation); the
	# problem it causes is the blur bleeding its 0-hazard into the adjacent content
	# tiles, softening the gate at the content edge and leaking a boundary
	# transition. Flag content tiles (bright in some frame) so the blur ignores bar
	# tiles as neighbours and the content edge keeps its full hazard.
	const CONTENT_LUMA := 0.05
	var is_content := []
	is_content.resize(cols * rows)
	for t in range(cols * rows):
		is_content[t] = false
	for f in range(n):
		var la2: PackedFloat32Array = lumas[f]
		for y in range(H):
			var tr2 := (y / TS) * cols
			for x in range(W):
				if la2[y * W + x] > CONTENT_LUMA:
					is_content[tr2 + (x / TS)] = true
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
		hazards.append(_blur_tile_grid_masked(raw, cols, rows, is_content))
	return hazards

func _lin_luma(c: Color) -> float:
	return _srgb_lin(c.r) * 0.2126 + _srgb_lin(c.g) * 0.7152 + _srgb_lin(c.b) * 0.0722

func _srgb_lin(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)

# Separable box blur that averages ONLY over content tiles (see is_content): a
# content tile at the picture edge is not pulled toward the bars' 0 hazard, so its
# gate stays full and the boundary does not leak. Bar tiles keep their own value
# (unused — they are black, nothing to mitigate).
func _blur_tile_grid_masked(field: PackedFloat32Array, cols: int, rows: int, is_content: Array) -> PackedFloat32Array:
	if cols <= 1 and rows <= 1:
		return field
	var current := field.duplicate()
	for _pass in range(2):
		var horizontal := current.duplicate()
		for row in range(rows):
			for col in range(cols):
				if not is_content[row * cols + col]:
					continue
				var acc := 0.0
				var num := 0
				for dc in range(-1, 2):
					var cc := col + dc
					if cc < 0 or cc >= cols or not is_content[row * cols + cc]:
						continue
					acc += current[row * cols + cc]
					num += 1
				if num > 0:
					horizontal[row * cols + col] = acc / float(num)
		for row in range(rows):
			for col in range(cols):
				if not is_content[row * cols + col]:
					continue
				var acc := 0.0
				var num := 0
				for dr in range(-1, 2):
					var rr := row + dr
					if rr < 0 or rr >= rows or not is_content[rr * cols + col]:
						continue
					acc += horizontal[rr * cols + col]
					num += 1
				if num > 0:
					current[row * cols + col] = acc / float(num)
	return current

func _upload_oracle_hazard(pipeline, solver) -> RID:
	var cols: int = solver.get_hazard_cols()
	var rows: int = solver.get_hazard_rows()
	if cols <= 0 or rows <= 0:
		return RID()
	var field: PackedFloat32Array = solver.get_hazard_field()
	if field.size() < cols * rows:
		return RID()
	var bytes := PackedByteArray()
	bytes.resize(cols * rows)
	for i in range(cols * rows):
		bytes[i] = clampi(int(field[i] * 255.0), 0, 255)
	var img := Image.create_from_data(cols, rows, false, Image.FORMAT_R8, bytes)
	return pipeline.upload_hazard_map(img)

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
	solver.mitigation_style = ProjectionReferenceClass.STYLE_TEMPORAL_LOWPASS if _mitigation_style == "lowpass" else ProjectionReferenceClass.STYLE_RISE_CAP
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
			"mitigation_style": float(solver.mitigation_style),
			"general_transition_area": float(solver.last_solution.get("raw_hazard_area", 0.0)),
			"target_risk": solver.target_risk,
			"safety_margin": solver.safety_margin,
		}
		# Feed the oracle's regional hazard field to the GPU red cap so it caps red
		# only in flashing regions (mirrors _project_red), instead of greying all
		# saturated red as the absolute cap did.
		var haz_rid := _upload_oracle_hazard(pipeline, solver)
		pipeline.apply_mitigation(shader_parameters, haz_rid)
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

func _export_frames(frame_paths: PackedStringArray, raw_dir: String, after_dir: String, output_abs: String) -> Dictionary:
	# Hard constrained projection (mitigation_mode 3) is the only shipped path; the
	# oracle projection is the CPU shadow used to validate it. The legacy mode-0/1/2 +
	# game-budget export was removed in the unify-mitigation-path work.
	if _oracle_projection_enabled:
		return _export_frames_oracle_projection(frame_paths, raw_dir, after_dir, output_abs)
	return _export_frames_hard_projection(frame_paths, raw_dir, after_dir, output_abs)

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
		elif arg == "--match-source-size":
			_match_source_size = true
		elif arg == "--no-raw-spatial-override":
			_raw_spatial_override_enabled = false
		elif arg == "--no-after-spatial-override":
			_after_spatial_override_enabled = false
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

func _configure_after_measurement_analyzer(after_analyzer) -> void:
	after_analyzer.mitigation_enabled = false
	after_analyzer.local_correction_enabled = true
	after_analyzer.spatial_sensitivity = RuntimeAnalyzerClass.SpatialSensitivity.BALANCED

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
