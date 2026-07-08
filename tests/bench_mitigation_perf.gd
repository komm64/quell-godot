extends Node

# Amplification benchmark for the GPU mitigation pass (mode 3 = temporal low-pass).
# The pipeline uses the MAIN RenderingDevice, so per-dispatch CPU timing is not the
# GPU cost. Instead we dispatch the mitigation K times per frame with vsync off and
# read the average frame time; per-dispatch GPU cost = (t_K - t_0) / K. Run with a
# real window (GPU): godot --path <proj> res://tests/bench_mitigation_perf.tscn

const NativeBridgeClass = preload("res://addons/quell_core/runtime/quell_native_bridge.gd")
const GpuAnalyzerClass = preload("res://addons/quell_core/runtime/quell_gpu_analyzer.gd")

var _pipeline
var _analyzer
var _params: Dictionary
var _haz_rid: RID
var _size := Vector2i(1920, 1080)

# Config sweep: "mitigate" (mode-3 pass only) then "both" (analyze + mitigate =
# full per-frame Quell cost). analyze cost = both - mitigate.
var _configs := ["mitigate", "both"]
var _config := 0
var _k_stages := [0, 50, 100, 200]
var _stage := 0
var _k := 0
var _warmup := 20
var _frame := 0
var _samples: Array = []
var _results: Array = []
var _config_results: Dictionary = {}

func _ready() -> void:
	_pipeline = NativeBridgeClass.instantiate_native_gpu_frame_pipeline()
	if _pipeline == null:
		push_error("pipeline unavailable"); get_tree().quit(1); return
	if not _pipeline.configure(_size, Vector2i(_size.x / 5, _size.y / 5)):
		push_error("configure failed"); get_tree().quit(1); return
	# Source: a mid-detail gradient (content does not change per-pixel compute cost).
	var src := Image.create(_size.x, _size.y, false, Image.FORMAT_RGBA8)
	for y in range(0, _size.y, 4):
		for x in range(0, _size.x, 4):
			src.set_pixel(x, y, Color(float(x) / _size.x, float(y) / _size.y, 0.5))
	_pipeline.upload_source_image(src, false)
	# Hazard map (16x9) fully hot so the red cap path also runs.
	var hb := PackedByteArray(); hb.resize(16 * 9); hb.fill(255)
	var haz := Image.create_from_data(16, 9, false, Image.FORMAT_R8, hb)
	_haz_rid = _pipeline.upload_hazard_map(haz)
	_params = {
		"mitigation_mode": 3, "mitigation_style": 1.0,
		"general_transition_area": 0.5, "target_risk": 0.8, "safety_margin": 0.9,
	}
	_analyzer = GpuAnalyzerClass.new()
	if not _analyzer.is_ready():
		push_error("analyzer not ready"); get_tree().quit(1); return
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_k = _k_stages[0]
	print("bench start: %dx%d, %d pixels; analysis %dx%d" % [_size.x, _size.y, _size.x * _size.y, _size.x / 5, _size.y / 5])

func _process(delta: float) -> void:
	_frame += 1
	if _frame > _warmup:
		_samples.append(delta)
	var cfg: String = _configs[_config]
	var analyze: bool = cfg == "both"
	var haz_rid: RID = _haz_rid
	for i in range(_k):
		if analyze:
			_analyzer.analyze_current_signals(_pipeline.analysis_source_texture, 0.0)
			var h = _analyzer.hazard_texture
			if h != null and h.texture_rd_rid.is_valid():
				haz_rid = h.texture_rd_rid
		_pipeline.apply_mitigation(_params, haz_rid)
	if _samples.size() >= 150:
		_samples.sort()
		var mid := _samples.slice(int(_samples.size() * 0.25), int(_samples.size() * 0.75))
		var avg := 0.0
		for s in mid:
			avg += s
		avg /= float(mid.size())
		_results.append([_k, avg])
		print("[%s] K=%d : frame %.3f ms" % [cfg, _k, avg * 1000.0])
		_stage += 1
		_samples.clear(); _frame = 0
		if _stage >= _k_stages.size():
			_config_results[cfg] = _report(cfg)
			_config += 1
			_stage = 0
			_results = []
			if _config >= _configs.size():
				_summary(); get_tree().quit(0); return
			_k = _k_stages[0]
			return
		_k = _k_stages[_stage]

func _report(cfg: String) -> float:
	var t0 := 0.0
	for r in _results:
		if r[0] == 0:
			t0 = r[1]
	var best := 0.0
	print("--- [%s] per-op cost ---" % cfg)
	for r in _results:
		if r[0] == 0:
			continue
		var per_ms: float = (float(r[1]) - t0) / float(r[0]) * 1000.0
		print("  from K=%d : %.4f ms" % [r[0], per_ms])
		best = per_ms  # last (highest K = most saturated) is the cleanest
	return best

func _summary() -> void:
	var mit: float = _config_results.get("mitigate", 0.0)
	var both: float = _config_results.get("both", 0.0)
	print("\n=== Full Quell per-frame GPU cost (%dx%d, RTX 2060) ===" % [_size.x, _size.y])
	print("  mitigate (mode 3 lowpass)  : %.3f ms" % mit)
	print("  analyze (transition+hazard): %.3f ms" % (both - mit))
	print("  TOTAL analyze+mitigate     : %.3f ms  (budget 1.0 ms)" % both)
