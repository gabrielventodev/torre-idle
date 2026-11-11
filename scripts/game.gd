extends Node
## Estado y simulación del juego. No contiene UI: la escena principal lo lee y llama a sus acciones.
## Se registra como autoload "Game". Los tests lo instancian con .new() y llaman a new_run().
##
## Roguelite de torre de control. Cada partida es una sucesión de días:
##   turno (9:00 a 18:00, tráfico en oleadas con hora punta) -> resumen -> eliges 1 de 3 cartas
##   (mejora o contrato) -> el día siguiente trae más tráfico.
## Tres incidentes (desvío por combustible o aviso TCAS) y te despiden; una colisión te despide
## en el acto. La puntuación es el dinero ganado y los días aguantados.
##
## Simulación espacial: cada avión tiene posición en el mapa (unidades de mundo), rumbo, velocidad
## y altitud, y se mueve de forma continua.
##   Llegada: entrante -> espera en círculo (a la altitud que ordenes) -> aproximación -> toma y
##            carrera en pista -> rodaje -> puerta.
##   Salida:  puerta -> push-back y rodaje -> punto de espera -> entra en pista -> despegue y ascenso.
## Una pista solo admite una operación a la vez, tras cada operación hay que respetar la
## separación por estela, y dos aviones en vuelo a la misma altitud y en el mismo sitio chocan.
## El viento decide el sentido de las pistas (09 o 27) y puede cambiar a mitad de turno.
## Las tormentas cruzan el mapa: dentro se quema combustible el triple y sobre una pista impiden
## aterrizar y despegar.

signal toast(text: String)
## Pérdida de separación grave entre dos aviones (aviso TCAS) o colisión.
signal incident(kind: String, a: String, b: String)

enum Phase { MENU, SHIFT, PAYDAY, DRAFT, GAMEOVER }

const SAVE_PATH := "user://run.json"
const RECORDS_PATH := "user://records.json"
const SAVE_VERSION := 5

## Pago por avión coordinado según el tamaño.
const PAY_BY_TIER := [100, 250, 600, 1500]
const MODEL_BY_TIER := ["Cessna 208", "ATR 72", "A320", "B787"]
const PAX_BY_TIER := [9, 68, 180, 290]
## Categoría de estela: 0 ligera, 1 media, 2 pesada.
const WAKE_BY_TIER := [0, 1, 1, 2]
const WAKE_NAMES := ["L", "M", "H"]
## Segundos de separación exigidos [categoría anterior][categoría siguiente].
const SEPARATION := [
	[0.0, 0.0, 0.0],
	[3.0, 0.0, 0.0],
	[6.0, 4.0, 3.0],
]
const AIRLINES := ["IB", "VY", "UX", "AA", "LH", "AF", "KL", "LA", "AV", "AM"]

# --- Geometría del aeropuerto (unidades de mundo) ---
const MAP_SIZE := Vector2(1600, 1000)
const RUNWAY_X0 := 590.0
const RUNWAY_X1 := 1010.0
const RUNWAY_Y0 := 440.0
const RUNWAY_SPACING := 60.0
const TAXI_Y := 490.0
const GATE_Y := 528.0
const GATE_X0 := 630.0
const GATE_SPACING := 42.0
## Distancia del punto de entrada a final al umbral.
const FINAL_DIST := 260.0

# --- Vuelo ---
const HOLD_ALTITUDES := [3000, 4000, 5000, 6000, 7000]
const GO_AROUND_ALT := 2500
const SPAWN_ALTITUDES := [5000, 6000, 7000, 8000]
const AIR_SPEED := 80.0
const FINAL_SPEED := 60.0
const TAXI_SPEED := 40.0
const PUSHBACK_SPEED := 15.0
const TAKEOFF_SPEED := 90.0
const TURN_RATE := 1.6
const CLIMB_RATE := 350.0
const HOLD_RADIUS := 40.0
## Un entrante sin órdenes entra en espera solo al llegar a esta distancia del centro.
const AUTO_HOLD_DIST := 330.0

# --- Separación en vuelo ---
const CRASH_DIST := 16.0
const CRASH_ALT := 400.0
const TCAS_DIST := 38.0
const TCAS_ALT := 700.0
const CONFLICT_DIST := 70.0
const CONFLICT_ALT := 900.0

# --- Combustible y emergencias ---
const FUEL_RANGE := Vector2(95.0, 125.0)
const MAYDAY_FUEL := 20.0
const STORM_FUEL_BURN := 2.0
const EMERGENCY_FUEL := 45.0
const ENGINE_FAIL_CLOSE := 10.0

# --- Partida ---
const MAX_STRIKES := 3
const BASE_GATES := 3
const MAX_GATES := 11
const TURNAROUND_TIME := 8.0
const MAX_RUNWAYS := 4
const SHIFT_START := 9.0
const SHIFT_END := 18.0
## Última hora a la que aparece tráfico nuevo.
const LAST_SPAWN_HOUR := 17.4
## Segundos reales que dura un turno de 9:00 a 18:00.
const SHIFT_SECONDS := 160.0
## Picos de tráfico (hora del reloj) y su intensidad respecto al tráfico de fondo.
const RUSH_HOURS := [9.8, 17.0]
const RUSH_WEIGHT := 2.5
const RUSH_WIDTH := 0.7

## Cartas que se ofrecen entre días. kind "upgrade" mejora el aeropuerto; kind "contract" trae
## más tráfico a cambio de más dinero. max -1 = sin límite. weight = frecuencia relativa.
const CARDS := {
	"gates": {"kind": "upgrade", "name": "Puerta de embarque", "max": MAX_GATES - BASE_GATES, "weight": 3,
		"desc": "+1 puerta para salidas y llegadas."},
	"taxiway": {"kind": "upgrade", "name": "Calles de rodaje", "max": 5, "weight": 2,
		"desc": "+20 % de velocidad de rodaje."},
	"rapid_exit": {"kind": "upgrade", "name": "Salida rápida", "max": 3, "weight": 2,
		"desc": "Los aterrizajes dejan la pista antes."},
	"runway": {"kind": "upgrade", "name": "Pista adicional", "max": MAX_RUNWAYS - 1, "weight": 2,
		"desc": "+1 pista paralela."},
	"ground": {"kind": "upgrade", "name": "Controlador de tierra", "max": 1, "weight": 2,
		"desc": "Hace los push-back por ti. La torre sigue siendo tuya."},
	"wake_monitor": {"kind": "upgrade", "name": "Monitor de estela", "max": 1, "weight": 2,
		"desc": "Cuenta atrás de separación por estela en cada pista."},
	"meteo": {"kind": "upgrade", "name": "Radar meteorológico", "max": 1, "weight": 2,
		"desc": "Ves la trayectoria de las tormentas y el aviso de viento llega antes."},
	"fuel_reserve": {"kind": "upgrade", "name": "Reserva de combustible", "max": 2, "weight": 2,
		"desc": "Las llegadas traen 15 s más de combustible."},
	"fees": {"kind": "upgrade", "name": "Tasas aeroportuarias", "max": -1, "weight": 2,
		"desc": "+20 % de pago por avión."},
	"union": {"kind": "upgrade", "name": "Delegado sindical", "max": -1, "weight": 2,
		"desc": "Borra un incidente de tu expediente."},
	"charter": {"kind": "contract", "name": "Contrato chárter", "max": -1, "weight": 3,
		"desc": "+3 aviones al día. +25 % de pago."},
	"lowcost": {"kind": "contract", "name": "Aerolínea low cost", "max": -1, "weight": 2,
		"desc": "+4 aviones al día con el combustible justo (-15 s). +35 % de pago."},
	"cargo": {"kind": "contract", "name": "Carguero pesado", "max": -1, "weight": 2,
		"desc": "+2 B787 al día: pagan mucho pero dejan estela pesada."},
	"vip": {"kind": "contract", "name": "Vuelo VIP", "max": -1, "weight": 2,
		"desc": "+1 vuelo VIP al día: paga x5 si aterriza en menos de 45 s."},
}

var save_enabled := true
var rng := RandomNumberGenerator.new()

# Récords, persistentes entre partidas.
var best_days := 0
var best_money := 0.0
## Mejor puntuación de cada reto diario, por semilla.
var daily_best := {}

# Estado de la partida actual.
var phase := Phase.MENU
var daily := false
var seed_value := 0
var money := 0.0
var day := 1
var strikes := 0
var levels := {}
var offer: Array = []
var fired_reason := ""

# Estado del turno en curso.
## Todos los aviones activos del turno, en orden de llegada.
var planes: Array = []
var runways: Array = []
## Una entrada por puerta: {"plane": id o -1, "turn": segundos de escala restantes}.
var gates: Array = []
## Tormentas: {"pos", "vel", "radius"}.
var storms: Array = []
## Sentido de las pistas: 1 = 09 (aterrizan de oeste a este), -1 = 27.
var wind_dir := 1
## Segundos que faltan para el cambio de viento anunciado; -1 si no hay ninguno.
var wind_change_in := -1.0
var planes_total := 0
var planes_spawned := 0
var shift_elapsed := 0.0
var day_pay := 0.0
var day_bonus := 0.0
var day_fines := 0.0
var day_landed := 0
var day_departed := 0
var day_diverted := 0
var day_go_arounds := 0
var day_infractions := 0
var day_tcas := 0
var day_emergencies := 0
var last_summary := {}
## Repeticiones de incidentes del día: {"title", "frames"}.
var replays: Array = []

var _spawn_queue: Array = []
var _events: Array = []
var _wind_at := -1.0
var _wind_warned := false
var _done_announced := false
var _fire_timer := -1.0
var _tcas_pairs := {}
var _history: Array = []
var _history_t := 0.0
var _pending_replays: Array = []
var _next_plane_id := 1

const REPLAY_EVERY := 0.1
const REPLAY_BEFORE := 70
const REPLAY_AFTER := 25


func _ready() -> void:
	load_records()
	phase = Phase.MENU


func _process(delta: float) -> void:
	simulate(delta)


## Empieza una partida nueva. El reto diario usa la fecha como semilla: todos juegan el mismo.
func new_run(is_daily: bool, forced_seed: int = -1) -> void:
	daily = is_daily
	if forced_seed >= 0:
		seed_value = forced_seed
	elif is_daily:
		seed_value = today_seed()
	else:
		seed_value = randi()
	rng.seed = seed_value
	money = 0.0
	day = 1
	strikes = 0
	fired_reason = ""
	levels = {}
	for id in CARDS:
		levels[id] = 0
	wind_dir = 1
	start_shift()


static func today_seed() -> int:
	var d := Time.get_date_dict_from_system()
	return d["year"] * 10000 + d["month"] * 100 + d["day"]


func has_saved_run() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


# --- Fórmulas -------------------------------------------------------------

func planes_per_day() -> int:
	return planes_for_day(day)


func planes_for_day(d: int) -> int:
	return 4 + floori(d * 1.5) + 3 * levels["charter"] + 4 * levels["lowcost"] + 2 * levels["cargo"] + levels["vip"]


func runway_count() -> int:
	return 1 + levels["runway"]


func gate_count() -> int:
	return min(BASE_GATES + levels["gates"], MAX_GATES)


func gates_used() -> int:
	var n := 0
	for g in gates:
		if g["plane"] >= 0 or g["turn"] > 0.0:
			n += 1
	return n


func taxi_speed() -> float:
	return TAXI_SPEED * (1.0 + 0.2 * levels["taxiway"])


func pay_mult() -> float:
	return (1.0 + 0.2 * levels["fees"]) * (1.0 + 0.25 * levels["charter"] + 0.35 * levels["lowcost"])


func plane_value(plane: Dictionary) -> float:
	return PAY_BY_TIER[plane["tier"]] * pay_mult()


## Tamaño máximo de avión: el aeropuerto crece con los días.
func max_tier() -> int:
	return clampi(floori((day - 1) / 3.0), 0, 2)


## Hora del reloj de la torre (9.0 a 18.0).
func clock_hours() -> float:
	return SHIFT_START + (SHIFT_END - SHIFT_START) * clamp(shift_elapsed / SHIFT_SECONDS, 0.0, 1.0)


func planes_pending() -> int:
	return planes_total - planes_spawned


## El turno termina a las 18:00 cuando no quedan aviones por llegar ni en movimiento.
func shift_done() -> bool:
	if phase != Phase.SHIFT or planes_spawned < planes_total or _fire_timer >= 0.0:
		return false
	return planes.is_empty() and clock_hours() >= SHIFT_END


func runway_y(i: int) -> float:
	return RUNWAY_Y0 - i * RUNWAY_SPACING


## Umbral de aterrizaje de una pista según el sentido en uso.
func threshold(i: int, d: int = 0) -> Vector2:
	d = d if d != 0 else wind_dir
	return Vector2(RUNWAY_X0 if d > 0 else RUNWAY_X1, runway_y(i))


## Extremo de la pista opuesto al umbral.
func far_end_x(d: int) -> float:
	return RUNWAY_X1 if d > 0 else RUNWAY_X0


## Punto de la pista donde los aterrizajes la abandonan; la salida rápida lo adelanta.
func runway_exit_x(d: int = 0) -> float:
	d = d if d != 0 else wind_dir
	return far_end_x(d) - d * 50.0 * levels["rapid_exit"]


## Calle de acceso a la cabecera en uso.
func entry_x(d: int = 0) -> float:
	d = d if d != 0 else wind_dir
	return RUNWAY_X0 - 30.0 if d > 0 else RUNWAY_X1 + 30.0


## Punto de espera de las salidas, junto a la cabecera en uso.
func hold_point(d: int = 0) -> Vector2:
	d = d if d != 0 else wind_dir
	return Vector2(entry_x(d) - d * 10.0, TAXI_Y)


## Donde esperan las llegadas si no hay puerta, en el extremo contrario.
func wait_gate_point(d: int = 0) -> Vector2:
	d = d if d != 0 else wind_dir
	return Vector2(1070.0 if d > 0 else 530.0, TAXI_Y)


func runway_name(d: int = 0) -> String:
	d = d if d != 0 else wind_dir
	return "09" if d > 0 else "27"


func gate_pos(k: int) -> Vector2:
	return Vector2(GATE_X0 + k * GATE_SPACING, GATE_Y)


## Segundos de separación que aún faltan en una pista para un avión de la categoría dada.
func separation_left(runway: int, wake: int) -> float:
	var r: Dictionary = runways[runway]
	if r["prev_wake"] < 0:
		return 0.0
	return max(0.0, SEPARATION[r["prev_wake"]][wake] - r["since"])


## Una pista está libre si no hay nadie rodando por ella ni entrando o alineado, y no está cerrada.
func runway_clear(runway: int) -> bool:
	var r: Dictionary = runways[runway]
	return r["op"].is_empty() and r["lined"].is_empty() and r["closed"] <= 0.0


## Una tormenta sobre la pista impide aterrizar (cizalladura) y despegar.
func runway_stormy(runway: int) -> bool:
	var y := runway_y(runway)
	for s in storms:
		var nearest := Vector2(clamp(s["pos"].x, RUNWAY_X0, RUNWAY_X1), y)
		if nearest.distance_to(s["pos"]) < s["radius"]:
			return true
	return false


func in_storm(pos: Vector2) -> bool:
	for s in storms:
		if pos.distance_to(s["pos"]) < s["radius"]:
			return true
	return false


func is_airborne(p: Dictionary) -> bool:
	return p["state"] in ["inbound", "holding", "approach", "go_around", "divert", "climb"]


func arrivals() -> Array:
	return planes.filter(func(p): return p["arrival"])


func departures() -> Array:
	return planes.filter(func(p): return not p["arrival"])


## Aviones en aproximación hacia una pista.
func approaches_on(runway: int) -> Array:
	return planes.filter(func(p): return p["state"] == "approach" and p["runway"] == runway)


## Segundos estimados hasta la toma de un avión en aproximación.
func time_to_touchdown(p: Dictionary) -> float:
	var d := 0.0
	var at: Vector2 = p["pos"]
	for w in p["path"]:
		d += at.distance_to(w)
		at = w
	return d / FINAL_SPEED


# --- Acciones del jugador: turno -------------------------------------------

## Ordena esperar en círculo, donde está ahora, a una altitud dada. Sirve también para
## cambiar la altitud de un avión que ya está en espera.
func hold_at(plane_id: int, altitude: int) -> bool:
	var p := _find(plane_id)
	if p.is_empty() or not p["state"] in ["inbound", "holding"]:
		return false
	p["target_alt"] = float(altitude)
	if p["state"] == "inbound":
		_enter_hold(p)
	return true


## Autoriza el aterrizaje: el avión deja la espera y sigue la trayectoria hasta el umbral.
## Si al llegar la pista está ocupada o hay tormenta encima, hace motor y al aire.
func clear_landing(plane_id: int, runway: int) -> bool:
	var p := _find(plane_id)
	if p.is_empty() or not p["state"] in ["inbound", "holding"] or runway < 0 or runway >= runways.size():
		return false
	p["state"] = "approach"
	p["runway"] = runway
	p["dir"] = wind_dir
	p["path"] = _approach_path(p["pos"], runway, wind_dir)
	return true


## Push-back y rodaje hasta el punto de espera. Libera la puerta.
func push_back(plane_id: int) -> bool:
	var p := _find(plane_id)
	if p.is_empty() or p["state"] != "gate":
		return false
	gates[p["gate"]]["plane"] = -1
	var g := gate_pos(p["gate"])
	p["gate"] = -1
	p["state"] = "pushback"
	p["path"] = [Vector2(g.x, TAXI_Y), hold_point()]
	return true


## Entrar y esperar: el avión rueda hasta el umbral y ocupa la pista hasta que despegue.
func line_up(plane_id: int, runway: int) -> bool:
	var p := _find(plane_id)
	if p.is_empty() or p["state"] != "hold_point" or runway < 0 or runway >= runways.size():
		return false
	if not runway_clear(runway):
		return false
	p["state"] = "line_up"
	p["runway"] = runway
	p["dir"] = wind_dir
	p["path"] = [Vector2(entry_x(), runway_y(runway)), threshold(runway) + Vector2(wind_dir * 6.0, 0)]
	runways[runway]["lined"] = p
	return true


## Autoriza el despegue de un avión alineado. Si no se respeta la separación por estela,
## despega igual pero se registra una infracción con multa. Con tormenta encima, no despega.
func clear_takeoff(plane_id: int) -> bool:
	var p := _find(plane_id)
	if p.is_empty() or p["state"] != "lined_up":
		return false
	if runway_stormy(p["runway"]):
		toast.emit("%s: negativo, tormenta sobre la pista. Mantenemos posición." % p["callsign"])
		return false
	var r: Dictionary = runways[p["runway"]]
	if separation_left(p["runway"], p["wake"]) > 0.0:
		_infraction(p, "despegó sin separación por estela")
	r["lined"] = {}
	r["op"] = p
	p["state"] = "takeoff"
	p["speed"] = 0.0
	return true


# --- Flujo de la partida ----------------------------------------------------

func start_shift() -> void:
	phase = Phase.SHIFT
	planes.clear()
	runways.clear()
	for i in runway_count():
		runways.append({"op": {}, "lined": {}, "prev_wake": -1, "since": 0.0, "closed": 0.0})
	gates.clear()
	for k in gate_count():
		gates.append({"plane": -1, "turn": 0.0})
	storms.clear()
	planes_total = planes_per_day()
	planes_spawned = 0
	shift_elapsed = 0.0
	day_pay = 0.0
	day_bonus = 0.0
	day_fines = 0.0
	day_landed = 0
	day_departed = 0
	day_diverted = 0
	day_go_arounds = 0
	day_infractions = 0
	day_tcas = 0
	day_emergencies = 0
	replays.clear()
	_pending_replays.clear()
	_history.clear()
	_tcas_pairs.clear()
	_done_announced = false
	_fire_timer = -1.0
	_build_schedule()


## Prepara el tráfico del día en oleadas con dos horas punta, y los sucesos: tormentas,
## emergencias y cambio de viento. Todo sale de la semilla, así el reto diario es igual para todos.
func _build_schedule() -> void:
	var specials := []
	for i in levels["cargo"] * 2:
		specials.append("cargo")
	for i in levels["vip"]:
		specials.append("vip")
	_spawn_queue.clear()
	for i in planes_total:
		_spawn_queue.append({"t": _rush_time(), "kind": ""})
	_spawn_queue.sort_custom(func(a, b): return a["t"] < b["t"])
	# Los vuelos especiales sustituyen a vuelos normales repartidos por el día.
	for s in specials:
		var k := rng.randi_range(0, _spawn_queue.size() - 1)
		_spawn_queue[k]["kind"] = s
	_spawn_queue[0]["t"] = min(_spawn_queue[0]["t"], 1.0)

	_events.clear()
	var storm_count := 0
	if day >= 2:
		storm_count = 1 + (1 if day >= 6 and rng.randf() < 0.5 else 0) + (1 if day >= 10 and rng.randf() < 0.5 else 0)
	for i in storm_count:
		_events.append({"t": rng.randf_range(0.1, 0.75) * SHIFT_SECONDS, "kind": "storm"})
	var emergencies := 0
	if day >= 2:
		emergencies = 1 + (1 if day >= 5 and rng.randf() < 0.6 else 0)
	for i in emergencies:
		_events.append({"t": rng.randf_range(0.15, 0.85) * SHIFT_SECONDS,
			"kind": ["medical", "engine"][rng.randi() % 2]})
	_events.sort_custom(func(a, b): return a["t"] < b["t"])

	wind_change_in = -1.0
	_wind_warned = false
	_wind_at = -1.0
	if day >= 3 and rng.randf() < 0.6:
		_wind_at = rng.randf_range(0.3, 0.8) * SHIFT_SECONDS


## Instante del turno (segundos) para un avión, con más probabilidad en las horas punta.
func _rush_time() -> float:
	var last := (LAST_SPAWN_HOUR - SHIFT_START) / (SHIFT_END - SHIFT_START) * SHIFT_SECONDS
	while true:
		var t := rng.randf_range(0.0, last)
		var h := SHIFT_START + t / SHIFT_SECONDS * (SHIFT_END - SHIFT_START)
		var w := 1.0
		for peak in RUSH_HOURS:
			w += RUSH_WEIGHT * exp(-pow((h - peak) / RUSH_WIDTH, 2.0))
		if rng.randf() * (1.0 + RUSH_WEIGHT) < w:
			return t
	return 0.0


## Hora punta: más de la mitad del tráfico de fondo concentrado en este momento.
func is_rush_hour() -> bool:
	var h := clock_hours()
	for peak in RUSH_HOURS:
		if abs(h - peak) < RUSH_WIDTH:
			return true
	return false


## Cierra el turno y prepara el resumen.
func end_day() -> bool:
	if not shift_done():
		return false
	last_summary = {
		"day": day, "landed": day_landed, "departed": day_departed, "diverted": day_diverted,
		"go_arounds": day_go_arounds, "infractions": day_infractions, "tcas": day_tcas,
		"emergencies": day_emergencies,
		"pay": day_pay, "bonus": day_bonus, "fines": day_fines,
		"total": max(0.0, day_pay + day_bonus - day_fines),
	}
	money += last_summary["total"]
	phase = Phase.PAYDAY
	return true


## Del resumen a la elección de carta.
func open_draft() -> bool:
	if phase != Phase.PAYDAY:
		return false
	offer = _make_offer()
	phase = Phase.DRAFT
	if save_enabled:
		save_run()
	return true


func card_available(id: String) -> bool:
	var c: Dictionary = CARDS[id]
	if c["max"] >= 0 and levels[id] >= c["max"]:
		return false
	if id == "union" and strikes == 0:
		return false
	return true


## Tres cartas distintas: al menos una mejora y un contrato.
func _make_offer() -> Array:
	var ups := []
	var cons := []
	for id in CARDS:
		if not card_available(id):
			continue
		if CARDS[id]["kind"] == "contract":
			cons.append(id)
		else:
			ups.append(id)
	var picked := []
	if not ups.is_empty():
		picked.append(_weighted(ups))
	if not cons.is_empty():
		picked.append(_weighted(cons))
	var rest := (ups + cons).filter(func(id): return not id in picked)
	if not rest.is_empty():
		picked.append(_weighted(rest))
	return picked


func _weighted(ids: Array) -> String:
	var total := 0
	for id in ids:
		total += CARDS[id]["weight"]
	var r := rng.randi_range(1, total)
	for id in ids:
		r -= CARDS[id]["weight"]
		if r <= 0:
			return id
	return ids[0]


func pick_card(index: int) -> bool:
	if phase != Phase.DRAFT or index < 0 or index >= offer.size():
		return false
	var id: String = offer[index]
	if id == "union":
		strikes = max(0, strikes - 1)
	else:
		levels[id] += 1
	offer = []
	day += 1
	# Se guarda antes de generar el turno para que, al volver, el reto diario sea idéntico.
	phase = Phase.SHIFT
	if save_enabled:
		save_run()
	start_shift()
	return true


## Despido: fin de la partida. Actualiza récords y borra la partida guardada.
func _fire(reason: String) -> void:
	fired_reason = reason
	last_summary = {
		"day": day, "landed": day_landed, "departed": day_departed, "diverted": day_diverted,
		"go_arounds": day_go_arounds, "infractions": day_infractions, "tcas": day_tcas,
		"emergencies": day_emergencies,
		"pay": day_pay, "bonus": day_bonus, "fines": day_fines, "total": 0.0,
	}
	for r in _pending_replays:
		replays.append({"title": r["title"], "frames": r["frames"]})
	_pending_replays.clear()
	var days_survived := day - 1
	best_days = max(best_days, days_survived)
	best_money = max(best_money, money)
	if daily:
		var key := str(seed_value)
		daily_best[key] = max(float(daily_best.get(key, 0.0)), money)
	phase = Phase.GAMEOVER
	if save_enabled:
		save_records()
		if FileAccess.file_exists(SAVE_PATH):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


func back_to_menu() -> void:
	phase = Phase.MENU


## Abandonar la partida en curso cuenta como despido.
func resign() -> void:
	if phase in [Phase.SHIFT, Phase.PAYDAY, Phase.DRAFT]:
		_fire("Dimitiste.")


func _add_strike(reason: String) -> void:
	strikes += 1
	if strikes >= MAX_STRIKES:
		toast.emit("Tercer incidente: %s. Estás despedido." % reason)
		_schedule_fire("Tres incidentes. El último: %s." % reason)
	else:
		toast.emit("Incidente %d de %d: %s." % [strikes, MAX_STRIKES, reason])


## Se deja correr la simulación un momento para que la repetición muestre el desenlace.
func _schedule_fire(reason: String) -> void:
	if _fire_timer < 0.0:
		_fire_timer = 2.5
		fired_reason = reason


# --- Simulación del turno --------------------------------------------------

func simulate(delta: float) -> void:
	if phase != Phase.SHIFT:
		return
	shift_elapsed += delta
	for r in runways:
		r["since"] += delta
		r["closed"] = max(0.0, r["closed"] - delta)
	for g in gates:
		g["turn"] = max(0.0, g["turn"] - delta)
	_update_storms(delta)
	_update_wind(delta)
	for p in planes.duplicate():
		if planes.has(p):
			_update_plane(p, delta)
	_check_separation()
	_spawn()
	_update_events()
	_ground_control()
	_record(delta)
	if _fire_timer >= 0.0:
		_fire_timer -= delta
		if _fire_timer < 0.0:
			_fire(fired_reason)
		return
	if not _done_announced and shift_done():
		_done_announced = true
		toast.emit("Torre: son las 18:00 y no queda tráfico. Puedes terminar el día.")


func _find(plane_id: int) -> Dictionary:
	for p in planes:
		if p["id"] == plane_id:
			return p
	return {}


func _update_plane(p: Dictionary, delta: float) -> void:
	p["wait"] += delta
	if p["arrival"] and is_airborne(p) and p["state"] != "divert":
		p["fuel"] -= delta * (STORM_FUEL_BURN if in_storm(p["pos"]) else 1.0)
		if p["fuel"] <= MAYDAY_FUEL and not p["mayday"]:
			p["mayday"] = true
			toast.emit("MAYDAY MAYDAY MAYDAY, %s, combustible mínimo, solicitamos prioridad." % p["callsign"])
		if p["fuel"] <= 0.0:
			_divert(p)
	_update_altitude(p, delta)
	var d: int = p["dir"]
	match p["state"]:
		"inbound":
			_fly_toward(p, MAP_SIZE * 0.5, AIR_SPEED, delta)
			if p["pos"].distance_to(MAP_SIZE * 0.5) < AUTO_HOLD_DIST:
				_enter_hold(p)
		"holding":
			_orbit(p, delta)
		"approach":
			if _fly_path(p, FINAL_SPEED, delta):
				_touchdown(p)
			else:
				_glide_slope(p, delta)
		"landing":
			# Carrera de aterrizaje: frena hasta velocidad de rodaje y abandona la pista en la salida.
			p["speed"] = max(taxi_speed(), p["speed"] - 20.0 * delta)
			p["pos"].x += d * p["speed"] * delta
			if (p["pos"].x - runway_exit_x(d)) * d >= 0.0:
				_vacate_runway(p)
		"taxi_in":
			if _move_path(p, taxi_speed(), delta):
				_arrive_gate_or_wait(p)
		"wait_gate":
			_arrive_gate_or_wait(p)
		"pushback":
			var speed := PUSHBACK_SPEED if p["pos"].y > TAXI_Y + 1.0 else taxi_speed()
			if _move_path(p, speed, delta):
				p["state"] = "hold_point"
		"hold_point":
			pass
		"line_up":
			if _move_path(p, taxi_speed() * 0.6, delta):
				p["state"] = "lined_up"
				p["heading"] = 0.0 if d > 0 else PI
		"takeoff":
			p["speed"] = min(TAKEOFF_SPEED, p["speed"] + 32.0 * delta)
			p["pos"].x += d * p["speed"] * delta
			if (p["pos"].x - far_end_x(d)) * d >= 0.0:
				_liftoff(p)
		"climb", "divert":
			_fly_toward(p, p["exit"], AIR_SPEED * 1.2, delta)
			if p["pos"].distance_to(p["exit"]) < 20.0 or not Rect2(Vector2(-80, -80), MAP_SIZE + Vector2(160, 160)).has_point(p["pos"]):
				if p["state"] == "climb":
					_pay(p)
					day_departed += 1
				planes.erase(p)
		"go_around":
			if _fly_path(p, AIR_SPEED, delta):
				p["target_alt"] = float(GO_AROUND_ALT)
				_enter_hold(p)


func _update_altitude(p: Dictionary, delta: float) -> void:
	if p["state"] == "approach":
		return
	var diff: float = p["target_alt"] - p["alt"]
	var rate: float = CLIMB_RATE * (2.0 if p["tcas"] > 0.0 else 1.0)
	p["tcas"] = max(0.0, p["tcas"] - delta)
	p["alt"] += clamp(diff, -rate * delta, rate * delta)


## Senda de planeo: 1500 ft al entrar en final y 0 en el umbral.
func _glide_slope(p: Dictionary, delta: float) -> void:
	var t := threshold(p["runway"], p["dir"])
	if p["path"].size() <= 1:
		p["alt"] = min(p["alt"], 1500.0 * clamp(p["pos"].distance_to(t) / FINAL_DIST, 0.0, 1.0))
	else:
		p["alt"] = move_toward(p["alt"], 1500.0, CLIMB_RATE * delta)


## Trayectoria de aproximación: si viene del lado contrario, tramo base al costado de la pista;
## luego punto de entrada a final alineado con la pista, y el umbral.
func _approach_path(from: Vector2, runway: int, d: int) -> Array:
	var t := threshold(runway, d)
	var join := t - Vector2(d * FINAL_DIST, 0)
	var far := far_end_x(d)
	var path := []
	if (from.x - join.x) * d > 40.0:
		var side := 1.0 if from.y >= t.y else -1.0
		var bx: float = from.x if (from.x - far) * d < 0.0 else far
		path.append(Vector2(bx, t.y + side * 190.0))
		path.append(Vector2(join.x - d * 60.0, t.y + side * 190.0))
		path.append(Vector2(join.x - d * 90.0, t.y + side * 70.0))
	path.append(join)
	path.append(t)
	return path


## Vuelo con giro limitado hacia un punto (las trayectorias son curvas, sin saltos).
func _fly_toward(p: Dictionary, target: Vector2, speed: float, delta: float) -> void:
	var want: float = (target - p["pos"]).angle()
	var diff := wrapf(want - p["heading"], -PI, PI)
	p["heading"] += clamp(diff, -TURN_RATE * delta, TURN_RATE * delta)
	p["speed"] = speed
	p["pos"] += Vector2.from_angle(p["heading"]) * speed * delta


## Sigue una ruta en vuelo; devuelve true al llegar al último punto.
func _fly_path(p: Dictionary, speed: float, delta: float) -> bool:
	if p["path"].is_empty():
		return true
	var target: Vector2 = p["path"][0]
	_fly_toward(p, target, speed, delta)
	# Un punto intermedio se da por alcanzado dentro del radio de giro, para no orbitar a su
	# alrededor; el último (umbral de pista) al cruzarlo.
	var reach: float = speed / TURN_RATE * 1.2
	var last: bool = p["path"].size() == 1 and p["state"] == "approach"
	var passed: bool = last and (p["pos"].x - target.x) * p["dir"] >= -2.0 and abs(p["pos"].y - target.y) < 30.0
	if passed or (not last and p["pos"].distance_to(target) < reach):
		p["path"].pop_front()
		if p["path"].is_empty():
			p["pos"] = target
			return true
	return false


## Movimiento en tierra por tramos rectos a velocidad constante.
func _move_path(p: Dictionary, speed: float, delta: float) -> bool:
	var step := speed * delta
	p["speed"] = speed
	while step > 0.0 and not p["path"].is_empty():
		var target: Vector2 = p["path"][0]
		var to: Vector2 = target - p["pos"]
		if to.length() > 0.01:
			p["heading"] = to.angle()
		if to.length() <= step:
			p["pos"] = target
			step -= to.length()
			p["path"].pop_front()
		else:
			p["pos"] += to.normalized() * step
			step = 0.0
	return p["path"].is_empty()


## Entra en espera describiendo círculos a derechas alrededor de un punto junto a su posición.
func _enter_hold(p: Dictionary) -> void:
	p["state"] = "holding"
	p["runway"] = -1
	p["path"] = []
	p["hold_center"] = p["pos"] + Vector2.from_angle(p["heading"] + PI / 2.0) * HOLD_RADIUS
	p["hold_angle"] = (p["pos"] - p["hold_center"]).angle()


func _orbit(p: Dictionary, delta: float) -> void:
	p["hold_angle"] += AIR_SPEED / HOLD_RADIUS * delta
	p["pos"] = p["hold_center"] + Vector2.from_angle(p["hold_angle"]) * HOLD_RADIUS
	p["heading"] = p["hold_angle"] + PI / 2.0
	p["speed"] = AIR_SPEED


func _go_around(p: Dictionary, why: String, fine: bool) -> void:
	var runway: int = p["runway"]
	p["state"] = "go_around"
	p["target_alt"] = float(GO_AROUND_ALT)
	p["path"] = [threshold(runway, p["dir"]) + Vector2(p["dir"] * 260.0, -120.0)]
	p["runway"] = -1
	day_go_arounds += 1
	if fine:
		day_fines += plane_value(p) * 0.25
	toast.emit("%s: motor y al aire, %s." % [p["callsign"], why])


func _touchdown(p: Dictionary) -> void:
	var runway: int = p["runway"]
	if runway_stormy(runway):
		_go_around(p, "cizalladura por tormenta en pista %d" % (runway + 1), false)
		return
	if not runway_clear(runway):
		_go_around(p, "la pista %d estaba ocupada" % (runway + 1), true)
		return
	if separation_left(runway, p["wake"]) > 0.0:
		_infraction(p, "aterrizó sin separación por estela")
	p["state"] = "landing"
	p["alt"] = 0.0
	p["target_alt"] = 0.0
	p["heading"] = 0.0 if p["dir"] > 0 else PI
	p["speed"] = FINAL_SPEED
	runways[runway]["op"] = p


func _release_runway(p: Dictionary) -> void:
	var r: Dictionary = runways[p["runway"]]
	r["op"] = {}
	r["prev_wake"] = p["wake"]
	r["since"] = 0.0


func _vacate_runway(p: Dictionary) -> void:
	_release_runway(p)
	if p["special"] == "engine":
		runways[p["runway"]]["closed"] = ENGINE_FAIL_CLOSE
		toast.emit("Pista %d cerrada %d s para inspección tras el fallo de motor de %s." % [p["runway"] + 1, ENGINE_FAIL_CLOSE, p["callsign"]])
	var d: int = p["dir"]
	var exit_x := runway_exit_x(d) + d * 20.0
	p["state"] = "taxi_in"
	p["path"] = [Vector2(exit_x, p["pos"].y), Vector2(exit_x, TAXI_Y), wait_gate_point(d)]
	p["gate"] = -1


## Al terminar el rodaje busca puerta; si no hay, espera en la calle de rodaje.
func _arrive_gate_or_wait(p: Dictionary) -> void:
	if p["gate"] >= 0:
		_pay(p)
		day_landed += 1
		gates[p["gate"]]["plane"] = -1
		gates[p["gate"]]["turn"] = TURNAROUND_TIME
		planes.erase(p)
		return
	var k := _free_gate()
	if k < 0:
		p["state"] = "wait_gate"
		return
	gates[k]["plane"] = p["id"]
	p["gate"] = k
	p["state"] = "taxi_in"
	var g := gate_pos(k)
	p["path"] = [Vector2(g.x, TAXI_Y), g]


func _free_gate() -> int:
	for k in gates.size():
		if gates[k]["plane"] < 0 and gates[k]["turn"] <= 0.0:
			return k
	return -1


func _liftoff(p: Dictionary) -> void:
	_release_runway(p)
	p["state"] = "climb"
	# Restricción de salida: mantienen 2000 ft, por debajo de las esperas, hasta dejar el sector.
	p["target_alt"] = 2000.0
	p["exit"] = Vector2(MAP_SIZE.x + 60 if p["dir"] > 0 else -60.0, p["pos"].y - 250)


func _check_separation() -> void:
	var air := planes.filter(func(p): return is_airborne(p) and p["alt"] > 50.0)
	for p in air:
		p["conflict"] = false
	for i in air.size():
		for j in range(i + 1, air.size()):
			var a: Dictionary = air[i]
			var b: Dictionary = air[j]
			var d: float = a["pos"].distance_to(b["pos"])
			var dalt: float = abs(a["alt"] - b["alt"])
			var key := "%d-%d" % [min(a["id"], b["id"]), max(a["id"], b["id"])]
			if d < CRASH_DIST and dalt < CRASH_ALT:
				_crash(a, b)
				return
			if d < TCAS_DIST and dalt < TCAS_ALT and not _tcas_pairs.has(key):
				_tcas(a, b, key)
			elif d > CONFLICT_DIST and _tcas_pairs.has(key):
				_tcas_pairs.erase(key)
			if d < CONFLICT_DIST and dalt < CONFLICT_ALT:
				a["conflict"] = true
				b["conflict"] = true


## Aviso de resolución TCAS: los pilotos ignoran a la torre, uno sube y otro baja. Es un incidente.
func _tcas(a: Dictionary, b: Dictionary, key: String) -> void:
	_tcas_pairs[key] = true
	day_tcas += 1
	var up: Dictionary = a if a["alt"] >= b["alt"] else b
	var down: Dictionary = b if up == a else a
	for pair in [[up, 1000.0], [down, -1000.0]]:
		var p: Dictionary = pair[0]
		if p["state"] == "approach":
			continue
		p["target_alt"] = clamp(p["alt"] + pair[1], 1000.0, 9000.0)
		p["tcas"] = 4.0
	_capture_replay("TCAS: %s y %s a %d ft" % [a["callsign"], b["callsign"], int(a["alt"])])
	toast.emit("TCAS RA: %s CLIMB, %s DESCEND." % [up["callsign"], down["callsign"]])
	incident.emit("tcas", a["callsign"], b["callsign"])
	_add_strike("pérdida de separación entre %s y %s" % [a["callsign"], b["callsign"]])


## Colisión en vuelo: se pierden los dos aviones y te despiden en el acto.
func _crash(a: Dictionary, b: Dictionary) -> void:
	_capture_replay("COLISIÓN: %s y %s a %d ft" % [a["callsign"], b["callsign"], int(a["alt"])])
	planes.erase(a)
	planes.erase(b)
	toast.emit("COLISIÓN entre %s y %s a %d ft." % [a["callsign"], b["callsign"], int(a["alt"])])
	incident.emit("crash", a["callsign"], b["callsign"])
	_schedule_fire("Colisión en vuelo entre %s y %s." % [a["callsign"], b["callsign"]])


func _infraction(p: Dictionary, what: String) -> void:
	day_infractions += 1
	day_fines += plane_value(p) * 0.5
	toast.emit("Infracción: %s %s. Multa de %s $." % [p["callsign"], what, format_number(plane_value(p) * 0.5)])


## Sin combustible: se desvía a otro aeropuerto saliendo del mapa. Es un incidente.
func _divert(p: Dictionary) -> void:
	if p["state"] == "approach" and not p["path"].is_empty():
		return
	p["state"] = "divert"
	p["exit"] = p["pos"] + (p["pos"] - MAP_SIZE * 0.5).normalized() * 900.0
	p["runway"] = -1
	day_diverted += 1
	_add_strike("%s se desvió sin combustible" % p["callsign"])


## Paga un avión; pierde un 10 % por cada 10 s de espera por encima del margen.
func _pay(p: Dictionary) -> void:
	var pay := plane_value(p)
	var late: float = max(0.0, p["wait"] - (90.0 if p["arrival"] else 45.0))
	pay *= max(0.3, 1.0 - 0.1 * floor(late / 10.0))
	day_pay += pay
	match p["special"]:
		"vip":
			if p["wait"] < 45.0:
				day_bonus += plane_value(p) * 4.0
				toast.emit("VIP %s en tierra a tiempo: x5." % p["callsign"])
			else:
				toast.emit("VIP %s llegó tarde: sin prima." % p["callsign"])
		"medical", "engine":
			day_emergencies += 1
			day_bonus += plane_value(p) * 2.0
			toast.emit("Emergencia de %s resuelta: prima de %s $." % [p["callsign"], format_number(plane_value(p) * 2.0)])


func _spawn() -> void:
	while not _spawn_queue.is_empty() and _spawn_queue[0]["t"] <= shift_elapsed:
		var s: Dictionary = _spawn_queue.pop_front()
		# Las salidas nacen en una puerta: si no hay puerta libre, llega una llegada en su lugar.
		var gate := _free_gate()
		var is_arrival: bool = rng.randf() < 0.5 or gate < 0 or s["kind"] == "vip"
		planes.append(_make_plane(is_arrival, s["kind"], gate))
		planes_spawned += 1
		if planes_spawned == planes_total:
			toast.emit("Último avión del día en camino.")


func _make_plane(is_arrival: bool, special: String = "", gate: int = -1) -> Dictionary:
	var tier: int = max_tier()
	if tier > 0 and rng.randf() < 0.4:
		tier = rng.randi_range(0, tier - 1)
	if special == "cargo":
		tier = 3
	var fuel: float = rng.randf_range(FUEL_RANGE.x, FUEL_RANGE.y) + 15.0 * levels["fuel_reserve"]
	if levels["lowcost"] > 0 and rng.randf() < 0.4:
		fuel -= 15.0
	if special in ["medical", "engine"]:
		fuel = EMERGENCY_FUEL
	var airline: String = AIRLINES[rng.randi() % AIRLINES.size()]
	if special == "cargo":
		airline = "CGO"
	elif special == "vip":
		airline = "VIP"
	var plane := {
		"id": _next_plane_id,
		"callsign": "%s%d" % [airline, rng.randi_range(100, 9999)],
		"arrival": is_arrival,
		"tier": tier,
		"model": MODEL_BY_TIER[tier],
		"wake": WAKE_BY_TIER[tier],
		"pax": PAX_BY_TIER[tier] if special != "cargo" else 0,
		"runway": -1,
		"gate": -1,
		"dir": wind_dir,
		"path": [],
		"speed": 0.0,
		"heading": 0.0,
		"alt": 0.0,
		"target_alt": 0.0,
		"fuel": fuel,
		"wait": 0.0,
		"special": special,
		"emergency": special in ["medical", "engine"],
		"mayday": false,
		"conflict": false,
		"tcas": 0.0,
	}
	if is_arrival:
		# Entra por un borde del mapa, rumbo al aeropuerto, a una altitud de crucero.
		var a := rng.randf_range(0.0, TAU)
		plane["pos"] = MAP_SIZE * 0.5 + Vector2(cos(a) * MAP_SIZE.x * 0.5, sin(a) * MAP_SIZE.y * 0.5) * 0.98
		plane["heading"] = (MAP_SIZE * 0.5 - plane["pos"]).angle()
		plane["alt"] = float(SPAWN_ALTITUDES[rng.randi() % SPAWN_ALTITUDES.size()])
		plane["target_alt"] = plane["alt"]
		plane["state"] = "inbound"
		plane["speed"] = AIR_SPEED
	else:
		gates[gate]["plane"] = _next_plane_id
		plane["gate"] = gate
		plane["pos"] = gate_pos(gate)
		plane["heading"] = -PI / 2.0
		plane["state"] = "gate"
	_next_plane_id += 1
	return plane


## El controlador de tierra hace el push-back sin saturar el punto de espera.
func _ground_control() -> void:
	if levels["ground"] == 0:
		return
	var queued := planes.filter(func(p): return p["state"] in ["pushback", "hold_point"]).size()
	for p in planes:
		if queued >= runways.size() + 1:
			return
		if p["state"] == "gate":
			push_back(p["id"])
			queued += 1


# --- Sucesos: emergencias, tormentas y viento -------------------------------

func _update_events() -> void:
	while not _events.is_empty() and _events[0]["t"] <= shift_elapsed:
		var e: Dictionary = _events.pop_front()
		match e["kind"]:
			"storm":
				_spawn_storm()
			"medical":
				var p := _make_plane(true, "medical")
				planes.append(p)
				toast.emit("PAN PAN, %s, emergencia médica a bordo. Combustible para %d s." % [p["callsign"], EMERGENCY_FUEL])
			"engine":
				var p := _make_plane(true, "engine")
				planes.append(p)
				toast.emit("MAYDAY, %s, fallo de motor. Tras la toma la pista quedará cerrada %d s." % [p["callsign"], ENGINE_FAIL_CLOSE])


## Una tormenta entra por un borde y cruza el mapa pasando cerca del aeropuerto.
func _spawn_storm() -> void:
	var a := rng.randf_range(0.0, TAU)
	var start := MAP_SIZE * 0.5 + Vector2(cos(a) * 1000.0, sin(a) * 700.0)
	var aim := MAP_SIZE * 0.5 + Vector2(rng.randf_range(-250, 250), rng.randf_range(-200, 200))
	var speed := rng.randf_range(30.0, 42.0) + day * 0.5
	storms.append({"pos": start, "vel": (aim - start).normalized() * speed,
		"radius": rng.randf_range(110.0, 170.0) + min(day * 3.0, 40.0)})
	toast.emit("Meteo: célula de tormenta entrando en el sector. Dentro, el doble de consumo; sobre la pista, no se opera.")


func _update_storms(delta: float) -> void:
	for s in storms.duplicate():
		s["pos"] += s["vel"] * delta
		var center := MAP_SIZE * 0.5
		var leaving: bool = (s["pos"] - center).dot(s["vel"]) > 0.0
		if leaving and s["pos"].distance_to(center) > 1100.0:
			storms.erase(s)


## Segundos de aviso antes de que cambie el viento.
func wind_warning_time() -> float:
	return 30.0 if levels["meteo"] > 0 else 15.0


func _update_wind(delta: float) -> void:
	if _wind_at < 0.0:
		return
	var left := _wind_at - shift_elapsed
	if not _wind_warned and left <= wind_warning_time():
		_wind_warned = true
		toast.emit("ATIS: el viento rola. En %d s cambian las pistas en uso a %s." % [ceil(left), runway_name(-wind_dir)])
	if _wind_warned:
		wind_change_in = max(0.0, left)
	if left <= 0.0:
		_wind_at = -1.0
		wind_change_in = -1.0
		_flip_wind()


## Cambio de pista en uso: las aproximaciones en curso abortan y las salidas ruedan a la otra cabecera.
func _flip_wind() -> void:
	wind_dir = -wind_dir
	for r in runways:
		r["lined"] = {}
	for p in planes:
		match p["state"]:
			"approach":
				_go_around(p, "cambio de pista en uso", false)
				p["dir"] = wind_dir
			"hold_point", "line_up", "lined_up", "pushback":
				p["state"] = "pushback"
				p["runway"] = -1
				p["dir"] = wind_dir
				p["path"] = [Vector2(p["pos"].x, TAXI_Y), hold_point()]
			"inbound", "holding", "gate", "go_around":
				p["dir"] = wind_dir
	toast.emit("Pistas en uso: %s. Las salidas ruedan a la nueva cabecera." % runway_name())


# --- Repeticiones -------------------------------------------------------------

## Guarda una foto de los aviones cada décima de segundo para poder repetir los incidentes.
func _record(delta: float) -> void:
	_history_t += delta
	if _history_t < REPLAY_EVERY:
		return
	_history_t = 0.0
	var frame := []
	for p in planes:
		frame.append({
			"id": p["id"], "callsign": p["callsign"], "pos": p["pos"], "heading": p["heading"],
			"alt": p["alt"], "target_alt": p["target_alt"], "state": p["state"], "wake": p["wake"],
			"arrival": p["arrival"], "emergency": p["emergency"], "special": p["special"],
			"fuel": p["fuel"], "conflict": p["conflict"], "mayday": p["mayday"],
		})
	_history.append(frame)
	if _history.size() > REPLAY_BEFORE:
		_history.pop_front()
	for r in _pending_replays.duplicate():
		r["frames"].append(frame)
		r["left"] -= 1
		if r["left"] <= 0:
			_pending_replays.erase(r)
			replays.append({"title": r["title"], "frames": r["frames"]})


func _capture_replay(title: String) -> void:
	_pending_replays.append({"title": title, "frames": _history.duplicate(), "left": REPLAY_AFTER})


# --- Guardado ---------------------------------------------------------------

## Se guarda al elegir carta; un turno a medias se reinicia al volver.
func to_dict() -> Dictionary:
	return {
		"version": SAVE_VERSION, "daily": daily, "seed": seed_value, "rng_state": str(rng.state),
		"money": money, "day": day, "strikes": strikes, "levels": levels, "wind_dir": wind_dir,
		"phase": phase, "offer": offer,
	}


func from_dict(d: Dictionary) -> void:
	daily = bool(d.get("daily", false))
	seed_value = int(d.get("seed", 0))
	rng.seed = seed_value
	rng.state = str(d.get("rng_state", str(rng.state))).to_int()
	money = float(d.get("money", 0.0))
	day = int(d.get("day", 1))
	strikes = int(d.get("strikes", 0))
	wind_dir = int(d.get("wind_dir", 1))
	levels = {}
	var saved: Dictionary = d.get("levels", {})
	for id in CARDS:
		levels[id] = int(saved.get(id, 0))
	offer = d.get("offer", [])
	if int(d.get("phase", Phase.SHIFT)) == Phase.DRAFT and not offer.is_empty():
		phase = Phase.DRAFT
	else:
		start_shift()


func save_run() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(to_dict()))


func load_run() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var data = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if typeof(data) != TYPE_DICTIONARY or int(data.get("version", 0)) != SAVE_VERSION:
		return false
	from_dict(data)
	return true


func save_records() -> void:
	var f := FileAccess.open(RECORDS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"best_days": best_days, "best_money": best_money, "daily": daily_best}))


func load_records() -> void:
	if not FileAccess.file_exists(RECORDS_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(RECORDS_PATH))
	if typeof(data) != TYPE_DICTIONARY:
		return
	best_days = int(data.get("best_days", 0))
	best_money = float(data.get("best_money", 0.0))
	daily_best = data.get("daily", {})


static func format_number(n: float) -> String:
	if n < 1000.0:
		return str(int(n))
	var suffixes := ["K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No"]
	var i := -1
	while n >= 1000.0 and i < suffixes.size() - 1:
		n /= 1000.0
		i += 1
	return "%.2f %s" % [n, suffixes[i]]
