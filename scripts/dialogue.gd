extends CanvasLayer
## Autoload "Dialogue": show a line of dialogue from anywhere for a set number of seconds.
##
##     Dialogue.say("Mission control, we have a problem.", 4.0)
##     Dialogue.say("Copy that, Eagle.", 3.0, "Houston")           # optional speaker name
##     Dialogue.say("Brace for impact!", 2.5, "Pilot", true)       # true = interrupt: replaces whatever is showing
##     await Dialogue.line_finished                                 # wait for a line to end
##     Dialogue.clear()                                             # hide everything now
##
## Lines sent while one is showing are queued and play one after another. A duration of 0 or less
## picks a reading time from the text length. Works while the game is paused and draws above other UI.
##
## RADIO STATIC
## A line spoken by a radio voice (a speaker in radio_speakers, "Mission Control" by default, or radio = RADIO_ON)
## is garbled according to signal_quality, 0..1, which the MoonSystems autoload keeps up to date from the radio link
## budget. The weaker the signal, the more letters are lost to static, with bursts of dropout at the bottom end, and
## the longer the line stays up. The static keeps shimmering while the line is on screen and follows the signal as the
## player moves, so a line that starts as noise can clear up on the way back to the base. Everyone else (the suit
## computer, the astronaut) speaks locally and is never garbled. Signals and queued text always carry the clean text.
##
##     Dialogue.say("Hold position.", 3.0, "Pilot", false, Dialogue.RADIO_ON)     # force it over the radio
##     Dialogue.say("Stand by.", 3.0, "Mission Control", false, Dialogue.RADIO_OFF) # force it clean
##     Dialogue.garble("Copy that, Eagle.", 0.4)                                    # the garbling on its own

signal line_started(text: String, speaker: String)
signal line_finished(text: String, speaker: String)
signal queue_finished

const FADE_TIME := 0.25

const RADIO_AUTO := -1
const RADIO_OFF := 0
const RADIO_ON := 1

const CLEAR_ABOVE := 0.97                  # at or above this quality a line is shown untouched
const MAX_LOSS := 0.93                     # even with no signal a few letters get through
const BURST_CHANCE := 0.12                 # dropout bursts at the bottom end of the signal
const SHIMMER_S := 0.12                    # how often the static re-rolls
const STATIC_GLYPHS := "#%&*+=?/\\~^<>|.-: "

## 0..1: how good the radio link is right now (1 = perfectly clear). MoonSystems keeps this up to date.
var signal_quality := 1.0
## Speakers whose lines arrive over the radio.
var radio_speakers: Array[String] = ["Mission Control", "Houston", "Capcom", "CAPCOM"]

var _queue: Array = []
var _current: Dictionary = {}
var _remaining := 0.0
var _shimmer := 0.0
var _tick := 0
var _panel: PanelContainer
var _speaker_label: Label
var _text_label: Label
var _tween: Tween


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_panel.visible = false
	_panel.modulate.a = 0.0


## Shows `text` for `seconds`. Returns nothing; connect to line_finished / queue_finished to react.
## radio: RADIO_AUTO (default) garbles it if the speaker is a radio voice, RADIO_ON / RADIO_OFF force it.
func say(text: String, seconds: float, speaker: String = "", interrupt: bool = false, radio: int = RADIO_AUTO) -> void:
	var duration := seconds if seconds > 0.0 else clampf(1.5 + text.length() * 0.05, 2.0, 12.0)
	var over_radio := radio == RADIO_ON or (radio == RADIO_AUTO and speaker in radio_speakers)
	var line := {"text": text, "speaker": speaker, "duration": duration, "radio": over_radio, "seed": text.hash()}
	if interrupt:
		_queue.clear()
		if not _current.is_empty():
			var old := _current
			_current = {}
			line_finished.emit(old["text"], old["speaker"])
		_show(line)
	elif _current.is_empty():
		_show(line)
	else:
		_queue.append(line)


## Hides the current line and drops anything queued.
func clear() -> void:
	_queue.clear()
	if _current.is_empty():
		return
	var old := _current
	_current = {}
	line_finished.emit(old["text"], old["speaker"])
	_fade_out()
	queue_finished.emit()


func is_showing() -> bool:
	return not _current.is_empty()


## `text` as it sounds over a radio link of this quality (0..1). seed_value picks which letters go first (the same
## seed keeps the same letters), tick re-rolls the shimmer. At or above CLEAR_ABOVE the text comes back unchanged.
func garble(text: String, quality: float, seed_value: int = 0, tick: int = 0) -> String:
	var q := clampf(quality, 0.0, 1.0)
	if q >= CLEAR_ABOVE:
		return text
	var loss := pow(1.0 - q, 1.4)                         # 0 = clear ... 1 = nothing
	var p := loss * MAX_LOSS                              # chance that a letter is lost
	var burst_p := loss * loss * BURST_CHANCE             # chance that a letter starts a dropout burst
	var out := ""
	var burst := 0
	for i in text.length():
		var c := text.substr(i, 1)
		if c == " " or c == "\n" or c == "\t":
			out += c
			continue
		if burst > 0:
			burst -= 1
			out += _static_char(i, seed_value, tick)
			continue
		if _rand01(i, seed_value + 7, tick >> 2) < burst_p:
			burst = 1 + int(_rand01(i, seed_value + 13, 0) * 5.0)
			out += _static_char(i, seed_value, tick)
			continue
		var limit := p if _is_letter(c) else p * 0.5      # punctuation survives a little better
		# Mostly the same letters are lost for the whole line; a smaller share flickers with the tick.
		var lost := _rand01(i, seed_value, 0) < limit * 0.75 or _rand01(i, seed_value, tick + 1) < limit * 0.25
		out += _static_char(i, seed_value, tick) if lost else c
	return out


func _process(delta: float) -> void:
	if _current.is_empty():
		return
	if _current["radio"]:
		_shimmer -= delta
		if _shimmer <= 0.0:
			_shimmer = SHIMMER_S
			_tick += 1
			_render(_current)
	_remaining -= delta
	if _remaining > 0.0:
		return
	var done := _current
	_current = {}
	line_finished.emit(done["text"], done["speaker"])
	if _queue.is_empty():
		_fade_out()
		queue_finished.emit()
	else:
		_show(_queue.pop_front())


func _show(line: Dictionary) -> void:
	_current = line
	var stretch := 1.0
	if line["radio"]:
		stretch += 0.5 * (1.0 - clampf(signal_quality, 0.0, 1.0))      # garbled speech takes longer to read
	_remaining = float(line["duration"]) * stretch
	_shimmer = SHIMMER_S
	_tick = 0
	_speaker_label.visible = line["speaker"] != ""
	_render(line)
	_panel.visible = true
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 1.0, FADE_TIME)
	line_started.emit(line["text"], line["speaker"])


# Puts the line on screen: clean, or garbled by the current signal with a signal tag after the speaker name.
func _render(line: Dictionary) -> void:
	var raw: String = line["text"]
	var who: String = line["speaker"]
	var q := clampf(signal_quality, 0.0, 1.0)
	var text := raw
	if line["radio"] and q < CLEAR_ABOVE:
		text = garble(raw, q, int(line["seed"]), _tick)
		who = "%s  %s" % [who, _signal_tag(q)]
	if _text_label.text != text:
		_text_label.text = text
	if _speaker_label.text != who:
		_speaker_label.text = who


func _signal_tag(q: float) -> String:
	if q < 0.03:
		return "[NO SIGNAL]"
	var bars := clampi(int(round(q * 4.0)), 1, 4)
	return "[" + "|".repeat(bars) + ".".repeat(4 - bars) + "]"


func _static_char(i: int, seed_value: int, tick: int) -> String:
	var n := STATIC_GLYPHS.length()
	return STATIC_GLYPHS[int(_rand01(i, seed_value + 3, tick) * n) % n]


static func _is_letter(c: String) -> bool:
	return c.to_lower() != c.to_upper() or (c >= "0" and c <= "9")


static func _rand01(a: int, b: int, c: int) -> float:
	return float(hash(Vector3i(a, b, c)) & 0xFFFF) / 65536.0


func _fade_out() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 0.0, FADE_TIME)
	_tween.tween_callback(func() -> void:
		if _current.is_empty():
			_panel.visible = false)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.anchor_left = 0.15
	_panel.anchor_right = 0.85
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = 0.0
	_panel.offset_right = 0.0
	_panel.offset_top = -40.0
	_panel.offset_bottom = -40.0
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN      # grows upward as the text gets longer

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.04, 0.07, 0.88)
	sb.border_color = Color(0.55, 0.65, 0.8, 0.6)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 22.0
	sb.content_margin_right = 22.0
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	_panel.add_child(box)

	_speaker_label = Label.new()
	_speaker_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_speaker_label.add_theme_font_size_override("font_size", 18)
	_speaker_label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.35))
	box.add_child(_speaker_label)

	_text_label = Label.new()
	_text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_label.add_theme_font_size_override("font_size", 22)
	_text_label.add_theme_color_override("font_color", Color(0.93, 0.95, 1.0))
	box.add_child(_text_label)
