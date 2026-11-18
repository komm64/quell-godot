extends RefCounted

# Local benchmark clip description. Clip identity and locations are kept out of
# the public tree: an optional, gitignored `validation/private/benchmark.json`
# overrides these generic defaults.
#
# {
#   "id": "my_clip",                     # manifest case ids: <id>_raw / <id>_after
#   "group": "my_clip_private",          # manifest group prefix: <group>_raw / <group>_after
#   "name": "My clip (private)",
#   "frames_dir": "res://validation/private/<clip>/frames",
#   "fps": 23.976
# }

const CONFIG_PATH := "res://validation/private/benchmark.json"
const DEFAULTS := {
	"id": "private_benchmark",
	"group": "private_benchmark",
	"name": "Private benchmark clip",
	"frames_dir": "res://validation/private/benchmark/frames",
	"fps": 1199.0 / 50.0,
}

static func load_config() -> Dictionary:
	var config := DEFAULTS.duplicate()
	if not FileAccess.file_exists(CONFIG_PATH):
		return config
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if parsed is Dictionary:
		for key in DEFAULTS.keys():
			if parsed.has(key):
				config[key] = parsed[key]
	config["fps"] = float(config["fps"])
	return config

# Sibling quell-core checkout: QUELL_CORE_DIR, else ../quell-core next to this project.
static func core_dir() -> String:
	var from_env := OS.get_environment("QUELL_CORE_DIR")
	if from_env != "":
		return from_env.replace("\\", "/")
	return ProjectSettings.globalize_path("res://").path_join("../quell-core").simplify_path()
