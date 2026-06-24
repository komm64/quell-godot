extends SceneTree

const AnalyzerClass = preload("res://addons/quell_core/runtime/quell_analyzer.gd")
const GpuAnalyzerClass = preload("res://addons/quell_core/runtime/quell_gpu_analyzer.gd")
const FramePipelineClass = preload("res://addons/quell_core/runtime/quell_gpu_frame_pipeline.gd")

const CSV_HEADER := "Frame,TimeSeconds,QuellLuminance,QuellRed,QuellSpatial,QuellRawRisk,GeneralFlashCount,RedFlashCount,GeneralFlashArea,RedFlashArea,RedSaturationArea,FrameLuminanceContrast,TemporalLuminanceContrast"

var _input_dir: String = ""
var _output_path: String = "validation/private/mitigation/frame-sequence-gpu-analysis.json"
var _csv_path: String = "validation/private/mitigation/frame-sequence-gpu-analysis.csv"
var _fps: float = 30.0
var _display_size := Vector2i(1280, 960)
var _analysis_size := Vector2i(320, 240)
var _max_frames: int = 0
var _failed: bool = false

func _init() -> void:
	_parse_args()
	if DisplayServer.get_name() == "headless":
		_fail("GPU frame sequence analysis requires a RenderingDevice renderer")
		quit(1)
		return
	if _input_dir.is_empty():
		_fail("--input is required")
		quit(1)
		return

	var input_abs: String = _absolute_path(_input_dir)
	var frames: PackedStringArray = _frame_paths(input_abs)
	if frames.is_empty():
		_fail("No frame_*.png files found: %s" % input_abs)
		quit(1)
		return

	var report: Dictionary = _measure_frames(frames)
	_write_json(_output_path, report)
	print(JSON.stringify(report, "\t"))
	quit(1 if _failed else 0)

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--input="):
			_input_dir = arg.trim_prefix("--input=")
		elif arg.begins_with("--output="):
			_output_path = arg.trim_prefix("--output=")
		elif arg.begins_with("--csv="):
			_csv_path = arg.trim_prefix("--csv=")
		elif arg.begins_with("--fps="):
			_fps = max(1.0, float(arg.trim_prefix("--fps=")))
		elif arg.begins_with("--display="):
			_display_size = _parse_size(arg.trim_prefix("--display="), _display_size)
		elif arg.begins_with("--analysis="):
			_analysis_size = _parse_size(arg.trim_prefix("--analysis="), _analysis_size)
		elif arg.begins_with("--max-frames="):
			_max_frames = maxi(0, int(arg.trim_prefix("--max-frames=")))

func _measure_frames(frames: PackedStringArray) -> Dictionary:
	var pipeline = FramePipelineClass.new()
	var gpu = GpuAnalyzerClass.new()
	var analyzer = AnalyzerClass.new()
	analyzer.mitigation_enabled = false
	analyzer.local_correction_enabled = true
	analyzer.spatial_sensitivity = AnalyzerClass.SpatialSensitivity.BALANCED

	if not pipeline.configure(_display_size, _analysis_size):
		_fail("Failed to configure GPU frame pipeline")
		return {}
	if not gpu.is_ready():
		_fail("Failed to initialize GPU analyzer")
		return {}

	var output_abs: String = _absolute_path(_csv_path)
	_make_parent_dir(output_abs)
	var csv := FileAccess.open(output_abs, FileAccess.WRITE)
	if csv == null:
		_fail("Could not write CSV: %s" % output_abs)
		return {}
	csv.store_line(CSV_HEADER)

	var frame_limit: int = frames.size()
	if _max_frames > 0:
		frame_limit = mini(frame_limit, _max_frames)
	var max_metrics: Dictionary = _empty_max_metrics()
	var first_over_target_frame: int = -1
	var over_target_frames: int = 0
	var samples: Array[Dictionary] = []

	for frame_index in range(frame_limit):
		var image := Image.new()
		var load_error: Error = image.load(String(frames[frame_index]))
		if load_error != OK:
			_fail("Could not load frame %s: %s" % [frames[frame_index], error_string(load_error)])
			continue
		if image.get_format() != Image.FORMAT_RGBA8:
			image.convert(Image.FORMAT_RGBA8)
		if not pipeline.upload_source_image(image, true):
			_fail("Could not upload frame %s" % frames[frame_index])
			continue

		var time_seconds: float = float(frame_index) / _fps
		var metrics: Dictionary = gpu.analyze_texture(pipeline.analysis_source_texture, time_seconds)
		metrics["source_kind"] = "frame_sequence"
		analyzer.apply_spatial_image_override(metrics, image)
		var measured: Dictionary = analyzer.update_from_metrics(metrics, 1.0 / _fps, time_seconds)
		_accumulate_max(max_metrics, measured)
		csv.store_line(_metrics_csv_row(frame_index + 1, time_seconds, measured))

		var raw_risk: float = float(measured.get("raw_risk", 0.0))
		if raw_risk > analyzer.headroom_margin:
			over_target_frames += 1
			if first_over_target_frame < 0:
				first_over_target_frame = frame_index + 1
		if samples.size() < 20 or raw_risk > analyzer.headroom_margin:
			samples.append({
				"frame": frame_index + 1,
				"time": snapped(time_seconds, 0.001),
				"raw_risk": snapped(raw_risk, 0.001),
				"luminance": snapped(float(measured.get("luminance", 0.0)), 0.001),
				"red": snapped(float(measured.get("red", 0.0)), 0.001),
				"spatial": snapped(float(measured.get("spatial", 0.0)), 0.001),
				"general_flash_count": int(measured.get("general_flash_count", 0)),
			})

	csv.close()
	gpu.dispose()
	pipeline.dispose()

	return {
		"schema": "quell-frame-sequence-gpu-analysis-v1",
		"input_dir": _absolute_path(_input_dir),
		"csv": output_abs,
		"fps": _fps,
		"display_size": "%dx%d" % [_display_size.x, _display_size.y],
		"analysis_size": "%dx%d" % [_analysis_size.x, _analysis_size.y],
		"frame_count": frame_limit,
		"over_target_frames": over_target_frames,
		"first_over_target_frame": first_over_target_frame,
		"max": _rounded_metrics(max_metrics),
		"samples": samples,
	}

func _frame_paths(input_abs: String) -> PackedStringArray:
	var paths := PackedStringArray()
	var dir := DirAccess.open(input_abs)
	if dir == null:
		return paths
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.begins_with("frame_") and file_name.ends_with(".png"):
			paths.append(input_abs.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	return paths

func _empty_max_metrics() -> Dictionary:
	return {
		"raw_risk": 0.0,
		"luminance": 0.0,
		"red": 0.0,
		"spatial": 0.0,
		"general_flash_area": 0.0,
		"red_flash_area": 0.0,
		"general_flash_count": 0,
		"red_flash_count": 0,
		"luminance_contrast": 0.0,
		"frame_luminance_contrast": 0.0,
		"temporal_luminance_contrast": 0.0,
	}

func _accumulate_max(target: Dictionary, metrics: Dictionary) -> void:
	for key in target.keys():
		target[key] = max(float(target[key]), float(metrics.get(key, 0.0)))

func _rounded_metrics(metrics: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in metrics.keys():
		if String(key).ends_with("_count"):
			result[key] = int(metrics[key])
		else:
			result[key] = snapped(float(metrics[key]), 0.001)
	return result

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
		float(metrics.get("red_saturation_area", 0.0)),
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

func _parse_size(text: String, fallback: Vector2i) -> Vector2i:
	var parts := text.split("x", false)
	if parts.size() != 2:
		return fallback
	return Vector2i(maxi(1, int(parts[0])), maxi(1, int(parts[1])))

func _write_json(path: String, payload: Dictionary) -> void:
	var absolute: String = _absolute_path(path)
	_make_parent_dir(absolute)
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		_fail("Could not write JSON: %s" % absolute)
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()

func _make_parent_dir(path: String) -> void:
	var error: Error = DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error != OK:
		_fail("Could not create directory %s: %s" % [path.get_base_dir(), error_string(error)])

func _absolute_path(path: String) -> String:
	if path.begins_with("res://"):
		return ProjectSettings.globalize_path("res://").path_join(path.trim_prefix("res://")).simplify_path()
	if path.length() >= 3 and (path.substr(1, 2) == ":/" or path.substr(1, 2) == ":\\"):
		return path.simplify_path()
	if path.begins_with("/") or path.begins_with("\\\\"):
		return path.simplify_path()
	var cwd: String = OS.get_environment("PWD")
	if cwd.is_empty():
		cwd = ProjectSettings.globalize_path("res://../..")
	return cwd.path_join(path).simplify_path()

func _fail(message: String) -> void:
	_failed = true
	push_error(message)
