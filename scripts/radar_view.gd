extends Control
## Pantalla de radar: dibuja pistas, terminal y aviones a partir del estado de Game.
## La simulación no tiene coordenadas: cada posición se deriva de la fase y el temporizador
## del avión. Aquí solo se suaviza el movimiento y se guarda la estela de posiciones pasadas.

signal plane_selected(plane_id: int)

const C_BG := Color("06140f")
const C_GRID := Color(0.2, 0.8, 0.5, 0.16)
const C_SWEEP := Color(0.3, 1.0, 0.6, 0.12)
const C_RUNWAY := Color("3a4a44")
const C_RUNWAY_BUSY := Color("a33a2c")
const C_RUNWAY_LINED := Color("b8862b")
const C_TERMINAL := Color("1d3a31")
const C_GATE_FREE := Color("2f5a4c")
const C_GATE_USED := Color("6fae96")
const C_ARRIVAL := Color("8ecbff")
const C_DEPARTURE := Color("9be89b")
const C_EMERGENCY := Color("ffb347")
const C_WARN := Color("ff6b5b")
const C_SELECTED := Color("ffe066")
const C_TEXT := Color(0.72, 1.0, 0.84)
const TRAIL_POINTS := 16
const TRAIL_EVERY := 0.2
const PICK_RADIUS := 24.0
const AIRBORNE := ["approach", "final", "takeoff"]

var selected_id := -1
## id -> {"pos": Vector2, "heading": float, "trail": Array, "trail_t": float}
var _shown := {}
var _sweep := 0.0
var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP


func _process(delta: float) -> void:
	_sweep = fmod(_sweep + delta * 1.3, TAU)
	_update_positions(delta)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var pressed: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	if not pressed and not (event is InputEventScreenTouch and event.pressed):
		return
	var best := -1
	var best_d := PICK_RADIUS
	for id in _shown:
		var d: float = _shown[id]["pos"].distance_to(event.position)
		if d < best_d:
			best = id
			best_d = d
	if best >= 0:
		selected_id = best
		plane_selected.emit(best)


# --- Geometría del aeropuerto ---------------------------------------------

func _center() -> Vector2:
	return size * 0.5 + Vector2(40, -30)


func _radius() -> float:
	return min(size.x, size.y) * 0.46


func _runway_len() -> float:
	return min(size.x * 0.36, 300.0)


func _runway_y(i: int) -> float:
	var n := Game.runways.size()
	return _center().y + (i - (n - 1) / 2.0) * 42.0


func _threshold(i: int) -> Vector2:
	return Vector2(_center().x - _runway_len() / 2.0, _runway_y(i))


func _runway_end(i: int) -> Vector2:
	return Vector2(_center().x + _runway_len() / 2.0, _runway_y(i))


func _final_fix(i: int) -> Vector2:
	return _threshold(i) - Vector2(min(size.x * 0.32, 260.0), 0)


func _terminal_rect() -> Rect2:
	var top := _runway_y(Game.runways.size() - 1) + 34.0
	return Rect2(Vector2(_center().x - _runway_len() / 2.0, top), Vector2(_runway_len(), 30))


func _gate_pos(k: int) -> Vector2:
	var t := _terminal_rect()
	var spacing: float = t.size.x / max(1, Game.gate_count())
	return Vector2(t.position.x + spacing * (k + 0.5), t.position.y + 4)


func _holding_pos(k: int) -> Vector2:
	var t := _terminal_rect()
	return Vector2(t.position.x - 22 - k * 22, t.end.y + 14)


func _wait_gate_pos(k: int) -> Vector2:
	var t := _terminal_rect()
	return Vector2(t.end.x + 24 + k * 16, t.position.y + 2)


func _orbit_pos(p: Dictionary) -> Vector2:
	var r: float = _radius() * (0.86 + 0.06 * (p["id"] % 3))
	var a: float = p["id"] * 2.39996 + Game.shift_elapsed * 0.1
	return _center() + Vector2(cos(a), sin(a)) * r


func _progress(timer: float, total: float) -> float:
	return clamp(1.0 - timer / max(total, 0.01), 0.0, 1.0)


## Posición objetivo de un avión según su fase.
func _target(p: Dictionary, slots: Dictionary) -> Vector2:
	var rw: int = p["runway"]
	match p["state"]:
		"approach":
			return _orbit_pos(p)
		"final":
			return _final_fix(rw).lerp(_threshold(rw), _progress(p["timer"], Game.FINAL_TIME))
		"landing":
			var t := _progress(Game.runways[rw]["op_left"], Game.landing_time())
			return _threshold(rw).lerp(_runway_end(rw), t)
		"taxi_in":
			return _runway_end(rw).lerp(_wait_gate_pos(0), _progress(p["timer"], Game.taxi_time()))
		"wait_gate":
			return _wait_gate_pos(slots.get(p["id"], 0))
		"gate":
			return _gate_pos(slots.get(p["id"], 0))
		"taxi_out":
			var t := _progress(p["timer"], Game.PUSHBACK_TIME + Game.taxi_time())
			return _gate_pos(slots.get(p["id"], 0)).lerp(_holding_pos(0), t)
		"holding":
			return _holding_pos(slots.get(p["id"], 0))
		"lined_up":
			return _threshold(rw) + Vector2(8, 0)
		"takeoff":
			var t := _progress(Game.runways[rw]["op_left"], Game.takeoff_time())
			return _threshold(rw).lerp(_runway_end(rw) + Vector2(_runway_len() * 0.8, -40), t)
	return _center()


## Reparte puertas, punto de espera y cola de puerta según el orden de los aviones.
func _slots() -> Dictionary:
	var slots := {}
	var counts := {"gate": 0, "holding": 0, "wait_gate": 0}
	for p in Game.planes:
		var key: String = p["state"]
		if key == "taxi_out":
			key = "gate"
		if counts.has(key):
			slots[p["id"]] = counts[key]
			counts[key] += 1
	return slots


func _update_positions(delta: float) -> void:
	var alive := {}
	var slots := _slots()
	for p in Game.planes:
		var id: int = p["id"]
		alive[id] = true
		var target := _target(p, slots)
		if not _shown.has(id):
			_shown[id] = {"pos": target, "heading": 0.0, "trail": [], "trail_t": 0.0}
		var s: Dictionary = _shown[id]
		var prev: Vector2 = s["pos"]
		s["pos"] = prev.lerp(target, 1.0 - exp(-7.0 * delta))
		var move: Vector2 = s["pos"] - prev
		if move.length() > 0.05:
			s["heading"] = move.angle()
		if p["state"] in AIRBORNE:
			s["trail_t"] += delta
			if s["trail_t"] >= TRAIL_EVERY:
				s["trail_t"] = 0.0
				s["trail"].push_front(s["pos"])
				if s["trail"].size() > TRAIL_POINTS:
					s["trail"].pop_back()
		else:
			s["trail"].clear()
	for id in _shown.keys():
		if not alive.has(id):
			_shown.erase(id)
	if selected_id >= 0 and not alive.has(selected_id):
		selected_id = -1


# --- Dibujo ----------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), C_BG)
	_draw_scope()
	_draw_airport()
	for p in Game.planes:
		if _shown.has(p["id"]):
			_draw_plane(p, _shown[p["id"]])
	_draw_string("Clic en un avión para hablar con él por radio", Vector2(12, size.y - 12), 13, C_GRID * 3.0)


func _draw_scope() -> void:
	var c := _center()
	var r := _radius()
	for k in [0.33, 0.66, 1.0]:
		draw_arc(c, r * k, 0, TAU, 96, C_GRID, 1.0)
	draw_line(c - Vector2(r, 0), c + Vector2(r, 0), C_GRID, 1.0)
	draw_line(c - Vector2(0, r), c + Vector2(0, r), C_GRID, 1.0)
	for k in 6:
		var a := _sweep - k * 0.05
		var col := C_SWEEP
		col.a *= 1.0 - k / 6.0
		draw_line(c, c + Vector2(cos(a), sin(a)) * r, col, 3.0)


func _draw_airport() -> void:
	for i in Game.runways.size():
		var r: Dictionary = Game.runways[i]
		var a := _threshold(i)
		var b := _runway_end(i)
		draw_dashed_line(_final_fix(i), a, C_GRID * 2.0, 1.0, 6.0)
		var col := C_RUNWAY
		if not r["op"].is_empty():
			col = C_RUNWAY_BUSY
		elif not r["lined"].is_empty():
			col = C_RUNWAY_LINED
		draw_rect(Rect2(a - Vector2(0, 6), Vector2(b.x - a.x, 12)), col)
		draw_dashed_line(a + Vector2(10, 0), b - Vector2(4, 0), Color(1, 1, 1, 0.35), 1.0, 8.0)
		_draw_string("P%d" % (i + 1), a + Vector2(-26, 5), 14, C_TEXT)
		if r["prev_wake"] >= 0 and Game.levels["wake_monitor"] > 0:
			var left: float = Game.separation_left(i, 0)
			if left > 0.0:
				_draw_string("estela %s %.1fs" % [Game.WAKE_NAMES[r["prev_wake"]], left], b + Vector2(8, 5), 12, C_WARN)
	var t := _terminal_rect()
	draw_rect(t, C_TERMINAL)
	var used := Game.gates_used()
	for k in Game.gate_count():
		var g := _gate_pos(k)
		draw_rect(Rect2(g - Vector2(5, 4), Vector2(10, 8)), C_GATE_USED if k < used else C_GATE_FREE)
	_draw_string("TERMINAL", t.position + Vector2(4, 26), 11, C_TEXT)
	_draw_string("PUNTO DE ESPERA", _holding_pos(0) + Vector2(-70, 22), 10, C_TEXT)


func _draw_plane(p: Dictionary, s: Dictionary) -> void:
	var pos: Vector2 = s["pos"]
	var col := C_ARRIVAL if p["arrival"] else C_DEPARTURE
	if p["emergency"]:
		col = C_EMERGENCY
	elif p["state"] in ["approach", "final"] and p["fuel"] < 10.0 and int(Game.shift_elapsed * 3.0) % 2 == 0:
		col = C_WARN
	var trail: Array = s["trail"]
	for k in trail.size():
		var dot := col
		dot.a = 0.6 * (1.0 - float(k) / TRAIL_POINTS)
		draw_circle(trail[k], 2.0, dot)
	var selected: bool = p["id"] == selected_id
	var size_px: float = 6.0 + 2.0 * p["wake"]
	var h: float = s["heading"]
	var pts := PackedVector2Array([
		pos + Vector2.from_angle(h) * size_px,
		pos + Vector2.from_angle(h + 2.5) * size_px * 0.8,
		pos + Vector2.from_angle(h - 2.5) * size_px * 0.8,
	])
	draw_colored_polygon(pts, col)
	if selected:
		draw_arc(pos, size_px + 7.0, 0, TAU, 32, C_SELECTED, 2.0)
	var tag := "%s %s" % [p["callsign"], Game.WAKE_NAMES[p["wake"]]]
	if p["state"] in ["approach", "final"]:
		tag += " %ds" % ceil(p["fuel"])
	elif not selected and not p["state"] in AIRBORNE:
		tag = p["callsign"]
	_draw_string(tag, pos + Vector2(10, -8), 12, C_SELECTED if selected else col)


func _draw_string(text: String, at: Vector2, font_size: int, col: Color) -> void:
	draw_string(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
