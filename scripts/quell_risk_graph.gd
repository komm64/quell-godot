extends Control

const SAMPLE_SECONDS: float = 8.0
const GRAPH_SAMPLE_HZ: float = 30.0
const GRAPH_DT: float = 1.0 / GRAPH_SAMPLE_HZ
const MAX_SAMPLES: int = int(SAMPLE_SECONDS * GRAPH_SAMPLE_HZ)
const RISK_GRAPH_MAX: float = 1.35
const PADDING_LEFT: float = 34.0
const PADDING_TOP: float = 12.0
const PADDING_RIGHT: float = 10.0
const PADDING_BOTTOM: float = 24.0
const TRACK_GAP: float = 16.0
const MITIGATION_TRACK_HEIGHT: float = 34.0

var headroom_margin: float = 0.80
var samples: Array[Dictionary] = []
var _next_graph_sample_time: float = -1.0

func _ready() -> void:
	custom_minimum_size = Vector2(360.0, 178.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func reset() -> void:
	samples.clear()
	_next_graph_sample_time = -1.0
	queue_redraw()

func add_sample(time_seconds: float, metrics: Dictionary) -> void:
	var raw: float = float(metrics.get("raw_risk", metrics.get("predicted", 0.0)))
	var output: float = float(metrics.get("output_risk", 0.0))
	var mitigation: float = float(metrics.get("mitigation", 0.0))

	var sample := {
		"time": time_seconds,
		"raw": raw,
		"output": output,
		"mitigation": mitigation,
	}

	if _next_graph_sample_time < 0.0:
		_next_graph_sample_time = time_seconds

	var appended := false
	while time_seconds + 0.0001 >= _next_graph_sample_time:
		var fixed_sample := sample.duplicate(true)
		fixed_sample["time"] = _next_graph_sample_time
		samples.append(fixed_sample)
		_next_graph_sample_time += GRAPH_DT
		appended = true

	while samples.size() > MAX_SAMPLES:
		samples.pop_front()

	if appended:
		queue_redraw()

func get_sample_count() -> int:
	return samples.size()

func _draw() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.025, 0.031, 0.036, 0.72), true)
	draw_rect(rect, Color(0.22, 0.29, 0.32, 0.90), false, 1.0)

	var mitigation_plot: Rect2 = Rect2(
		Vector2(PADDING_LEFT, size.y - PADDING_BOTTOM - MITIGATION_TRACK_HEIGHT),
		Vector2(max(1.0, size.x - PADDING_LEFT - PADDING_RIGHT), MITIGATION_TRACK_HEIGHT)
	)
	var risk_plot: Rect2 = Rect2(
		Vector2(PADDING_LEFT, PADDING_TOP),
		Vector2(
			max(1.0, size.x - PADDING_LEFT - PADDING_RIGHT),
			max(1.0, mitigation_plot.position.y - TRACK_GAP - PADDING_TOP)
		)
	)

	_draw_grid(risk_plot, true)
	_draw_threshold_line(risk_plot, 1.0, Color(0.82, 0.88, 0.90, 0.72), RISK_GRAPH_MAX)
	_draw_threshold_line(risk_plot, headroom_margin, Color(0.93, 0.78, 0.32, 0.74), RISK_GRAPH_MAX)
	_draw_series(risk_plot, "output", Color(0.37, 0.82, 0.62), 4.2, RISK_GRAPH_MAX)
	_draw_series(risk_plot, "raw", Color(1.00, 0.55, 0.25), 2.0, RISK_GRAPH_MAX)

	_draw_grid(mitigation_plot, false)
	_draw_series(mitigation_plot, "mitigation", Color(0.44, 0.66, 0.96), 2.2, 1.0)
	_draw_track_labels(risk_plot, mitigation_plot)
	_draw_legend()

func _draw_grid(plot: Rect2, show_left_values: bool) -> void:
	for i in range(5):
		var ratio: float = float(i) / 4.0
		var y: float = plot.position.y + plot.size.y * ratio
		draw_line(Vector2(plot.position.x, y), Vector2(plot.position.x + plot.size.x, y), Color(0.25, 0.31, 0.34, 0.36), 1.0)

	for i in range(5):
		var ratio: float = float(i) / 4.0
		var x: float = plot.position.x + plot.size.x * ratio
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.position.y + plot.size.y), Color(0.25, 0.31, 0.34, 0.22), 1.0)

	if show_left_values:
		draw_string(get_theme_default_font(), Vector2(5.0, plot.position.y + 4.0), "%d" % roundi(RISK_GRAPH_MAX * 100.0), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color(0.66, 0.72, 0.75))
		draw_string(get_theme_default_font(), Vector2(12.0, plot.position.y + plot.size.y), "0", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color(0.66, 0.72, 0.75))
	else:
		draw_string(get_theme_default_font(), Vector2(7.0, plot.position.y + 4.0), "M100", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, Color(0.66, 0.72, 0.75))
		draw_string(get_theme_default_font(), Vector2(19.0, plot.position.y + plot.size.y), "0", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, Color(0.66, 0.72, 0.75))

func _draw_threshold_line(plot: Rect2, value: float, color: Color, max_value: float) -> void:
	var y: float = _value_to_y(plot, value, max_value)
	draw_line(Vector2(plot.position.x, y), Vector2(plot.position.x + plot.size.x, y), color, 1.5)

func _draw_series(plot: Rect2, key: String, color: Color, width: float, max_value: float) -> void:
	if samples.size() < 2:
		return

	var points: PackedVector2Array = PackedVector2Array()
	var draw_count: int = min(samples.size(), max(2, int(plot.size.x) + 1))
	var first_sample: float = max(0.0, float(samples.size() - MAX_SAMPLES))
	var last_sample: float = float(samples.size() - 1)

	for i in range(draw_count):
		var t: float = float(i) / float(max(1, draw_count - 1))
		var sample_position: float = lerpf(first_sample, last_sample, t)
		var x: float = plot.position.x + plot.size.x * t
		var y: float = _value_to_y(plot, _interpolated_value(key, sample_position), max_value)
		points.append(Vector2(x, y))

	draw_polyline(points, color, width, true)

func _interpolated_value(key: String, sample_position: float) -> float:
	var lower_index: int = clampi(int(floor(sample_position)), 0, samples.size() - 1)
	var upper_index: int = clampi(lower_index + 1, 0, samples.size() - 1)
	var weight: float = clamp(sample_position - float(lower_index), 0.0, 1.0)
	var lower: float = float(samples[lower_index][key])
	var upper: float = float(samples[upper_index][key])
	return lerpf(lower, upper, weight)

func _draw_track_labels(risk_plot: Rect2, mitigation_plot: Rect2) -> void:
	var font := get_theme_default_font()
	draw_string(font, Vector2(risk_plot.position.x, risk_plot.position.y - 2.0), "Risk", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color(0.77, 0.84, 0.86))
	draw_string(font, Vector2(mitigation_plot.position.x, mitigation_plot.position.y - 2.0), "Mitigation strength", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color(0.77, 0.84, 0.86))

func _draw_legend() -> void:
	var x: float = PADDING_LEFT
	var y: float = size.y - 7.0
	_draw_legend_item(Vector2(x, y), "Raw", Color(1.00, 0.55, 0.25))
	_draw_legend_item(Vector2(x + 82.0, y), "After", Color(0.37, 0.82, 0.62))
	_draw_legend_item(Vector2(x + 178.0, y), "Mitigation", Color(0.44, 0.66, 0.96))

func _draw_legend_item(origin: Vector2, label: String, color: Color) -> void:
	draw_line(origin + Vector2(0.0, -4.0), origin + Vector2(18.0, -4.0), color, 2.0)
	draw_string(get_theme_default_font(), origin + Vector2(24.0, 0.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color(0.77, 0.84, 0.86))

func _value_to_y(plot: Rect2, value: float, max_value: float) -> float:
	return plot.position.y + plot.size.y * (1.0 - clamp(value / max(max_value, 0.001), 0.0, 1.0))
