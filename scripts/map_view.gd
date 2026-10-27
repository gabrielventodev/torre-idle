extends Control
## Tablero del aeropuerto visto desde arriba. Dibuja el mapa, las pistas, las calles de rodaje,
## la terminal y los aviones en la posición que calcula Game (en unidades de mundo).
## Si existe MAP_TEXTURE_PATH, se dibuja como fondo (pensado para una foto satelital futura).

signal plane_selected(plane_id: int)

const MAP_TEXTURE_PATH := "res://assets/mapa.png"
const C_GROUND := Color("2e3b2c")
const C_GRID := Color(1, 1, 1, 0.04)
const C_APRON := Color("4a4f4c")
const C_RUNWAY := Color("2b2d2e")
const C_RUNWAY_BUSY := Color("6e2a22")
const C_RUNWAY_LINED := Color("6b5420")
const C_MARK := Color(1, 1, 1, 0.8)
const C_TAXI_LINE := Color("d8b23a")
const C_TERMINAL := Color("7d8590")
const C_ARRIVAL := Color("8ecbff")
const C_DEPARTURE := Color("9be89b")
const C_EMERGENCY := Color("ffb347")
const C_WARN := Color("ff4d3d")
const C_SELECTED := Color("ffe066")
const C_TEXT := Color(0.95, 0.97, 1.0)
const C_SHADOW := Color(0, 0, 0, 0.35)
const TRAIL_POINTS := 12
const TRAIL_EVERY := 0.25
const PICK_RADIUS := 26.0

var selected_id := -1
var _trails := {}
var _trail_t := 0.0
var _font: Font
var _texture: Texture2D


func _ready() -> void:
	_font = ThemeDB.fallback_font
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	if ResourceLoader.exists(MAP_TEXTURE_PATH):
		_texture = load(MAP_TEXTURE_PATH)


func _process(delta: float) -> void:
	_update_trails(delta)
	if selected_id >= 0 and Game._find(selected_id).is_empty():
		selected_id = -1
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var pressed: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	if not pressed and not (event is InputEventScreenTouch and event.pressed):
		return
	var best := -1
	var best_d := PICK_RADIUS
	for p in Game.planes:
		var d := _to_screen(p["pos"]).distance_to(event.position)
		if d < best_d:
			best = p["id"]
			best_d = d
	if best >= 0:
		selected_id = best
		plane_selected.emit(best)


# --- Transformación mundo -> pantalla ---------------------------------------

func _scale() -> float:
	return min(size.x / Game.MAP_SIZE.x, size.y / Game.MAP_SIZE.y)


func _offset() -> Vector2:
	return (size - Game.MAP_SIZE * _scale()) * 0.5


func _to_screen(world: Vector2) -> Vector2:
	return _offset() + world * _scale()


func _update_trails(delta: float) -> void:
	_trail_t += delta
	var sample := _trail_t >= TRAIL_EVERY
	if sample:
		_trail_t = 0.0
	var alive := {}
	for p in Game.planes:
		alive[p["id"]] = true
		if not Game.is_airborne(p):
			_trails.erase(p["id"])
			continue
		if sample:
			var t: Array = _trails.get(p["id"], [])
			t.push_front(p["pos"])
			if t.size() > TRAIL_POINTS:
				t.pop_back()
			_trails[p["id"]] = t
	for id in _trails.keys():
		if not alive.has(id):
			_trails.erase(id)


# --- Dibujo ----------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("1b2419"))
	draw_set_transform(_offset(), 0.0, Vector2.ONE * _scale())
	_draw_ground()
	_draw_airport()
	var sel := Game._find(selected_id)
	if not sel.is_empty():
		_draw_route(sel)
	draw_set_transform(Vector2.ZERO)
	# Primero los aviones en tierra y después los que vuelan, de menor a mayor altitud.
	var order := Game.planes.duplicate()
	order.sort_custom(func(a, b): return a["alt"] < b["alt"])
	for p in order:
		_draw_plane(p)
	_draw_text("Clic en un avión para hablar con él por radio", Vector2(12, size.y - 12), 13, Color(1, 1, 1, 0.5))


func _draw_ground() -> void:
	var map := Rect2(Vector2.ZERO, Game.MAP_SIZE)
	if _texture:
		draw_texture_rect(_texture, map, false)
		return
	draw_rect(map, C_GROUND)
	for x in range(0, int(Game.MAP_SIZE.x) + 1, 100):
		draw_line(Vector2(x, 0), Vector2(x, Game.MAP_SIZE.y), C_GRID, 1.0)
	for y in range(0, int(Game.MAP_SIZE.y) + 1, 100):
		draw_line(Vector2(0, y), Vector2(Game.MAP_SIZE.x, y), C_GRID, 1.0)


func _draw_airport() -> void:
	var n := Game.runways.size()
	var top := Game.runway_y(n - 1) - 30.0
	# Plataforma de hormigón que contiene pistas, rodaje y terminal.
	draw_rect(Rect2(Vector2(Game.HOLD_POINT.x - 40, top), Vector2(Game.WAIT_GATE_POINT.x + 40 - Game.HOLD_POINT.x + 40, Game.GATE_Y + 50 - top)), C_APRON)
	# Calle de rodaje principal y conexiones.
	draw_line(Vector2(Game.HOLD_POINT.x, Game.TAXI_Y), Vector2(Game.WAIT_GATE_POINT.x, Game.TAXI_Y), C_TAXI_LINE, 1.5)
	for i in n:
		var y := Game.runway_y(i)
		draw_line(Vector2(Game.RUNWAY_X0 - 30, Game.TAXI_Y), Vector2(Game.RUNWAY_X0 - 30, y), C_TAXI_LINE, 1.5)
		var ex := Game.runway_exit_x() + 20.0
		draw_line(Vector2(ex, y), Vector2(ex, Game.TAXI_Y), C_TAXI_LINE, 1.5)
	for i in n:
		_draw_runway(i)
	# Terminal y puertas.
	var t0 := Game.gate_pos(0) - Vector2(30, -14)
	draw_rect(Rect2(t0, Vector2(Game.GATE_SPACING * Game.MAX_GATES + 20, 28)), C_TERMINAL)
	for k in Game.gates.size():
		var g := Game.gate_pos(k)
		var used: bool = Game.gates[k]["plane"] >= 0 or Game.gates[k]["turn"] > 0.0
		draw_rect(Rect2(g - Vector2(14, 12), Vector2(28, 24)), Color(1, 1, 1, 0.12) if used else Color(1, 1, 1, 0.05))
		draw_line(g + Vector2(0, 12), g + Vector2(0, 14), C_TAXI_LINE, 1.0)


func _draw_runway(i: int) -> void:
	var r: Dictionary = Game.runways[i]
	var y := Game.runway_y(i)
	var col := C_RUNWAY
	if not r["op"].is_empty():
		col = C_RUNWAY_BUSY
	elif not r["lined"].is_empty():
		col = C_RUNWAY_LINED
	var rect := Rect2(Vector2(Game.RUNWAY_X0, y - 9), Vector2(Game.RUNWAY_X1 - Game.RUNWAY_X0, 18))
	draw_rect(rect, col)
	# Marcas: umbral, eje discontinuo y numeración.
	for k in 4:
		draw_rect(Rect2(Vector2(Game.RUNWAY_X0 + 4, y - 7 + k * 4), Vector2(14, 2)), C_MARK)
	draw_dashed_line(Vector2(Game.RUNWAY_X0 + 40, y), Vector2(Game.RUNWAY_X1 - 10, y), C_MARK, 1.0, 10.0)
	# Senda de aproximación prolongada.
	draw_dashed_line(Game.threshold(i) - Vector2(Game.FINAL_DIST, 0), Game.threshold(i), Color(1, 1, 1, 0.15), 1.0, 6.0)


func _draw_route(p: Dictionary) -> void:
	if p["state"] == "holding":
		draw_arc(p["hold_center"], Game.HOLD_RADIUS, 0, TAU, 48, Color(C_SELECTED, 0.4), 1.0)
	var at: Vector2 = p["pos"]
	for w in p["path"]:
		draw_dashed_line(at, w, Color(C_SELECTED, 0.6), 1.0, 5.0)
		at = w


func _draw_plane(p: Dictionary) -> void:
	var pos := _to_screen(p["pos"])
	var col := C_ARRIVAL if p["arrival"] else C_DEPARTURE
	if p["emergency"]:
		col = C_EMERGENCY
	elif p["arrival"] and Game.is_airborne(p) and p["fuel"] < 15.0 and int(Game.shift_elapsed * 3.0) % 2 == 0:
		col = C_WARN
	for k in _trails.get(p["id"], []).size():
		var dot := col
		dot.a = 0.5 * (1.0 - float(k) / TRAIL_POINTS)
		draw_circle(_to_screen(_trails[p["id"]][k]), 1.6, dot)
	var scale_px: float = (7.0 + 2.5 * p["wake"]) * max(_scale() * 1.4, 0.8)
	# La sombra se separa del avión con la altitud: da sensación de altura en una vista 2D.
	var lift: float = min(p["alt"] / 1000.0 * 3.0, 24.0)
	_draw_silhouette(pos + Vector2(lift, lift), p["heading"], scale_px, C_SHADOW)
	_draw_silhouette(pos, p["heading"], scale_px, col)
	var selected: bool = p["id"] == selected_id
	if selected:
		draw_arc(pos, scale_px + 8.0, 0, TAU, 32, C_SELECTED, 2.0)
	if p.get("conflict", false):
		draw_arc(pos, scale_px + 13.0, 0, TAU, 32, C_WARN, 2.0)
	var tag: String = p["callsign"]
	if Game.is_airborne(p):
		tag += "  %03d" % int(round(p["alt"] / 100.0))
		if p["target_alt"] != p["alt"] and p["state"] in ["holding", "inbound"]:
			tag += "↑" if p["target_alt"] > p["alt"] else "↓"
	_draw_text(tag, pos + Vector2(scale_px + 4, -scale_px), 12, C_SELECTED if selected else C_TEXT)


## Silueta de avión vista desde arriba: fuselaje, alas y cola.
func _draw_silhouette(pos: Vector2, heading: float, s: float, col: Color) -> void:
	var body := PackedVector2Array([
		Vector2(1.0, 0), Vector2(0.6, 0.12), Vector2(0.15, 0.12), Vector2(-0.1, 0.95), Vector2(-0.3, 0.95),
		Vector2(-0.15, 0.12), Vector2(-0.7, 0.1), Vector2(-0.9, 0.4), Vector2(-1.0, 0.4), Vector2(-0.95, 0),
		Vector2(-1.0, -0.4), Vector2(-0.9, -0.4), Vector2(-0.7, -0.1), Vector2(-0.15, -0.12), Vector2(-0.3, -0.95),
		Vector2(-0.1, -0.95), Vector2(0.15, -0.12), Vector2(0.6, -0.12),
	])
	var t := Transform2D(heading, pos)
	var pts := PackedVector2Array()
	for v in body:
		pts.append(t * (v * s))
	draw_colored_polygon(pts, col)


func _draw_text(text: String, at: Vector2, font_size: int, col: Color) -> void:
	draw_string_outline(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color(0, 0, 0, 0.7))
	draw_string(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
