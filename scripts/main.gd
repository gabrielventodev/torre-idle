extends Control
## Interfaz de la torre con tres pantallas: turno (radar + radio), cobro y tienda.
## Se construye por código para que el prototipo sea fácil de modificar; los botones se
## reutilizan en vez de recrearse para no perder clics entre refrescos.

const COLOR_BG := Color("101820")
const COLOR_ARRIVAL := Color("8ecbff")
const COLOR_DEPARTURE := Color("9be89b")
const COLOR_WARN := Color("ff6b5b")
const COLOR_EMERGENCY := Color("ffb347")
const COLOR_MUTED := Color("8a96a3")
const TRAFFIC_ROWS := 14
const RADIO_LINES := 8
const RadarView := preload("res://scripts/radar_view.gd")

var _status_label: Label
var _shift_view: VBoxContainer
var _payday_view: VBoxContainer
var _shop_view: VBoxContainer

# Turno.
var _clock_label: Label
var _shift_info: Label
var _event_label: Label
var _end_day_button: Button
var _radar: Control
var _traffic_buttons: Array[Button] = []
var _selected_label: Label
var _action_buttons: Array[Button] = []
var _radio_label: Label
var _radio_log: Array[String] = []
var _airport_label: Label

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

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	view.add_child(body)

	_radar = RadarView.new()
	_radar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_radar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_radar.plane_selected.connect(func(_id): pass)
	body.add_child(_radar)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(380, 0)
	side.add_theme_constant_override("separation", 6)
	body.add_child(side)

	_label(side, "AVIÓN SELECCIONADO", 15)
	_selected_label = _label(side, "", 14)
	_selected_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var actions := HFlowContainer.new()
	side.add_child(actions)
	for j in Game.MAX_RUNWAYS:
		var b := Button.new()
		b.add_theme_font_size_override("font_size", 13)
		b.pressed.connect(func(): _on_action(b))
		actions.add_child(b)
		_action_buttons.append(b)

	_label(side, "RADIO", 15)
	_radio_label = _label(side, "", 12)
	_radio_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_radio_label.custom_minimum_size = Vector2(0, 150)
	_radio_label.add_theme_color_override("font_color", Color(0.72, 1.0, 0.84))

	_label(side, "TRÁFICO", 15)
	var traffic := HFlowContainer.new()
	side.add_child(traffic)
	for i in TRAFFIC_ROWS:
		var b := Button.new()
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(func(): _radar.selected_id = b.get_meta("plane_id", -1))
		traffic.add_child(b)
		_traffic_buttons.append(b)

	_airport_label = _label(side, "", 12)
	_airport_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_airport_label.add_theme_color_override("font_color", COLOR_MUTED)

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


## Ejecuta la orden guardada en el botón y la transmite por radio con la colación del piloto.
func _on_action(b: Button) -> void:
	var action: String = b.get_meta("action", "")
	var p: Dictionary = Game._find(b.get_meta("plane_id", -1))
	var runway: int = b.get_meta("runway", -1)
	if p.is_empty():
		return
	var cs: String = p["callsign"]
	var ok := false
	var order := ""
	var readback := ""
	match action:
		"land":
			ok = Game.clear_landing(p["id"], runway)
			order = "%s, pista %d, autorizado a aterrizar." % [cs, runway + 1]
			readback = "Autorizado a aterrizar pista %d, %s." % [runway + 1, cs]
		"push":
			ok = Game.push_back(p["id"])
			order = "%s, push-back aprobado, ruede al punto de espera." % cs
			readback = "Push-back y rodaje al punto de espera, %s." % cs
		"line_up":
			ok = Game.line_up(p["id"], runway)
			order = "%s, entre en pista %d y espere." % [cs, runway + 1]
			readback = "Entrando en pista %d y esperando, %s." % [runway + 1, cs]
		"takeoff":
			ok = Game.clear_takeoff(p["id"])
			order = "%s, pista %d, autorizado a despegar." % [cs, p["runway"] + 1]
			readback = "Autorizado a despegar, %s." % cs
	if ok:
		_radio("TWR: " + order)
		_radio(cs + ": " + readback)


func _radio(line: String) -> void:
	_radio_log.push_front(line)
	if _radio_log.size() > RADIO_LINES:
		_radio_log.pop_back()
	_radio_label.text = "\n".join(_radio_log)


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

	_refresh_selected()
	_refresh_traffic()
	var lines := []
	for i in Game.runways.size():
		var r: Dictionary = Game.runways[i]
		var state := "libre"
		if not r["op"].is_empty():
			state = "ocupada por %s" % r["op"]["callsign"]
		elif not r["lined"].is_empty():
			state = "%s alineado" % r["lined"]["callsign"]
		lines.append("P%d: %s" % [i + 1, state])
	lines.append("Puertas ocupadas: %d de %d" % [Game.gates_used(), Game.gate_count()])
	lines.append("Estela: tras H esperar 6 s a L, 4 s a M y 3 s a H; tras M, 3 s a L. Un aterrizaje toca pista %d s después de autorizarlo." % Game.FINAL_TIME)
	_airport_label.text = "\n".join(lines)


func _refresh_selected() -> void:
	var p: Dictionary = Game._find(_radar.selected_id)
	if p.is_empty():
		_selected_label.text = "Ninguno. Haz clic en un avión del radar o de la lista de tráfico."
		_fill_actions(p)
		return
	var text := "%s · %s · estela %s\n%d pasajeros · paga %s $\n%s" % [
		p["callsign"], p["model"], Game.WAKE_NAMES[p["wake"]], p["pax"],
		Game.format_number(Game.plane_value(p)), _state_text(p)]
	if p["emergency"]:
		text += "\nEMERGENCIA MÉDICA: prioridad absoluta"
	_selected_label.text = text
	_fill_actions(p)


func _refresh_traffic() -> void:
	var planes := Game.planes
	for i in _traffic_buttons.size():
		var b := _traffic_buttons[i]
		if i >= planes.size():
			b.visible = false
			continue
		var p: Dictionary = planes[i]
		b.visible = true
		b.set_meta("plane_id", p["id"])
		b.text = "%s %s" % ["▼" if p["arrival"] else "▲", p["callsign"]]
		var c := COLOR_ARRIVAL if p["arrival"] else COLOR_DEPARTURE
		if p["emergency"]:
			c = COLOR_EMERGENCY
		elif p["state"] in ["approach", "final"] and p["fuel"] < 10.0:
			c = COLOR_WARN
		b.add_theme_color_override("font_color", c)
		b.add_theme_color_override("font_hover_color", c)


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


## Muestra solo las órdenes de radio posibles en la fase actual del avión seleccionado.
func _fill_actions(p: Dictionary) -> void:
	var actions := []
	if not p.is_empty():
		match p["state"]:
			"approach":
				for r in Game.runways.size():
					actions.append(["land", r, "Autorizar aterrizaje P%d" % (r + 1), true])
			"gate":
				actions.append(["push", -1, "Aprobar push-back", true])
			"holding":
				for r in Game.runways.size():
					actions.append(["line_up", r, "Entrar y esperar P%d" % (r + 1), Game.runway_clear(r)])
			"lined_up":
				actions.append(["takeoff", -1, "Autorizar despegue", true])
	for j in _action_buttons.size():
		var b: Button = _action_buttons[j]
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
	if Game.phase == Game.Phase.SHIFT:
		_radio("TWR: " + text)
