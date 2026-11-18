extends RefCounted

# Local, untracked data (benchmark clip, exports, reports). With QUELL_DATA_DIR
# set, it lives in $QUELL_DATA_DIR/quell-godot; otherwise in the gitignored
# res://validation/private. Plain directories only: no links into this tree.
#
# Optional <data dir>/benchmark.json:
# {
#   "id": "my_clip",                     # manifest case ids: <id>_raw / <id>_after
#   "group": "my_clip_private",          # manifest group prefix: <group>_raw / <group>_after
#   "name": "My clip (private)",
#   "frames_dir": "<absolute or res:// path>/frames",
#   "fps": 23.976
# }

const REPO_SUBDIR := "quell-godot"
const FALLBACK_DIR := "res://validation/private"
const BENCHMARK_DEFAULTS := {
	"id": "private_benchmark",
	"group": "private_benchmark",
	"name": "Private benchmark clip",
	"frames_dir": "",
	"fps": 1199.0 / 50.0,
}

static func data_dir() -> String:
	var root := OS.get_environment("QUELL_DATA_DIR")
	if root == "":
		return FALLBACK_DIR
	return root.replace("\\", "/").path_join(REPO_SUBDIR)

static func path(relative: String) -> String:
	return data_dir().path_join(relative)

static func load_benchmark() -> Dictionary:
	var config := BENCHMARK_DEFAULTS.duplicate()
	config["frames_dir"] = path("benchmark/frames")
	var config_path := path("benchmark.json")
	if FileAccess.file_exists(config_path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(config_path))
		if parsed is Dictionary:
			for key in BENCHMARK_DEFAULTS.keys():
				if parsed.has(key):
					config[key] = parsed[key]
	config["fps"] = float(config["fps"])
	return config

# Frame sequences produced by tools/import_core_tmp_videos.py.
static func sample_frames_dir() -> String:
	if OS.get_environment("QUELL_DATA_DIR") != "":
		return path("sample-frames")
	return _core_dir().path_join(".tmp/quell-godot-sample-frames")

# Sibling quell-core checkout: QUELL_CORE_DIR, else ../quell-core next to this project.
static func _core_dir() -> String:
	var from_env := OS.get_environment("QUELL_CORE_DIR")
	if from_env != "":
		return from_env.replace("\\", "/")
	return ProjectSettings.globalize_path("res://").path_join("../quell-core").simplify_path()
