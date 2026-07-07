extends Control

# Live viewer for the hard-projection ORACLE (quell_projection_reference.gd),
# the CPU reference mitigation. Runs each Pokemon frame through the oracle and
# shows Raw (left) vs After (right) side by side, so the actually-shipping
# mitigation can be seen on the benchmark. Toggle RISE_CAP / TEMPORAL_LOWPASS
# with Space. This is NOT the realtime GPU path (that port is still pending) —
# it is the oracle itself, the same code the release gate measures green.

const ProjectionClass = preload("res://addons/quell_core/runtime/quell_projection_reference.gd")

const FRAME_DIR := "res://validation/private/demo-videos/pokemon-shock/frames"
const ANALYSIS := Vector2i(256, 144)
const SOURCE_FPS := 1199.0 / 50.0
const OUTPUT_FPS := 30.0
const TARGET_RISK := 0.80

var _paths: PackedStringArray = PackedStringArray()
var _oracle
var _style := 1                      # STYLE_TEMPORAL_LOWPASS (default)
var _out_index := 0
var _output_frames := 0
var _play_accum := 0.0
var _paused := false

var _raw_tex: TextureRect
var _aft_tex: TextureRect
var _label: Label

func _ready() -> void:
	_paths = _list_frames()
	if _paths.is_empty():
		_fatal("No frames found under %s" % FRAME_DIR)
		return
	_output_frames = maxi(1, int(floor(float(_paths.size()) / SOURCE_FPS * OUTPUT_FPS)))
	_build_ui()
	_reset_oracle()

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.08)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_label)

	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)
	_raw_tex = _make_panel(row, "RAW")
	_aft_tex = _make_panel(row, "AFTER (oracle)")

func _make_panel(row: HBoxContainer, title: String) -> TextureRect:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(col)
	var cap := Label.new()
	cap.text = title
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(cap)
	var tex := TextureRect.new()
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tex.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(tex)
	return tex

func _reset_oracle() -> void:
	_oracle = ProjectionClass.new()
	_oracle.target_risk = TARGET_RISK
	_oracle.mitigation_style = _style
	_oracle.reset()
	_out_index = 0

func _process(delta: float) -> void:
	if _paths.is_empty() or _paused:
		return
	# Advance one output frame per tick (playback speed follows the CPU oracle's
	# throughput — the oracle's per-pixel work in GDScript is not full 30 fps).
	_step_one()

func _step_one() -> void:
	var t := float(_out_index) / OUTPUT_FPS
	var si := clampi(int(floor(t * SOURCE_FPS)), 0, _paths.size() - 1)
	var img := Image.new()
	if img.load(_paths[si]) != OK:
		return
	var analysis := _prepare(img)
	var after: Image = _oracle.step(analysis, t)
	_raw_tex.texture = ImageTexture.create_from_image(analysis)
	_aft_tex.texture = ImageTexture.create_from_image(after)
	var style_name := "RISE_CAP" if _style == 0 else "TEMPORAL_LOWPASS"
	var pstate := "  [PAUSED]" if _paused else ""
	_label.text = "Oracle — Pokemon shock — frame %d / %d   style: %s%s   [Space]=style  [P]=pause  [.]=step  [R]=restart" % [
		_out_index + 1, _output_frames, style_name, pstate]
	_out_index += 1
	if _out_index >= _output_frames:
		_reset_oracle()

func _prepare(img: Image) -> Image:
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if img.get_width() != ANALYSIS.x or img.get_height() != ANALYSIS.y:
		img.resize(ANALYSIS.x, ANALYSIS.y, Image.INTERPOLATE_BILINEAR)
	return img

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_style = 1 - _style
			_reset_oracle()
		elif event.keycode == KEY_P:
			_paused = not _paused
			_refresh_label()
		elif event.keycode == KEY_PERIOD:      # step one frame forward while paused
			if _paused:
				_step_one()
		elif event.keycode == KEY_R:           # restart from the beginning
			_reset_oracle()
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()

func _refresh_label() -> void:
	if _label != null and _out_index > 0:
		var style_name := "RISE_CAP" if _style == 0 else "TEMPORAL_LOWPASS"
		var pstate := "  [PAUSED]" if _paused else ""
		_label.text = "Oracle — Pokemon shock — frame %d / %d   style: %s%s   [Space]=style  [P]=pause  [.]=step  [R]=restart" % [
			_out_index, _output_frames, style_name, pstate]

func _list_frames() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(FRAME_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name.is_empty():
			break
		if not dir.current_is_dir() and name.begins_with("frame_") and name.ends_with(".png"):
			out.append(FRAME_DIR.path_join(name))
	dir.list_dir_end()
	out.sort()
	return out

func _fatal(msg: String) -> void:
	var l := Label.new()
	l.text = msg
	add_child(l)
	push_error(msg)
