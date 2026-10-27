extends Control
## Interfaz de la torre con tres pantallas: turno, cobro y tienda.
## Se construye por código para que el prototipo sea fácil de modificar; los botones se reutilizan
## en vez de recrearse para no perder clics entre refrescos.

const COLOR_BG := Color("101820")
const COLOR_ARRIVAL := Color("8ecbff")
const COLOR_DEPARTURE := Color("9be89b")
const COLOR_WARN := Color("ff6b5b")
const COLOR_EMERGENCY := Color("ffb347")

var _status_label: Label
var _shift_view: VBoxContainer
var _payday_view: VBoxContainer
var _shop_view: VBoxContainer

# Turno.
var _clock_label: Label
var _shift_info: Label
var _event_label: Label
var _vip_button: Button
var _end_day_button: Button
var _arrival_buttons: Array[Button] = []
var _departure_buttons: Array[Button] = []
var _runway_labels: Array[Label] = []

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
	root.add_theme_constant_override("separation", 12)
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
	_shift_info = _label(top, "", 16)

	var event_row := HBoxContainer.new()
	view.add_child(event_row)
	_event_label = _label(event_row, "", 16)
	_event_label.add_theme_color_override("font_color", COLOR_EMERGENCY)
	_vip_button = Button.new()
	_vip_button.text = "Reservar pista para el VIP"
	_vip_button.pressed.connect(func(): Game.reserve_vip())
	event_row.add_child(_vip_button)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 24)
	view.add_child(columns)
	_arrival_buttons = _strip_column(columns, "LLEGADAS")
	_departure_buttons = _strip_column(columns, "SALIDAS")
	var runway_col := _column(columns, "PISTAS")
	for i in Game.MAX_RUNWAYS:
		_runway_labels.append(_label(runway_col, "", 15))

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
	v.add_theme_constant_override("separation", 12)
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
	b.custom_minimum_size = Vector2(260, 48)
	b.size_flags_horizontal = Control.SIZE_SHRINK_END
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b


## Crea un grupo fijo de botones-tira; cada uno lee en su metadato el id del avión que muestra.
func _strip_column(parent: Node, title: String) -> Array[Button]:
	var col := _column(parent, title)
	var buttons: Array[Button] = []
	for i in Game.MAX_QUEUE:
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 40)
		b.pressed.connect(func(): Game.approve(b.get_meta("plane_id", -1)))
		col.add_child(b)
		buttons.append(b)
	return buttons


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
	_shift_info.text = "Por llegar: %d de %d · Coordinados: %d · Desviados: %d · Por cobrar: %s $" % [
		Game.planes_pending(), Game.planes_total, Game.day_landed, Game.day_diverted,
		Game.format_number(Game.day_pay + Game.day_bonus)]

	var event_text := ""
	match Game.event_id:
		"storm": event_text = "TORMENTA %ds · evita desvíos" % ceil(Game.event_time)
		"emergency": event_text = "EMERGENCIA · aprueba el avión naranja"
		"vip": event_text = "VUELO VIP %ds · reserva una pista" % ceil(Game.event_time)
	if Game.shift_done():
		event_text = "Torre: no vienen más aviones hoy. Puedes terminar el día."
	_event_label.text = event_text
	_vip_button.visible = Game.event_id == "vip"
	_end_day_button.disabled = not Game.shift_done()

	_fill_strips(_arrival_buttons, Game.arrivals, COLOR_ARRIVAL)
	_fill_strips(_departure_buttons, Game.departures, COLOR_DEPARTURE)

	for i in _runway_labels.size():
		var l := _runway_labels[i]
		if i >= Game.runways.size():
			l.text = "Pista %d · cerrada" % (i + 1)
			continue
		var r: Dictionary = Game.runways[i]
		if r["vip"]:
			l.text = "Pista %d · reservada VIP %.1fs" % [i + 1, r["time_left"]]
		elif r["time_left"] > 0.0:
			l.text = "Pista %d · %s %.1fs" % [i + 1, r["plane"]["callsign"], r["time_left"]]
		else:
			l.text = "Pista %d · libre" % (i + 1)


func _refresh_payday() -> void:
	var s: Dictionary = Game.last_summary
	var text := "Día %d\n\nAviones coordinados: %d\nAviones desviados: %d\nPago por aviones: %s $" % [
		s["day"], s["landed"], s["diverted"], Game.format_number(s["pay"])]
	if s["bonus"] > 0.0:
		text += "\nBonificación por crisis: %s $" % Game.format_number(s["bonus"])
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


func _fill_strips(buttons: Array[Button], queue: Array, color: Color) -> void:
	for i in buttons.size():
		var b := buttons[i]
		if i >= queue.size():
			b.visible = false
			continue
		var p: Dictionary = queue[i]
		b.visible = true
		b.set_meta("plane_id", p["id"])
		var detail := "combustible %ds" % ceil(p["fuel"]) if p["arrival"] else "espera %ds" % int(p["wait"])
		b.text = "%s   %s   %s $   %s" % [p["callsign"], p["model"], Game.format_number(Game.plane_value(p)), detail]
		var c := color
		if p["emergency"]:
			c = COLOR_EMERGENCY
		elif p["arrival"] and p["fuel"] < 10.0:
			c = COLOR_WARN
		b.add_theme_color_override("font_color", c)
		b.add_theme_color_override("font_hover_color", c)


func _on_toast(text: String) -> void:
	_toast_label.text = text
	_toast_time = 5.0
