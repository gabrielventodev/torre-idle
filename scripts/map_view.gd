extends Control
## Tablero del aeropuerto visto desde arriba. Dibuja el mapa, las pistas, las calles de rodaje,
## la terminal, las tormentas y los aviones en la posición que calcula Game (en unidades de mundo).
## Con replay_frames rellenado, en vez del tráfico en vivo reproduce a cámara lenta una
## repetición grabada por Game.
## Si existe MAP_TEXTURE_PATH, se dibuja como fondo (pensado para una foto satelital futura).

signal plane_selected(plane_id: int)

const MAP_TEXTURE_PATH := "res://assets/mapa.png"
const C_GROUND := Color("2e3b2c")
const C_GRID := Color(1, 1, 1, 0.04)
const C_APRON := Color("4a4f4c")
const C_RUNWAY := Color("2b2d2e")
const C_RUNWAY_BUSY := Color("6e2a22")
const C_RUNWAY_LINED := Color("6b5420")
const C_RUNWAY_CLOSED := Color("5a1d5e")
const C_MARK := Color(1, 1, 1, 0.8)
const C_TAXI_LINE := Color("d8b23a")
const C_TERMINAL := Color("7d8590")
const C_ARRIVAL := Color("8ecbff")
const C_DEPARTURE := Color("9be89b")
const C_EMERGENCY := Color("ffb347")
const C_VIP := Color("ffd700")
const C_CARGO := Color("c49cff")
const C_WARN := Color("ff4d3d")
const C_SELECTED := Color("ffe066")
const C_STORM := Color(0.35, 0.95, 0.45)
const C_STORM_CORE := Color(0.95, 0.3, 0.25)
const C_TEXT := Color(0.95, 0.97, 1.0)
const C_SHADOW := Color(0, 0, 0, 0.35)
const TRAIL_POINTS := 12
const TRAIL_EVERY := 0.25
const PICK_RADIUS := 26.0
## Velocidad de la repetición respecto al tiempo real.
const REPLAY_SPEED := 0.4

var selected_id := -1
## Repetición en curso: fotos de Game.replays[i]["frames"]. Vacía = tráfico en vivo.
var replay_frames: Array = []
var replay_title := ""
## Segundos (reales) que queda el destello rojo de un incidente.
var flash_time := 0.0
var flash_text := ""
var _replay_t := 0.0
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
	if not is_visible_in_tree():
		return
	# delta ya viene escalado por la cámara lenta; los temporizadores de la UI van en tiempo real.
	var real_delta: float = delta / max(Engine.time_scale, 0.01)
	if replay_frames.is_empty():
		_update_trails(delta)
		if selected_id >= 0 and Game._find(selected_id).is_empty():
			selected_id = -1
	else:
		_replay_t += real_delta * REPLAY_SPEED
	flash_time = max(0.0, flash_time - real_delta)
	queue_redraw()


func play_replay(replay: Dictionary) -> void:
	replay_frames = replay["frames"]
	replay_title = replay["title"]
	_replay_t = 0.0


func stop_replay() -> void:
	replay_frames = []


func flash(text: String) -> void:
	flash_text = text
	flash_time = 1.6


func _gui_input(event: InputEvent) -> void:
	if not replay_frames.is_empty():
		return
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
	if replay_frames.is_empty():
		_draw_storms()
		var sel := Game._find(selected_id)
		if not sel.is_empty():
			_draw_route(sel)
	draw_set_transform(Vector2.ZERO)
	if replay_frames.is_empty():
		_draw_live()
	else:
		_draw_replay()
	if flash_time > 0.0:
		var a: float = clamp(flash_time, 0.0, 1.0)
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 0, 0, 0.6 * a), false, 8.0)
		if int(flash_time * 6.0) % 2 == 0:
			_draw_text(flash_text, Vector2(size.x * 0.5 - 160, 80), 30, C_WARN)


func _draw_live() -> void:
	# Primero los aviones en tierra y después los que vuelan, de menor a mayor altitud.
	var order := Game.planes.duplicate()
	order.sort_custom(func(a, b): return a["alt"] < b["alt"])
	for p in order:
		_draw_plane(p, _trails.get(p["id"], []))
	_draw_wind_panel()
	_draw_text("Clic en un avión para hablar con él por radio", Vector2(12, size.y - 12), 13, Color(1, 1, 1, 0.5))


func _draw_replay() -> void:
	var n := replay_frames.size()
	if n == 0:
		return
	# Al terminar se queda un momento en la última foto y vuelve a empezar.
	var idx := int(_replay_t / Game.REPLAY_EVERY) % (n + 10)
	idx = min(idx, n - 1)
	var frame: Array = replay_frames[idx]
	for p in frame:
		var trail := []
		if Game.is_airborne(p):
			for k in range(1, TRAIL_POINTS):
				var j := idx - k * 2
				if j < 0:
					break
				for q in replay_frames[j]:
					if q["id"] == p["id"]:
						trail.append(q["pos"])
		_draw_plane(p, trail)
	_draw_text("REPETICIÓN x%.1f · %s" % [REPLAY_SPEED, replay_title], Vector2(12, 24), 18, C_WARN)
	var progress: float = float(idx) / max(1, n - 1)
	draw_rect(Rect2(Vector2(12, 34), Vector2((size.x - 24) * progress, 4)), C_WARN)


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
	draw_rect(Rect2(Vector2(Game.RUNWAY_X0 - 80, top), Vector2(Game.RUNWAY_X1 - Game.RUNWAY_X0 + 160, Game.GATE_Y + 50 - top)), C_APRON)
	# Calle de rodaje principal y conexiones con las dos cabeceras y la salida en uso.
	draw_line(Vector2(Game.RUNWAY_X0 - 70, Game.TAXI_Y), Vector2(Game.RUNWAY_X1 + 70, Game.TAXI_Y), C_TAXI_LINE, 1.5)
	for i in n:
		var y := Game.runway_y(i)
		for x in [Game.entry_x(1), Game.entry_x(-1), Game.runway_exit_x() + Game.wind_dir * 20.0]:
			draw_line(Vector2(x, Game.TAXI_Y), Vector2(x, y), C_TAXI_LINE, 1.5)
	for i in n:
		_draw_runway(i)
	# Punto de espera de las salidas en la cabecera en uso.
	var hp := Game.hold_point()
	draw_line(hp + Vector2(-8, -6), hp + Vector2(8, -6), C_WARN, 2.0)
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
	var d := Game.wind_dir
	var col := C_RUNWAY
	if r["closed"] > 0.0:
		col = C_RUNWAY_CLOSED
	elif not r["op"].is_empty():
		col = C_RUNWAY_BUSY
	elif not r["lined"].is_empty():
		col = C_RUNWAY_LINED
	var rect := Rect2(Vector2(Game.RUNWAY_X0, y - 9), Vector2(Game.RUNWAY_X1 - Game.RUNWAY_X0, 18))
	draw_rect(rect, col)
	if Game.runway_stormy(i):
		draw_rect(rect, Color(C_STORM_CORE, 0.35))
	# Marcas: umbral en la cabecera en uso, eje discontinuo y numeración.
	var tx := Game.threshold(i).x
	var mark_x: float = tx + 4.0 if d > 0 else tx - 18.0
	for k in 4:
		draw_rect(Rect2(Vector2(mark_x, y - 7 + k * 4), Vector2(14, 2)), C_MARK)
	draw_dashed_line(Vector2(Game.RUNWAY_X0 + 40, y), Vector2(Game.RUNWAY_X1 - 40, y), C_MARK, 1.0, 10.0)
	# Senda de aproximación prolongada.
	draw_dashed_line(Game.threshold(i) - Vector2(d * Game.FINAL_DIST, 0), Game.threshold(i), Color(1, 1, 1, 0.15), 1.0, 6.0)
	var label := "P%d %s" % [i + 1, Game.runway_name()]
	if r["closed"] > 0.0:
		label += " CERRADA %ds" % ceil(r["closed"])
	elif Game.runway_stormy(i):
		label += " TORMENTA"
	if Game.levels.get("wake_monitor", 0) > 0:
		var left := Game.separation_left(i, 0)
		if left > 0.0:
			label += " estela %ds" % ceil(left)
	draw_string(_font, Vector2(Game.RUNWAY_X0 + 30, y - 11), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C_TEXT)


func _draw_storms() -> void:
	for s in Game.storms:
		var c: Vector2 = s["pos"]
		var r: float = s["radius"]
		draw_circle(c, r, Color(C_STORM, 0.16))
		draw_circle(c, r * 0.6, Color(1.0, 0.85, 0.2, 0.18))
		draw_circle(c, r * 0.3, Color(C_STORM_CORE, 0.25))
		draw_arc(c, r, 0, TAU, 48, Color(C_STORM, 0.6), 2.0)
		if Game.levels.get("meteo", 0) > 0:
			# Trayectoria prevista de los próximos 20 s.
			var ahead: Vector2 = c + s["vel"] * 20.0
			draw_dashed_line(c, ahead, Color(C_STORM, 0.7), 2.0, 12.0)
			draw_arc(ahead, r, 0, TAU, 48, Color(C_STORM, 0.25), 1.0)


func _draw_route(p: Dictionary) -> void:
	if p["state"] == "holding":
		draw_arc(p["hold_center"], Game.HOLD_RADIUS, 0, TAU, 48, Color(C_SELECTED, 0.4), 1.0)
	var at: Vector2 = p["pos"]
	for w in p["path"]:
		draw_dashed_line(at, w, Color(C_SELECTED, 0.6), 1.0, 5.0)
		at = w


## Pista en uso, aviso de cambio de viento y hora punta, en la esquina.
func _draw_wind_panel() -> void:
	var at := Vector2(12, 22)
	var arrow := "→" if Game.wind_dir > 0 else "←"
	_draw_text("Pistas en uso %s %s" % [Game.runway_name(), arrow], at, 16, C_TEXT)
	if Game.wind_change_in >= 0.0:
		var blink := int(Game.shift_elapsed * 3.0) % 2 == 0
		_draw_text("Cambio a %s en %ds" % [Game.runway_name(-Game.wind_dir), ceil(Game.wind_change_in)], at + Vector2(0, 20), 16, C_WARN if blink else C_EMERGENCY)
	if Game.is_rush_hour():
		_draw_text("HORA PUNTA", at + Vector2(0, 40), 16, C_EMERGENCY)


func _plane_color(p: Dictionary) -> Color:
	var col := C_ARRIVAL if p["arrival"] else C_DEPARTURE
	match p.get("special", ""):
		"vip": col = C_VIP
		"cargo": col = C_CARGO
	if p["emergency"]:
		col = C_EMERGENCY
	var blink := (Time.get_ticks_msec() / 160) % 2 == 0
	if p["arrival"] and Game.is_airborne(p) and p.get("mayday", false) and blink:
		col = C_WARN
	return col


func _draw_plane(p: Dictionary, trail: Array) -> void:
	var pos := _to_screen(p["pos"])
	var col := _plane_color(p)
	for k in trail.size():
		var dot := col
		dot.a = 0.5 * (1.0 - float(k) / TRAIL_POINTS)
		draw_circle(_to_screen(trail[k]), 1.6, dot)
	var wake: int = p["wake"]
	var scale_px: float = (7.0 + 2.5 * wake) * max(_scale() * 1.4, 0.8)
	# La sombra se separa del avión con la altitud: da sensación de altura en una vista 2D.
	var lift: float = min(p["alt"] / 1000.0 * 3.0, 24.0)
	_draw_silhouette(pos + Vector2(lift, lift), p["heading"], scale_px, C_SHADOW)
	_draw_silhouette(pos, p["heading"], scale_px, col)
	var selected: bool = p["id"] == selected_id and replay_frames.is_empty()
	if selected:
		draw_arc(pos, scale_px + 8.0, 0, TAU, 32, C_SELECTED, 2.0)
	if p.get("conflict", false):
		draw_arc(pos, scale_px + 13.0, 0, TAU, 32, C_WARN, 2.0)
	var tag: String = p["callsign"]
	if Game.is_airborne(p):
		tag += "  %03d" % int(round(p["alt"] / 100.0))
		if p["target_alt"] != p["alt"] and p["state"] in ["holding", "inbound", "go_around", "climb"]:
			tag += "↑" if p["target_alt"] > p["alt"] else "↓"
	_draw_text(tag, pos + Vector2(scale_px + 4, -scale_px), 12, C_SELECTED if selected else C_TEXT)
	# Barra de combustible de las llegadas en vuelo.
	if p["arrival"] and Game.is_airborne(p) and p["state"] != "divert":
		var frac: float = clamp(p["fuel"] / Game.FUEL_RANGE.y, 0.0, 1.0)
		var bar := Rect2(pos + Vector2(scale_px + 4, -scale_px + 4), Vector2(34, 3))
		draw_rect(bar, Color(0, 0, 0, 0.6))
		var fc := C_DEPARTURE if p["fuel"] > 40.0 else (C_EMERGENCY if p["fuel"] > Game.MAYDAY_FUEL else C_WARN)
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * frac, bar.size.y)), fc)


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
