extends Control
## Interfaz de la torre: menú, turno (mapa + radio), resumen del día, elección de carta y despido.
## Se construye por código para que el prototipo sea fácil de modificar; los botones se
## reutilizan en vez de recrearse para no perder clics entre refrescos.

const COLOR_BG := Color("101820")
const COLOR_ARRIVAL := Color("8ecbff")
const COLOR_DEPARTURE := Color("9be89b")
const COLOR_WARN := Color("ff6b5b")
const COLOR_EMERGENCY := Color("ffb347")
const COLOR_VIP := Color("ffd700")
const COLOR_CARGO := Color("c49cff")
const COLOR_MUTED := Color("8a96a3")
const COLOR_UPGRADE := Color("9be89b")
const COLOR_CONTRACT := Color("ffb347")
const TRAFFIC_ROWS := 18
const RADIO_LINES := 8
const MapView := preload("res://scripts/map_view.gd")
const ACTION_BUTTONS := 10
const REPLAY_BUTTONS := 4
## Cámara lenta al producirse un incidente: escala de tiempo y duración en milisegundos reales.
const SLOWMO_SCALE := 0.25
const SLOWMO_MS := 1800

var _status_label: Label
var _menu_view: VBoxContainer
var _shift_view: VBoxContainer
var _payday_view: VBoxContainer
var _draft_view: VBoxContainer
var _gameover_view: VBoxContainer

# Menú.
var _continue_button: Button
var _daily_button: Button
var _records_label: Label

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

# Resumen del día y despido: cada uno con su visor de repeticiones.
var _summary_label: Label
var _payday_replay: Control
var _payday_replay_buttons: Array[Button] = []
var _gameover_label: Label
var _gameover_replay: Control
var _gameover_replay_buttons: Array[Button] = []

# Cartas.
var _draft_title: Label
var _card_buttons: Array[Button] = []
var _draft_info: Label

var _toast_label: Label
var _toast_time := 0.0
var _last_phase := -1
var _slowmo_until := 0


func _ready() -> void:
	_build_ui()
	Game.toast.connect(_on_toast)
	Game.incident.connect(_on_incident)


func _process(delta: float) -> void:
	if _slowmo_until > 0 and Time.get_ticks_msec() > _slowmo_until:
		_slowmo_until = 0
		Engine.time_scale = 1.0
	_refresh()
	if _toast_time > 0.0:
		_toast_time -= delta / max(Engine.time_scale, 0.01)
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

	_menu_view = _build_menu_view(root)
	_shift_view = _build_shift_view(root)
	_payday_view = _build_payday_view(root)
	_draft_view = _build_draft_view(root)
	_gameover_view = _build_gameover_view(root)

	_toast_label = _label(root, "", 15)


func _build_menu_view(parent: Node) -> VBoxContainer:
	var view := _view(parent)
	_label(view, "TORRE DE CONTROL", 40)
	var pitch := _label(view, "Aguanta todos los días que puedas en la torre. Cada día trae más tráfico, tormentas, cambios de viento y emergencias. Entre turnos eliges una carta: mejoras para tu aeropuerto o contratos que traen más aviones y más dinero.\n\nTres incidentes (un desvío por combustible o un aviso TCAS) y te despiden. Una colisión te despide en el acto.", 16)
	pitch.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pitch.custom_minimum_size = Vector2(700, 0)
	_continue_button = _big_button(view, "Continuar partida", func(): Game.load_run())
	_big_button(view, "Nueva partida", func(): Game.new_run(false))
	_daily_button = _big_button(view, "", func(): Game.new_run(true))
	for b in [_continue_button, _daily_button]:
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	view.get_child(view.get_child_count() - 2).size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_records_label = _label(view, "", 16)
	_records_label.add_theme_color_override("font_color", COLOR_MUTED)
	return view


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

	_radar = MapView.new()
	_radar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_radar.size_flags_vertical = Control.SIZE_EXPAND_FILL
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
	for j in ACTION_BUTTONS:
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
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 16)
	view.add_child(row)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(360, 0)
	row.add_child(left)
	_summary_label = _label(left, "", 17)
	_payday_replay = _replay_panel(row, _payday_replay_buttons)
	_big_button(view, "Elegir carta", func(): Game.open_draft())
	return view


func _build_draft_view(parent: Node) -> VBoxContainer:
	var view := _view(parent)
	_draft_title = _label(view, "", 26)
	_label(view, "Elige una carta. Las mejoras hacen tu aeropuerto más capaz; los contratos traen más tráfico y más dinero.", 15)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	view.add_child(row)
	for i in 3:
		var b := Button.new()
		b.custom_minimum_size = Vector2(300, 220)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.add_theme_font_size_override("font_size", 17)
		b.pressed.connect(func(): Game.pick_card(i))
		row.add_child(b)
		_card_buttons.append(b)
	_draft_info = _label(view, "", 15)
	_draft_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_draft_info.add_theme_color_override("font_color", COLOR_MUTED)
	return view


func _build_gameover_view(parent: Node) -> VBoxContainer:
	var view := _view(parent)
	var title := _label(view, "ESTÁS DESPEDIDO", 36)
	title.add_theme_color_override("font_color", COLOR_WARN)
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 16)
	view.add_child(row)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(360, 0)
	row.add_child(left)
	_gameover_label = _label(left, "", 17)
	_gameover_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_gameover_replay = _replay_panel(row, _gameover_replay_buttons)
	_big_button(view, "Volver al menú", func(): Game.back_to_menu())
	return view


## Visor de repeticiones: botones para elegir el incidente y un tablero que lo reproduce.
func _replay_panel(parent: Node, buttons: Array[Button]) -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(col)
	var flow := HFlowContainer.new()
	col.add_child(flow)
	var view := MapView.new()
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.custom_minimum_size = Vector2(0, 300)
	for i in REPLAY_BUTTONS:
		var b := Button.new()
		b.add_theme_font_size_override("font_size", 13)
		b.pressed.connect(func(): view.play_replay(Game.replays[i]))
		flow.add_child(b)
		buttons.append(b)
	col.add_child(view)
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
	var altitude: int = b.get_meta("altitude", 0)
	if p.is_empty():
		return
	var cs: String = p["callsign"]
	var rwy := "%d %s" % [runway + 1, Game.runway_name()]
	var ok := false
	var order := ""
	var readback := ""
	match action:
		"hold":
			ok = Game.hold_at(p["id"], altitude)
			order = "%s, mantenga %d pies y espere en circuito donde está." % [cs, altitude]
			readback = "Mantenemos %d pies en espera, %s." % [altitude, cs]
		"land":
			ok = Game.clear_landing(p["id"], runway)
			order = "%s, pista %s, autorizado a aterrizar." % [cs, rwy]
			readback = "Autorizado a aterrizar pista %s, %s." % [rwy, cs]
		"push":
			ok = Game.push_back(p["id"])
			order = "%s, push-back aprobado, ruede al punto de espera pista %s." % [cs, Game.runway_name()]
			readback = "Push-back y rodaje al punto de espera, %s." % cs
		"line_up":
			ok = Game.line_up(p["id"], runway)
			order = "%s, entre en pista %s y espere." % [cs, rwy]
			readback = "Entrando en pista %s y esperando, %s." % [rwy, cs]
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


func _on_incident(kind: String, a: String, b: String) -> void:
	Engine.time_scale = SLOWMO_SCALE
	_slowmo_until = Time.get_ticks_msec() + SLOWMO_MS
	_radar.selected_id = -1
	_radar.flash("COLISIÓN" if kind == "crash" else "TCAS RA · %s / %s" % [a, b])


# --- Refresco --------------------------------------------------------------

func _refresh() -> void:
	if Game.phase != _last_phase:
		_last_phase = Game.phase
		# Los avisos del turno no deben seguir visibles fuera de él.
		_toast_label.text = ""
		if Game.phase != Game.Phase.SHIFT:
			Engine.time_scale = 1.0
			_slowmo_until = 0
		else:
			_radio_log.clear()
			_radio_label.text = ""
		_payday_replay.stop_replay()
		_gameover_replay.stop_replay()
		if not Game.replays.is_empty():
			if Game.phase == Game.Phase.PAYDAY:
				_payday_replay.play_replay(Game.replays[0])
			elif Game.phase == Game.Phase.GAMEOVER:
				_gameover_replay.play_replay(Game.replays[Game.replays.size() - 1])
	if Game.phase == Game.Phase.MENU:
		_status_label.text = ""
	else:
		var marks := ""
		for i in Game.MAX_STRIKES:
			marks += "●" if i < Game.strikes else "○"
		_status_label.text = "%sDía %d · Incidentes %s · %s $ ganados" % [
			"RETO DIARIO · " if Game.daily else "", Game.day, marks, Game.format_number(Game.money)]
	_menu_view.visible = Game.phase == Game.Phase.MENU
	_shift_view.visible = Game.phase == Game.Phase.SHIFT
	_payday_view.visible = Game.phase == Game.Phase.PAYDAY
	_draft_view.visible = Game.phase == Game.Phase.DRAFT
	_gameover_view.visible = Game.phase == Game.Phase.GAMEOVER
	match Game.phase:
		Game.Phase.MENU: _refresh_menu()
		Game.Phase.SHIFT: _refresh_shift()
		Game.Phase.PAYDAY: _refresh_payday()
		Game.Phase.DRAFT: _refresh_draft()
		Game.Phase.GAMEOVER: _refresh_gameover()


func _refresh_menu() -> void:
	_continue_button.visible = Game.has_saved_run()
	var seed := Game.today_seed()
	var best: float = float(Game.daily_best.get(str(seed), 0.0))
	_daily_button.text = "Reto diario %d/%d · mismo tráfico para todos" % [seed % 100, (seed / 100) % 100]
	var text := "Récord: %d días · %s $" % [Game.best_days, Game.format_number(Game.best_money)]
	if best > 0.0:
		text += "\nTu mejor marca en el reto de hoy: %s $ (semilla %d, compártela para comparar)" % [Game.format_number(best), seed]
	_records_label.text = text


func _refresh_shift() -> void:
	var h := Game.clock_hours()
	_clock_label.text = "%02d:%02d" % [int(h), int(fmod(h, 1.0) * 60.0)]
	_shift_info.text = "Por llegar: %d de %d · Aterrizados: %d · Despegados: %d · Por cobrar: %s $ · Multas: %s $" % [
		Game.planes_pending(), Game.planes_total, Game.day_landed, Game.day_departed,
		Game.format_number(Game.day_pay + Game.day_bonus), Game.format_number(Game.day_fines)]

	var warnings := []
	if Game.wind_change_in >= 0.0:
		warnings.append("VIENTO: pistas %s en %ds, no autorices aproximaciones largas" % [Game.runway_name(-Game.wind_dir), ceil(Game.wind_change_in)])
	if not Game.storms.is_empty():
		warnings.append("TORMENTA en el sector")
	for p in Game.planes:
		if p["emergency"] and Game.is_airborne(p):
			warnings.append("EMERGENCIA %s" % p["callsign"])
		elif p["mayday"] and Game.is_airborne(p):
			warnings.append("MAYDAY %s sin combustible" % p["callsign"])
	if Game.shift_done():
		warnings = ["Torre: no queda tráfico. Puedes terminar el día."]
	_event_label.text = " · ".join(warnings)
	_end_day_button.disabled = not Game.shift_done()

	_refresh_selected()
	_refresh_traffic()
	var lines := []
	for i in Game.runways.size():
		var r: Dictionary = Game.runways[i]
		var state := "libre"
		if r["closed"] > 0.0:
			state = "cerrada %ds" % ceil(r["closed"])
		elif not r["op"].is_empty():
			state = "ocupada por %s" % r["op"]["callsign"]
		elif not r["lined"].is_empty():
			state = "%s alineado" % r["lined"]["callsign"]
		if Game.runway_stormy(i):
			state += ", tormenta encima"
		lines.append("P%d %s: %s" % [i + 1, Game.runway_name(), state])
	lines.append("Puertas ocupadas: %d de %d" % [Game.gates_used(), Game.gate_count()])
	lines.append("Las salidas mantienen 2000 ft; las esperas, de 3000 a 7000. Misma altitud y mismo sitio = choque. Anillo rojo = conflicto. Estela: tras H esperar 6 s a L, 4 s a M y 3 s a H; tras M, 3 s a L.")
	_airport_label.text = "\n".join(lines)


func _refresh_selected() -> void:
	var p: Dictionary = Game._find(_radar.selected_id)
	if p.is_empty():
		_selected_label.text = "Ninguno. Haz clic en un avión del mapa o de la lista de tráfico."
		_fill_actions(p)
		return
	var text := "%s · %s · estela %s\n%s · paga %s $\n%s" % [
		p["callsign"], p["model"], Game.WAKE_NAMES[p["wake"]],
		"carga" if p["special"] == "cargo" else "%d pasajeros" % p["pax"],
		Game.format_number(Game.plane_value(p)), _state_text(p)]
	match p["special"]:
		"medical": text += "\nEMERGENCIA MÉDICA: prioridad absoluta, prima x3"
		"engine": text += "\nFALLO DE MOTOR: prioridad; tras la toma la pista se cierra %d s" % Game.ENGINE_FAIL_CLOSE
		"vip": text += "\nVIP: paga x5 si está en tierra antes de 45 s (lleva %ds)" % int(p["wait"])
		"cargo": text += "\nCARGUERO PESADO: deja estela H"
	if p["mayday"]:
		text += "\nMAYDAY: combustible mínimo"
	if Game.in_storm(p["pos"]) and Game.is_airborne(p):
		text += "\nDentro de la tormenta: consume el doble"
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
		match p["special"]:
			"vip": c = COLOR_VIP
			"cargo": c = COLOR_CARGO
		if p["emergency"]:
			c = COLOR_EMERGENCY
		if p["mayday"] and Game.is_airborne(p):
			c = COLOR_WARN
		b.add_theme_color_override("font_color", c)
		b.add_theme_color_override("font_hover_color", c)


func _state_text(p: Dictionary) -> String:
	var alt := "%d ft" % int(round(p["alt"] / 100.0) * 100)
	match p["state"]:
		"inbound": return "entrante a %s, combustible %ds. Asígnale altitud de espera." % [alt, ceil(p["fuel"])]
		"holding": return "en espera a %s (asignada %d), combustible %ds" % [alt, int(p["target_alt"]), ceil(p["fuel"])]
		"approach": return "aproximación a P%d, %s, toma en %.0fs, combustible %ds" % [p["runway"] + 1, alt, Game.time_to_touchdown(p), ceil(p["fuel"])]
		"go_around": return "motor y al aire, subiendo a %d ft" % Game.GO_AROUND_ALT
		"landing": return "carrera de aterrizaje en P%d" % (p["runway"] + 1)
		"taxi_in": return "rodando a puerta"
		"wait_gate": return "esperando puerta libre"
		"gate": return "en puerta, espera %ds" % int(p["wait"])
		"pushback": return "push-back y rodaje al punto de espera"
		"hold_point": return "en punto de espera"
		"line_up": return "entrando en P%d" % (p["runway"] + 1)
		"lined_up": return "alineado en P%d" % (p["runway"] + 1)
		"takeoff": return "carrera de despegue en P%d" % (p["runway"] + 1)
		"climb": return "despegado, saliendo a %s" % alt
		"divert": return "desviándose a otro aeropuerto"
	return p["state"]


## Muestra solo las órdenes de radio posibles en la fase actual del avión seleccionado.
func _fill_actions(p: Dictionary) -> void:
	var actions := []
	if not p.is_empty():
		match p["state"]:
			"inbound", "holding":
				for alt in Game.HOLD_ALTITUDES:
					actions.append(["hold", -1, "Esperar a %d ft" % alt, int(p["target_alt"]) != alt or p["state"] == "inbound", alt])
				for r in Game.runways.size():
					var label := "Aterrizar P%d %s" % [r + 1, Game.runway_name()]
					if Game.runway_stormy(r):
						label += " (tormenta)"
					actions.append(["land", r, label, true])
			"gate":
				actions.append(["push", -1, "Aprobar push-back", true])
			"hold_point":
				for r in Game.runways.size():
					actions.append(["line_up", r, "Entrar y esperar P%d" % (r + 1), Game.runway_clear(r)])
			"lined_up":
				actions.append(["takeoff", -1, "Autorizar despegue", not Game.runway_stormy(p["runway"])])
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
		b.set_meta("altitude", a[4] if a.size() > 4 else 0)


func _summary_text(s: Dictionary) -> String:
	var text := "Día %d\n\nAterrizajes: %d\nDespegues: %d\nEmergencias resueltas: %d\nDesvíos: %d\nAvisos TCAS: %d\nMotor y al aire: %d\nInfracciones de estela: %d\n\nPago por aviones: %s $" % [
		s["day"], s["landed"], s["departed"], s["emergencies"], s["diverted"], s["tcas"], s["go_arounds"],
		s["infractions"], Game.format_number(s["pay"])]
	if s["bonus"] > 0.0:
		text += "\nPrimas (VIP y emergencias): %s $" % Game.format_number(s["bonus"])
	if s["fines"] > 0.0:
		text += "\nMultas: -%s $" % Game.format_number(s["fines"])
	return text


func _refresh_payday() -> void:
	var s: Dictionary = Game.last_summary
	_summary_label.text = _summary_text(s) + "\n\nTotal del día: %s $\nIncidentes en tu expediente: %d de %d" % [
		Game.format_number(s["total"]), Game.strikes, Game.MAX_STRIKES]
	_refresh_replay_buttons(_payday_replay, _payday_replay_buttons)


func _refresh_replay_buttons(view: Control, buttons: Array[Button]) -> void:
	view.visible = not Game.replays.is_empty()
	for i in buttons.size():
		var b := buttons[i]
		b.visible = i < Game.replays.size()
		if b.visible:
			b.text = "▶ " + Game.replays[i]["title"]


func _refresh_draft() -> void:
	_draft_title.text = "Día %d superado" % (Game.day)
	for i in _card_buttons.size():
		var b := _card_buttons[i]
		if i >= Game.offer.size():
			b.visible = false
			continue
		b.visible = true
		var id: String = Game.offer[i]
		var c: Dictionary = Game.CARDS[id]
		var contract: bool = c["kind"] == "contract"
		var lvl: int = Game.levels[id]
		b.text = "%s\n\n%s\n\n%s%s" % ["CONTRATO" if contract else "MEJORA", c["name"], c["desc"],
			"\n\n(ya tienes %d)" % lvl if lvl > 0 else ""]
		var col := COLOR_CONTRACT if contract else COLOR_UPGRADE
		b.add_theme_color_override("font_color", col)
		b.add_theme_color_override("font_hover_color", col)
	var active := []
	for id in Game.CARDS:
		if Game.levels[id] > 0:
			active.append("%s x%d" % [Game.CARDS[id]["name"], Game.levels[id]])
	_draft_info.text = "Mañana (día %d) llegan %d aviones, más los que traiga un contrato. Pistas: %d · Puertas: %d\nEn tu aeropuerto: %s" % [
		Game.day + 1, Game.planes_for_day(Game.day + 1), Game.runway_count(), Game.gate_count(), ", ".join(active) if not active.is_empty() else "nada todavía"]


func _refresh_gameover() -> void:
	var days := Game.day - 1
	var text := "%s\n\nAguantaste %d %s y ganaste %s $.\n\nRécord: %d días · %s $" % [
		Game.fired_reason, days, "día" if days == 1 else "días", Game.format_number(Game.money),
		Game.best_days, Game.format_number(Game.best_money)]
	if Game.daily:
		text += "\nReto diario (semilla %d): tu mejor marca es %s $" % [Game.seed_value, Game.format_number(float(Game.daily_best.get(str(Game.seed_value), 0.0)))]
	_gameover_label.text = text
	_refresh_replay_buttons(_gameover_replay, _gameover_replay_buttons)


func _on_toast(text: String) -> void:
	_toast_label.text = text
	_toast_time = 5.0
	if Game.phase == Game.Phase.SHIFT:
		_radio("TWR: " + text)
