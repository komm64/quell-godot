extends SceneTree

# Re-runs the CPU oracle over an already-exported raw frame sequence (the
# release-gate export's raw/ dir) and dumps the per-frame control series —
# most importantly the continuous enforcement envelope (= the HUD's
# "Mitigation strength"). The gate export itself only saves frames and
# detector metrics; this tool recovers the solver telemetry without
# re-running the GPU export. Solver configuration mirrors
# export_mitigated_frame_sequence.gd defaults (lowpass, target 0.80,
# 256x144 analysis, 30 fps).
#
# Usage:
#   godot --headless --path . --script res://tests/export_oracle_control_series.gd \
#       -- --frames-dir <dir with frame_*.png> --out <csv path> [--fps 30] [--source-fps 23.98]
#
# Without --source-fps the frames are assumed to already be at output cadence
# (an export's raw/ dir). With --source-fps the tool applies the export's
# source->output resample mapping (floor(t * source_fps)), which makes the run
# bit-exact against what the export solver saw when pointed at the original
# source frames.

const ProjectionReferenceClass = preload("res://addons/quell_core/runtime/quell_projection_reference.gd")

const DEFAULT_TARGET_RISK := 0.80
const DEFAULT_ANALYSIS_SIZE := Vector2i(256, 144)

func _init() -> void:
	var frames_dir := ""
	var out_path := ""
	var fps := 30.0
	var source_fps := 0.0
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--frames-dir":
				i += 1
				frames_dir = String(args[i])
			"--out":
				i += 1
				out_path = String(args[i])
			"--fps":
				i += 1
				fps = float(args[i])
			"--source-fps":
				i += 1
				source_fps = float(args[i])
		i += 1
	if frames_dir.is_empty() or out_path.is_empty():
		push_error("Usage: -- --frames-dir <dir> --out <csv> [--fps 30]")
		quit(1)
		return

	var frame_paths: Array[String] = []
	var dir := DirAccess.open(frames_dir)
	if dir == null:
		push_error("Cannot open frames dir: %s" % frames_dir)
		quit(1)
		return
	for file_name in dir.get_files():
		if file_name.begins_with("frame_") and file_name.ends_with(".png"):
			frame_paths.append(frames_dir.path_join(file_name))
	frame_paths.sort()
	if frame_paths.is_empty():
		push_error("No frame_*.png in %s" % frames_dir)
		quit(1)
		return

	var solver = ProjectionReferenceClass.new()
	solver.target_risk = DEFAULT_TARGET_RISK
	solver.mitigation_style = ProjectionReferenceClass.STYLE_TEMPORAL_LOWPASS
	solver.reset()

	var csv := FileAccess.open(out_path, FileAccess.WRITE)
	if csv == null:
		push_error("Cannot open output CSV: %s" % out_path)
		quit(1)
		return
	csv.store_line("Frame,TimeSeconds,Enforcement,Enforced,RawHazardArea")

	var output_count := frame_paths.size()
	if source_fps > 0.0:
		output_count = maxi(1, int(floor(float(frame_paths.size()) / source_fps * fps)))
	var cached_index := -1
	var cached_image: Image = null
	for out_index in range(output_count):
		var time_seconds := float(out_index) / fps
		var source_index := out_index
		if source_fps > 0.0:
			source_index = clampi(int(floor(time_seconds * source_fps)), 0, frame_paths.size() - 1)
		if source_index != cached_index:
			cached_image = Image.new()
			if cached_image.load(frame_paths[source_index]) != OK:
				push_error("Could not load %s" % frame_paths[source_index])
				quit(1)
				return
			if cached_image.get_format() != Image.FORMAT_RGBA8:
				cached_image.convert(Image.FORMAT_RGBA8)
			cached_index = source_index
		solver.step(_prepare_analysis_image(cached_image, DEFAULT_ANALYSIS_SIZE), time_seconds, 1.0 / fps)
		csv.store_line("%d,%f,%f,%d,%f" % [
			out_index + 1,
			time_seconds,
			float(solver.last_solution.get("enforcement", 0.0)),
			1 if bool(solver.last_solution.get("enforced", false)) else 0,
			float(solver.last_solution.get("raw_hazard_area", 0.0)),
		])
	csv.close()
	print("Wrote %d control rows to %s" % [output_count, out_path])
	quit(0)

# Mirrors export_mitigated_frame_sequence.gd (fit + letterbox on black).
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
