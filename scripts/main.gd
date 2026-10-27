extends Control
## Interfaz de la torre con tres pantallas: turno, cobro y tienda.
## Se construye por código para que el prototipo sea fácil de modificar; las filas y botones se
## reutilizan en vez de recrearse para no perder clics entre refrescos.

const COLOR_BG := Color("101820")
const COLOR_ARRIVAL := Color("8ecbff")
const COLOR_DEPARTURE := Color("9be89b")
const COLOR_WARN := Color("ff6b5b")
const COLOR_EMERGENCY := Color("ffb347")
const COLOR_MUTED := Color("8a96a3")
const ROWS_PER_COLUMN := 12

var _status_label: Label
var _shift_view: VBoxContainer
var _payday_view: VBoxContainer
var _shop_view: VBoxContainer

# Turno.
var _clock_label: Label
var _shift_info: Label
var _event_label: Label
var _end_day_button: Button
## Cada fila: {"box", "label", "buttons": Array[Button]}. Los botones guardan en metadatos la acción.
var _arrival_rows: Array = []
var _departure_rows: Array = []
var _runway_labels: Array[Label] = []
var _gates_label: Label

# Cobro.
var _summary_label: Label

# Tienda.
var _shop_money: Label
var _upgrade_buttons := {}
var _prestige_button: Button
var _tree_buttons := {}
var _next_day_button: Button

var _toast_label: Label
var _toast_time := 0.0
var _last_phase := -1


func _ready() -> void:
	_build_ui()
	Game.toast.connect(_on_toast)


func _process(delta: float) -> void:
	_refresh()
	if _toast_time > 0.0:
		_toast_time -= delta
		if _toast_time <= 0.0:
			_toast_label.text = ""


# --- Construcción ----------------------------------------------------------

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	_status_label = _label(root, "", 20)

	_shift_view = _build_shift_view(root)
	_payday_view = _build_payday_view(root)
	_shop_view = _build_shop_view(root)

	_toast_label = _label(root, "", 15)


func _build_shift_view(parent: Node) -> VBoxContainer:
	var view := _view(parent)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 32)
	view.add_child(top)
	_clock_label = _label(top, "", 28)
	_shift_info = _label(top, "", 15)

	_event_label = _label(view, "", 16)
	_event_label.add_theme_color_override("font_color", COLOR_EMERGENCY)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 20)
	view.add_child(columns)
	_arrival_rows = _strip_column(columns, "LLEGADAS")
	_departure_rows = _strip_column(columns, "SALIDAS")

	var runway_col := _column(columns, "PISTAS")
	runway_col.size_flags_horizontal = Control.SIZE_FILL
	runway_col.custom_minimum_size = Vector2(280, 0)
	for i in Game.MAX_RUNWAYS:
		var l := _label(runway_col, "", 14)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_runway_labels.append(l)
	_gates_label = _label(runway_col, "", 14)
	var help := _label(runway_col, "", 12)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_color_override("font_color", COLOR_MUTED)
	help.text = "Separación por estela tras un avión:\nH (pesado): 6 s a L, 4 s a M, 3 s a H\nM (medio): 3 s a L\nNo autorices un aterrizaje si la pista estará ocupada al tocar tierra (%d s)." % Game.FINAL_TIME

	_end_day_button = _big_button(view, "Terminar el día", func(): Game.end_day())
	return view


func _build_payday_view(parent: Node) -> VBoxContainer:
	var view := _view(parent)
	_label(view, "FIN DEL TURNO", 24)
	_summary_label = _label(view, "", 18)
	_big_button(view, "Cobrar", func(): Game.collect_pay())
	return view


func _build_shop_view(parent: Node) -> VBoxContainer:
	var view := _view(parent)
	_shop_money = _label(view, "", 22)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	view.add_child(scroll)
	var grid := HBoxContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("separation", 24)
	scroll.add_child(grid)

	var upgrades := _column(grid, "MEJORAS")
	for id in Game.UPGRADES:
		_upgrade_buttons[id] = _list_button(upgrades, func(): Game.buy(id))

	var prestige := _column(grid, "PRESTIGIO")
	_prestige_button = _list_button(prestige, func(): Game.prestige())
	for id in Game.XP_TREE:
		_tree_buttons[id] = _list_button(prestige, func(): Game.buy_tree(id))

	_next_day_button = _big_button(view, "", func(): Game.next_day())
	return view


func _view(parent: Node) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	parent.add_child(v)
	return v


func _label(parent: Node, text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	parent.add_child(l)
	return l


func _column(parent: Node, title: String) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(col)
	_label(col, title, 16)
	return col


func _list_button(parent: Node, on_press: Callable) -> Button:
	var b := Button.new()
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b


func _big_button(parent: Node, text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(260, 44)
	b.size_flags_horizontal = Control.SIZE_SHRINK_END
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b


## Crea filas fijas de tira de vuelo: un texto y hasta MAX_RUNWAYS botones de acción.
func _strip_column(parent: Node, title: String) -> Array:
	var col := _column(parent, title)
	var rows := []
	for i in ROWS_PER_COLUMN:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)
		col.add_child(box)
		var label := _label(box, "", 14)
		var buttons_row := HBoxContainer.new()
		box.add_child(buttons_row)
		var buttons: Array[Button] = []
		for j in Game.MAX_RUNWAYS:
			var b := Button.new()
			b.add_theme_font_size_override("font_size", 13)
			b.pressed.connect(func(): _on_action(b))
			buttons_row.add_child(b)
			buttons.append(b)
		rows.append({"box": box, "label": label, "buttons": buttons})
	return rows


## Ejecuta la acción guardada en el botón: [acción, id del avión, pista].
func _on_action(b: Button) -> void:
	var action: String = b.get_meta("action", "")
	var plane_id: int = b.get_meta("plane_id", -1)
	var runway: int = b.get_meta("runway", -1)
	match action:
		"land": Game.clear_landing(plane_id, runway)
		"push": Game.push_back(plane_id)
		"line_up": Game.line_up(plane_id, runway)
		"takeoff": Game.clear_takeoff(plane_id)


# --- Refresco --------------------------------------------------------------

func _refresh() -> void:
	# Los avisos del turno no deben seguir visibles en el cobro ni en la tienda.
	if Game.phase != _last_phase:
		_last_phase = Game.phase
		_toast_label.text = ""
	_status_label.text = "Día %d · %s · %s $ · XP %d" % [
		Game.day, Game.AIRPORTS[Game.airport_level], Game.format_number(Game.money), Game.xp_available]
	_shift_view.visible = Game.phase == Game.Phase.SHIFT
	_payday_view.visible = Game.phase == Game.Phase.PAYDAY
	_shop_view.visible = Game.phase == Game.Phase.SHOP
	match Game.phase:
		Game.Phase.SHIFT: _refresh_shift()
		Game.Phase.PAYDAY: _refresh_payday()
		Game.Phase.SHOP: _refresh_shop()


func _refresh_shift() -> void:
	var h := Game.clock_hours()
	_clock_label.text = "%02d:%02d" % [int(h), int(fmod(h, 1.0) * 60.0)]
	_shift_info.text = "Por llegar: %d de %d · Aterrizados: %d · Despegados: %d · Por cobrar: %s $ · Multas: %s $" % [
		Game.planes_pending(), Game.planes_total, Game.day_landed, Game.day_departed,
		Game.format_number(Game.day_pay + Game.day_bonus), Game.format_number(Game.day_fines)]

	var event_text := ""
	match Game.event_id:
		"storm": event_text = "TORMENTA %ds · las pistas tardan más, evita desvíos y motores y al aire" % ceil(Game.event_time)
		"emergency": event_text = "EMERGENCIA · aterriza el avión naranja cuanto antes"
	if Game.shift_done():
		event_text = "Torre: no vienen más aviones hoy. Puedes terminar el día."
	_event_label.text = event_text
	_end_day_button.disabled = not Game.shift_done()

	_fill_rows(_arrival_rows, Game.arrivals(), COLOR_ARRIVAL)
	_fill_rows(_departure_rows, Game.departures(), COLOR_DEPARTURE)

	for i in _runway_labels.size():
		_runway_labels[i].text = _runway_text(i)
	_gates_label.text = "Puertas ocupadas: %d de %d" % [Game.gates_used(), Game.gate_count()]


func _runway_text(i: int) -> String:
	if i >= Game.runways.size():
		return "P%d · cerrada" % (i + 1)
	var r: Dictionary = Game.runways[i]
	var parts := []
	if not r["op"].is_empty():
		var verb := "aterrizando" if r["op"]["arrival"] else "despegando"
		parts.append("%s %s %.1fs" % [r["op"]["callsign"], verb, r["op_left"]])
	if not r["lined"].is_empty():
		parts.append("%s alineado" % r["lined"]["callsign"])
	for p in Game.finals_on(i):
		parts.append("%s en final, toca en %.1fs" % [p["callsign"], p["timer"]])
	if parts.is_empty():
		parts.append("libre")
	var text := "P%d · %s" % [i + 1, " · ".join(parts)]
	if r["prev_wake"] >= 0:
		text += "\n    última estela: %s" % Game.WAKE_NAMES[r["prev_wake"]]
		if Game.levels["wake_monitor"] > 0:
			text += " · falta %.1fs para L, %.1fs para M" % [Game.separation_left(i, 0), Game.separation_left(i, 1)]
	return text


func _fill_rows(rows: Array, planes: Array, color: Color) -> void:
	for i in rows.size():
		var row: Dictionary = rows[i]
		if i >= planes.size():
			row["box"].visible = false
			continue
		row["box"].visible = true
		var p: Dictionary = planes[i]
		var label: Label = row["label"]
		label.text = "%s  %s (%s)  %s $ · %s" % [
			p["callsign"], p["model"], Game.WAKE_NAMES[p["wake"]],
			Game.format_number(Game.plane_value(p)), _state_text(p)]
		var c := color
		if p["emergency"]:
			c = COLOR_EMERGENCY
		elif p["state"] in ["approach", "final"] and p["fuel"] < 10.0:
			c = COLOR_WARN
		label.add_theme_color_override("font_color", c)
		_fill_buttons(row["buttons"], p)


func _state_text(p: Dictionary) -> String:
	match p["state"]:
		"approach": return "aproximación, combustible %ds" % ceil(p["fuel"])
		"final": return "final P%d, toca en %.1fs" % [p["runway"] + 1, p["timer"]]
		"landing": return "aterrizando en P%d" % (p["runway"] + 1)
		"taxi_in": return "rodando a puerta %.0fs" % p["timer"]
		"wait_gate": return "esperando puerta libre"
		"gate": return "en puerta, espera %ds" % int(p["wait"])
		"taxi_out": return "push-back y rodaje %.0fs" % p["timer"]
		"holding": return "en punto de espera"
		"lined_up": return "alineado en P%d" % (p["runway"] + 1)
		"takeoff": return "despegando de P%d" % (p["runway"] + 1)
	return p["state"]


## Muestra solo las acciones posibles en la fase actual del avión.
func _fill_buttons(buttons: Array, p: Dictionary) -> void:
	var actions := []
	match p["state"]:
		"approach":
			for r in Game.runways.size():
				actions.append(["land", r, "Aterrizar P%d" % (r + 1), true])
		"gate":
			actions.append(["push", -1, "Push-back", true])
		"holding":
			for r in Game.runways.size():
				actions.append(["line_up", r, "Entrar P%d" % (r + 1), Game.runway_clear(r)])
		"lined_up":
			actions.append(["takeoff", -1, "Despegar", true])
	for j in buttons.size():
		var b: Button = buttons[j]
		if j >= actions.size():
			b.visible = false
			continue
		var a: Array = actions[j]
		b.visible = true
		b.text = a[2]
		b.disabled = not a[3]
		b.set_meta("action", a[0])
		b.set_meta("plane_id", p["id"])
		b.set_meta("runway", a[1])


func _refresh_payday() -> void:
	var s: Dictionary = Game.last_summary
	var text := "Día %d\n\nAterrizajes: %d\nDespegues: %d\nDesvíos: %d\nMotor y al aire: %d\nInfracciones de separación: %d\n\nPago por aviones: %s $" % [
		s["day"], s["landed"], s["departed"], s["diverted"], s["go_arounds"], s["infractions"],
		Game.format_number(s["pay"])]
	if s["bonus"] > 0.0:
		text += "\nBonificación por crisis: %s $" % Game.format_number(s["bonus"])
	if s["fines"] > 0.0:
		text += "\nMultas: -%s $" % Game.format_number(s["fines"])
	text += "\n\nTotal: %s $" % Game.format_number(s["total"])
	_summary_label.text = text


func _refresh_shop() -> void:
	_shop_money.text = "Caja: %s $ · Mañana llegan %d aviones" % [Game.format_number(Game.money), Game.planes_per_day()]
	for id in _upgrade_buttons:
		var u: Dictionary = Game.UPGRADES[id]
		var b: Button = _upgrade_buttons[id]
		var cost := "MÁX" if Game.upgrade_maxed(id) else "%s $" % Game.format_number(Game.upgrade_cost(id))
		b.text = "%s (nivel %d) · %s\n%s" % [u["name"], _display_level(id), cost, u["desc"]]
		b.disabled = not Game.can_buy(id)

	_prestige_button.text = "Mudarse de aeropuerto · +%d XP (necesitas %s $ ganados)" % [
		Game.xp_gain(), Game.format_number(Game.prestige_threshold())]
	_prestige_button.disabled = not Game.can_prestige()
	for id in _tree_buttons:
		var node: Dictionary = Game.XP_TREE[id]
		var owned: bool = Game.tree_owned.get(id, false)
		var b: Button = _tree_buttons[id]
		b.text = "%s · %s" % [node["name"], "comprado" if owned else "%d XP" % node["cost"]]
		b.disabled = owned or Game.xp_available < node["cost"]
	_next_day_button.text = "Empezar día %d" % (Game.day + 1)


## "Más tráfico" empieza en nivel 1 (2 aviones); el resto empieza en 0.
func _display_level(id: String) -> int:
	return Game.levels[id] + (1 if id == "traffic" else 0)


func _on_toast(text: String) -> void:
	_toast_label.text = text
	_toast_time = 5.0
