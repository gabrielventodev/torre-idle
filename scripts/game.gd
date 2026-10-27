extends Node
## Estado y simulación del juego. No contiene UI: la escena principal lo lee y llama a sus acciones.
## Se registra como autoload "Game". Los tests lo instancian con .new() y llaman a new_game().
##
## Bucle: turno de 9 a 18 (se coordinan los aviones pedidos ese día) -> cobro -> tienda -> siguiente día.
##
## Simulación espacial: cada avión tiene posición en el mapa (unidades de mundo), rumbo, velocidad
## y altitud, y se mueve de forma continua.
##   Llegada: entrante -> espera en círculo (a la altitud que ordenes) -> aproximación -> toma y
##            carrera en pista -> rodaje -> puerta.
##   Salida:  puerta -> push-back y rodaje -> punto de espera -> entra en pista -> despegue y ascenso.
## Una pista solo admite una operación a la vez, tras cada operación hay que respetar la
## separación por estela, y dos aviones en vuelo a la misma altitud y en el mismo sitio chocan.

signal toast(text: String)

enum Phase { SHIFT, PAYDAY, SHOP }

const SAVE_PATH := "user://save.json"
## Pago por avión coordinado según el nivel de radar.
const PAY_BY_RADAR := [100, 250, 600, 1500]
const MODEL_BY_RADAR := ["Cessna 208", "ATR 72", "A320", "B787"]
const PAX_BY_RADAR := [9, 68, 180, 290]
## Categoría de estela: 0 ligera, 1 media, 2 pesada.
const WAKE_BY_RADAR := [0, 1, 1, 2]
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
const HOLD_POINT := Vector2(550, 490)
const WAIT_GATE_POINT := Vector2(1070, 490)
## Distancia del punto de entrada a final antes del umbral de pista.
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
## Si un entrante no recibe orden, entra en espera solo al llegar a esta distancia del aeropuerto.
const AUTO_HOLD_DIST := 330.0
## Separación mínima: menos que esto en horizontal y vertical es colisión.
const CRASH_DIST := 16.0
const CRASH_ALT := 400.0
const CONFLICT_DIST := 70.0
const CONFLICT_ALT := 900.0

const BASE_PLANES_PER_DAY := 2
const BASE_GATES := 2
const MAX_GATES := 11
const TURNAROUND_TIME := 8.0
const MAX_RUNWAYS := 4
const MILESTONES := [10, 25, 50, 100]
const SHIFT_START := 9.0
const SHIFT_END := 18.0
const AIRPORTS := ["Aeródromo local", "Aeropuerto regional"]

## max = -1 significa sin límite.
const UPGRADES := {
	"traffic": {"name": "Más tráfico", "base": 150.0, "growth": 1.35, "max": -1,
		"desc": "+1 avión por turno"},
	"fees": {"name": "Tasas aeroportuarias", "base": 200.0, "growth": 1.4, "max": -1,
		"desc": "+15 % de pago por avión"},
	"gates": {"name": "Puerta de embarque", "base": 250.0, "growth": 1.6, "max": MAX_GATES - BASE_GATES - 2,
		"desc": "+1 puerta para salidas y llegadas"},
	"taxiway": {"name": "Calles de rodaje", "base": 300.0, "growth": 1.5, "max": 6,
		"desc": "+15 % de velocidad de rodaje"},
	"wake_monitor": {"name": "Monitor de estela", "base": 400.0, "growth": 1.0, "max": 1,
		"desc": "Muestra la cuenta atrás de separación en cada pista"},
	"rapid_exit": {"name": "Salida rápida de pista", "base": 500.0, "growth": 1.5, "max": 4,
		"desc": "Los aterrizajes dejan la pista antes"},
	"runway": {"name": "Pista adicional", "base": 2500.0, "growth": 8.0, "max": MAX_RUNWAYS - 1,
		"desc": "+1 pista"},
	"radar": {"name": "Radar", "base": 800.0, "growth": 6.0, "max": 3,
		"desc": "Aviones más grandes: pagan más y dejan más estela"},
	"ground": {"name": "Controlador de tierra", "base": 1500.0, "growth": 1.0, "max": 1,
		"desc": "Hace el push-back de las salidas; la torre sigue siendo tuya"},
}

const XP_TREE := {
	"start_ground": {"name": "Empezar con controlador de tierra", "cost": 1},
	"extra_gates": {"name": "+2 puertas", "cost": 2},
	"frequent_crisis": {"name": "Crisis más frecuentes", "cost": 2},
}

var save_enabled := true
var rng := RandomNumberGenerator.new()

# Persistente entre prestigios.
var xp_available := 0
var xp_total := 0
var airport_level := 0
var tree_owned := {}

# Estado de la partida actual.
var money := 0.0
var run_money := 0.0
var day := 1
var levels := {}
var phase := Phase.SHOP

# Estado del turno en curso.
## Todos los aviones activos del turno, en orden de llegada.
var planes: Array = []
var runways: Array = []
## Una entrada por puerta: {"plane": id o -1, "turn": segundos de escala restantes}.
var gates: Array = []
var planes_total := 0
var planes_spawned := 0
var shift_elapsed := 0.0
var shift_length := 0.0
var day_pay := 0.0
var day_fines := 0.0
var day_landed := 0
var day_departed := 0
var day_diverted := 0
var day_go_arounds := 0
var day_infractions := 0
var day_crashes := 0
var day_bonus := 0.0
var last_summary := {}
var _spawn_interval := 0.0
var _spawn_timer := 0.0
var _done_announced := false

# Evento de crisis del día ("" si no hay). Como mucho uno por turno.
var event_id := ""
var event_time := 0.0
var event_success := true
var _event_at := -1.0
var _storm_won := false

var _next_plane_id := 1


func _ready() -> void:
	rng.randomize()
	if not load_game():
		new_game()


func _process(delta: float) -> void:
	simulate(delta)


func new_game() -> void:
	xp_available = 0
	xp_total = 0
	airport_level = 0
	tree_owned = {}
	reset_run()


## Reinicia la partida y arranca el primer turno.
func reset_run() -> void:
	money = 0.0
	run_money = 0.0
	day = 1
	levels = {}
	for id in UPGRADES:
		levels[id] = 0
	if tree_owned.get("start_ground", false):
		levels["ground"] = 1
	start_shift()


# --- Fórmulas -------------------------------------------------------------

func planes_per_day() -> int:
	return BASE_PLANES_PER_DAY + levels["traffic"]


func runway_count() -> int:
	return 1 + levels["runway"]


func gate_count() -> int:
	var n: int = BASE_GATES + levels["gates"]
	if tree_owned.get("extra_gates", false):
		n += 2
	return min(n, MAX_GATES)


func gates_used() -> int:
	var n := 0
	for g in gates:
		if g["plane"] >= 0 or g["turn"] > 0.0:
			n += 1
	return n


func taxi_speed() -> float:
	return TAXI_SPEED * pow(1.15, levels["taxiway"])


## Punto de la pista donde los aterrizajes la abandonan; la salida rápida lo adelanta.
func runway_exit_x() -> float:
	return RUNWAY_X1 - 50.0 * levels["rapid_exit"]


## Multiplica x2 el efecto en cada hito (10, 25, 50, 100 unidades).
func milestone_mult(id: String) -> float:
	var m := 1.0
	for threshold in MILESTONES:
		if levels[id] >= threshold:
			m *= 2.0
	return m


func pay_mult() -> float:
	var m: float = (1.0 + 0.15 * levels["fees"]) * milestone_mult("fees")
	m *= 1.0 + 0.05 * xp_total
	m *= 1.0 + airport_level
	return m


func plane_value(plane: Dictionary) -> float:
	return PAY_BY_RADAR[plane["tier"]] * pay_mult()


func upgrade_cost(id: String) -> float:
	var u: Dictionary = UPGRADES[id]
	return u["base"] * pow(u["growth"], levels[id])


func upgrade_maxed(id: String) -> bool:
	var u: Dictionary = UPGRADES[id]
	return u["max"] >= 0 and levels[id] >= u["max"]


## Las mejoras solo se compran en la tienda, entre turnos.
func can_buy(id: String) -> bool:
	return phase == Phase.SHOP and not upgrade_maxed(id) and money >= upgrade_cost(id)


## Cada aeropuerto exige 4 veces más dinero para la misma experiencia.
func prestige_threshold() -> float:
	return 1e6 * pow(4.0, airport_level)


func xp_gain() -> int:
	return int(floor(sqrt(run_money / prestige_threshold())))


## Hora del reloj de la torre (9.0 a 18.0).
func clock_hours() -> float:
	if shift_done():
		return SHIFT_END
	return SHIFT_START + (SHIFT_END - SHIFT_START) * clamp(shift_elapsed / shift_length, 0.0, 1.0)


func planes_pending() -> int:
	return planes_total - planes_spawned


## El turno termina cuando no quedan aviones por llegar ni en movimiento.
func shift_done() -> bool:
	if phase != Phase.SHIFT or planes_spawned < planes_total or event_id != "":
		return false
	return planes.is_empty()


func runway_y(i: int) -> float:
	return RUNWAY_Y0 - i * RUNWAY_SPACING


func threshold(i: int) -> Vector2:
	return Vector2(RUNWAY_X0, runway_y(i))


func gate_pos(k: int) -> Vector2:
	return Vector2(GATE_X0 + k * GATE_SPACING, GATE_Y)


## Segundos de separación que aún faltan en una pista para un avión de la categoría dada.
func separation_left(runway: int, wake: int) -> float:
	var r: Dictionary = runways[runway]
	if r["prev_wake"] < 0:
		return 0.0
	return max(0.0, SEPARATION[r["prev_wake"]][wake] - r["since"])


## Una pista está libre si no hay nadie rodando por ella ni entrando o alineado.
func runway_clear(runway: int) -> bool:
	var r: Dictionary = runways[runway]
	return r["op"].is_empty() and r["lined"].is_empty()


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
## Si al llegar la pista está ocupada, hace motor y al aire.
func clear_landing(plane_id: int, runway: int) -> bool:
	var p := _find(plane_id)
	if p.is_empty() or not p["state"] in ["inbound", "holding"] or runway < 0 or runway >= runways.size():
		return false
	p["state"] = "approach"
	p["runway"] = runway
	p["path"] = _approach_path(p["pos"], runway)
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
	p["path"] = [Vector2(g.x, TAXI_Y), HOLD_POINT]
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
	p["path"] = [Vector2(RUNWAY_X0 - 30, runway_y(runway)), threshold(runway) + Vector2(6, 0)]
	runways[runway]["lined"] = p
	return true


## Autoriza el despegue de un avión alineado. Si no se respeta la separación por estela,
## despega igual pero se registra una infracción con multa.
func clear_takeoff(plane_id: int) -> bool:
	var p := _find(plane_id)
	if p.is_empty() or p["state"] != "lined_up":
		return false
	var r: Dictionary = runways[p["runway"]]
	if separation_left(p["runway"], p["wake"]) > 0.0:
		_infraction(p, "despegó sin separación por estela")
	r["lined"] = {}
	r["op"] = p
	p["state"] = "takeoff"
	p["speed"] = 0.0
	return true


# --- Acciones del jugador: entre turnos -----------------------------------

func start_shift() -> void:
	phase = Phase.SHIFT
	planes.clear()
	runways.clear()
	for i in runway_count():
		runways.append({"op": {}, "lined": {}, "prev_wake": -1, "since": 0.0})
	gates.clear()
	for k in gate_count():
		gates.append({"plane": -1, "turn": 0.0})
	planes_total = planes_per_day()
	planes_spawned = 0
	_spawn_interval = clamp(30.0 / planes_total, 3.0, 8.0)
	_spawn_timer = 0.5
	shift_elapsed = 0.0
	shift_length = _spawn_interval * planes_total + 60.0
	day_pay = 0.0
	day_fines = 0.0
	day_landed = 0
	day_departed = 0
	day_diverted = 0
	day_go_arounds = 0
	day_infractions = 0
	day_crashes = 0
	day_bonus = 0.0
	_done_announced = false
	event_id = ""
	_storm_won = false
	var chance := 0.5 if tree_owned.get("frequent_crisis", false) else 0.3
	_event_at = rng.randf_range(0.2, 0.5) * shift_length if day > 1 and rng.randf() < chance else -1.0


## Cierra el turno y prepara el resumen de cobro.
func end_day() -> bool:
	if not shift_done():
		return false
	if _storm_won:
		day_bonus += day_pay * 0.5
	last_summary = {
		"day": day, "landed": day_landed, "departed": day_departed, "diverted": day_diverted,
		"go_arounds": day_go_arounds, "infractions": day_infractions, "crashes": day_crashes,
		"pay": day_pay, "bonus": day_bonus, "fines": day_fines,
		"total": max(0.0, day_pay + day_bonus - day_fines),
	}
	phase = Phase.PAYDAY
	return true


func collect_pay() -> bool:
	if phase != Phase.PAYDAY:
		return false
	money += last_summary["total"]
	run_money += last_summary["total"]
	phase = Phase.SHOP
	if save_enabled:
		save_game()
	return true


func next_day() -> bool:
	if phase != Phase.SHOP:
		return false
	day += 1
	start_shift()
	if save_enabled:
		save_game()
	return true


func buy(id: String) -> bool:
	if not can_buy(id):
		return false
	money -= upgrade_cost(id)
	levels[id] += 1
	return true


func can_prestige() -> bool:
	return phase == Phase.SHOP and xp_gain() >= 1


func prestige() -> bool:
	if not can_prestige():
		return false
	var gain := xp_gain()
	xp_available += gain
	xp_total += gain
	airport_level = min(airport_level + 1, AIRPORTS.size() - 1)
	reset_run()
	toast.emit("Bienvenido a %s. +%d de experiencia." % [AIRPORTS[airport_level], gain])
	if save_enabled:
		save_game()
	return true


func buy_tree(id: String) -> bool:
	if tree_owned.get(id, false) or xp_available < XP_TREE[id]["cost"]:
		return false
	xp_available -= XP_TREE[id]["cost"]
	tree_owned[id] = true
	return true


# --- Simulación del turno --------------------------------------------------

func simulate(delta: float) -> void:
	if phase != Phase.SHIFT:
		return
	shift_elapsed += delta
	for r in runways:
		r["since"] += delta
	for g in gates:
		g["turn"] = max(0.0, g["turn"] - delta)
	for p in planes.duplicate():
		if planes.has(p):
			_update_plane(p, delta)
	_check_separation()
	_spawn(delta)
	_ground_control()
	_update_event(delta)
	if not _done_announced and shift_done():
		_done_announced = true
		toast.emit("Torre: no vienen más aviones hoy. Puedes terminar el día.")


func _find(plane_id: int) -> Dictionary:
	for p in planes:
		if p["id"] == plane_id:
			return p
	return {}


func _update_plane(p: Dictionary, delta: float) -> void:
	p["wait"] += delta
	if p["arrival"] and is_airborne(p) and p["state"] != "divert":
		p["fuel"] -= delta
		if p["fuel"] <= 0.0:
			_divert(p)
	_update_altitude(p, delta)
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
			p["pos"].x += p["speed"] * delta
			if p["pos"].x >= runway_exit_x():
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
				p["heading"] = 0.0
		"takeoff":
			p["speed"] = min(TAKEOFF_SPEED, p["speed"] + 32.0 * delta)
			p["pos"].x += p["speed"] * delta
			if p["pos"].x >= RUNWAY_X1:
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
	p["alt"] += clamp(diff, -CLIMB_RATE * delta, CLIMB_RATE * delta)


## Senda de planeo: 1500 ft al entrar en final y 0 en el umbral.
func _glide_slope(p: Dictionary, delta: float) -> void:
	var t := threshold(p["runway"])
	if p["path"].size() <= 1:
		p["alt"] = min(p["alt"], 1500.0 * clamp(p["pos"].distance_to(t) / FINAL_DIST, 0.0, 1.0))
	else:
		p["alt"] = move_toward(p["alt"], 1500.0, CLIMB_RATE * delta)


## Trayectoria de aproximación: si viene del lado contrario, tramo base al costado de la pista;
## luego punto de entrada a final alineado con la pista, y el umbral.
func _approach_path(from: Vector2, runway: int) -> Array:
	var t := threshold(runway)
	var join := t - Vector2(FINAL_DIST, 0)
	var path := []
	if from.x > join.x + 40.0:
		var side := 1.0 if from.y >= t.y else -1.0
		path.append(Vector2(from.x, t.y + side * 190.0) if from.x < RUNWAY_X1 else Vector2(RUNWAY_X1, t.y + side * 190.0))
		path.append(Vector2(join.x - 60.0, t.y + side * 190.0))
		path.append(Vector2(join.x - 90.0, t.y + side * 70.0))
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
	var passed: bool = last and p["pos"].x >= target.x - 2.0 and abs(p["pos"].y - target.y) < 30.0
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


func _touchdown(p: Dictionary) -> void:
	var runway: int = p["runway"]
	if not runway_clear(runway):
		# Pista ocupada: motor y al aire, sube a la altitud de frustrada y vuelve a esperar.
		p["state"] = "go_around"
		p["target_alt"] = float(GO_AROUND_ALT)
		p["path"] = [threshold(runway) + Vector2(260, -120)]
		p["runway"] = -1
		day_go_arounds += 1
		day_fines += plane_value(p) * 0.25
		if event_id == "storm":
			event_success = false
		toast.emit("%s: motor y al aire, la pista %d estaba ocupada." % [p["callsign"], runway + 1])
		return
	if separation_left(runway, p["wake"]) > 0.0:
		_infraction(p, "aterrizó sin separación por estela")
	p["state"] = "landing"
	p["alt"] = 0.0
	p["target_alt"] = 0.0
	p["heading"] = 0.0
	p["speed"] = FINAL_SPEED * (0.75 if event_id == "storm" else 1.0)
	runways[runway]["op"] = p


func _release_runway(p: Dictionary) -> void:
	var r: Dictionary = runways[p["runway"]]
	r["op"] = {}
	r["prev_wake"] = p["wake"]
	r["since"] = 0.0


func _vacate_runway(p: Dictionary) -> void:
	_release_runway(p)
	var exit_x := runway_exit_x() + 20.0
	p["state"] = "taxi_in"
	p["path"] = [Vector2(exit_x, p["pos"].y), Vector2(exit_x, TAXI_Y), WAIT_GATE_POINT]
	p["gate"] = -1


## Al terminar el rodaje busca puerta; si no hay, espera en la calle de rodaje.
func _arrive_gate_or_wait(p: Dictionary) -> void:
	if p["gate"] >= 0:
		_pay(p)
		day_landed += 1
		gates[p["gate"]]["plane"] = -1
		gates[p["gate"]]["turn"] = TURNAROUND_TIME
		planes.erase(p)
		if p["emergency"] and event_id == "emergency":
			_end_event(true, plane_value(p) * 3.0)
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
	p["target_alt"] = 6000.0
	p["exit"] = Vector2(MAP_SIZE.x + 60, p["pos"].y - 250)


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
			if d < CRASH_DIST and dalt < CRASH_ALT:
				_crash(a, b)
				return
			if d < CONFLICT_DIST and dalt < CONFLICT_ALT:
				a["conflict"] = true
				b["conflict"] = true


## Colisión en vuelo: se pierden los dos aviones y todo el dinero.
func _crash(a: Dictionary, b: Dictionary) -> void:
	planes.erase(a)
	planes.erase(b)
	day_crashes += 1
	money = 0.0
	day_pay = 0.0
	day_bonus = 0.0
	toast.emit("COLISIÓN entre %s y %s a %d ft. Pierdes todo el dinero." % [a["callsign"], b["callsign"], int(a["alt"])])


func _infraction(p: Dictionary, what: String) -> void:
	day_infractions += 1
	day_fines += plane_value(p) * 0.5
	toast.emit("Infracción: %s %s. Multa de %s $." % [p["callsign"], what, format_number(plane_value(p) * 0.5)])


## Sin combustible: se desvía a otro aeropuerto saliendo del mapa.
func _divert(p: Dictionary) -> void:
	if p["state"] == "approach" and not p["path"].is_empty():
		return
	p["state"] = "divert"
	p["exit"] = p["pos"] + (p["pos"] - MAP_SIZE * 0.5).normalized() * 900.0
	p["runway"] = -1
	if p["emergency"]:
		if event_id == "emergency":
			_end_event(false, 0.0)
	else:
		day_diverted += 1
		if event_id == "storm":
			event_success = false
	toast.emit("%s se desvía por falta de combustible." % p["callsign"])


## Paga un avión; pierde un 10 % por cada 10 s de espera por encima del margen.
func _pay(p: Dictionary) -> void:
	var pay := plane_value(p)
	var late: float = max(0.0, p["wait"] - (90.0 if p["arrival"] else 45.0))
	pay *= max(0.3, 1.0 - 0.1 * floor(late / 10.0))
	day_pay += pay


func _spawn(delta: float) -> void:
	if planes_spawned >= planes_total:
		return
	_spawn_timer -= delta
	if _spawn_timer > 0.0:
		return
	# Las salidas nacen en una puerta: si no hay puerta libre, llega una llegada en su lugar.
	var gate := _free_gate()
	var is_arrival := rng.randf() < 0.5 or gate < 0
	planes.append(_make_plane(is_arrival, false, gate))
	planes_spawned += 1
	# Llegan en oleadas irregulares, como los bancos de un aeropuerto real.
	_spawn_timer = _spawn_interval * rng.randf_range(0.3, 1.7)
	if planes_spawned == planes_total:
		toast.emit("Último avión del día en camino.")


func _make_plane(is_arrival: bool, emergency: bool, gate: int = -1) -> Dictionary:
	# Con más radar, la mayoría de aviones son del tamaño máximo desbloqueado.
	var tier: int = levels["radar"]
	if tier > 0 and rng.randf() < 0.4:
		tier = rng.randi_range(0, tier - 1)
	var plane := {
		"id": _next_plane_id,
		"callsign": "%s%d" % [AIRLINES[rng.randi() % AIRLINES.size()], rng.randi_range(100, 9999)],
		"arrival": is_arrival,
		"tier": tier,
		"model": MODEL_BY_RADAR[tier],
		"wake": WAKE_BY_RADAR[tier],
		"pax": PAX_BY_RADAR[tier],
		"runway": -1,
		"gate": -1,
		"path": [],
		"speed": 0.0,
		"heading": 0.0,
		"alt": 0.0,
		"target_alt": 0.0,
		"fuel": 40.0 if emergency else rng.randf_range(60.0, 90.0),
		"wait": 0.0,
		"emergency": emergency,
		"conflict": false,
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


# --- Eventos de crisis -----------------------------------------------------

func _update_event(delta: float) -> void:
	if event_id == "":
		if _event_at >= 0.0 and shift_elapsed >= _event_at:
			_event_at = -1.0
			_start_event(["storm", "emergency"][rng.randi() % 2])
		return
	event_time -= delta
	if event_time <= 0.0 and event_id == "storm":
		# La tormenta se gana sobreviviéndola sin desvíos ni motores y al aire.
		if event_success:
			_storm_won = true
			toast.emit("Tormenta superada: +50 % de pago hoy.")
			_end_event(true, 0.0)
		else:
			_end_event(false, 0.0)


func _start_event(id: String) -> void:
	event_id = id
	event_success = true
	match id:
		"storm":
			event_time = 30.0
			toast.emit("Tormenta: las tomas son más lentas durante 30 s. Sin desvíos ni motores y al aire, +50 % de pago hoy.")
		"emergency":
			planes.append(_make_plane(true, true))
			toast.emit("Emergencia médica: aterriza el avión marcado antes de que se quede sin combustible.")


func _end_event(success: bool, bonus: float) -> void:
	var id := event_id
	event_id = ""
	if not success:
		toast.emit("La crisis pasó sin bonificación.")
		return
	day_bonus += bonus
	if id == "emergency":
		toast.emit("Emergencia resuelta: bonificación de %s $." % format_number(bonus))


# --- Guardado ---------------------------------------------------------------

## Se guarda entre turnos; un turno a medias se reinicia al volver.
func to_dict() -> Dictionary:
	return {
		"version": 4,
		"xp_available": xp_available, "xp_total": xp_total,
		"airport_level": airport_level, "tree_owned": tree_owned,
		"money": money, "run_money": run_money, "day": day, "levels": levels,
	}


func from_dict(d: Dictionary) -> void:
	new_game()
	xp_available = int(d.get("xp_available", 0))
	xp_total = int(d.get("xp_total", 0))
	airport_level = int(d.get("airport_level", 0))
	tree_owned = d.get("tree_owned", {})
	money = float(d.get("money", 0.0))
	run_money = float(d.get("run_money", 0.0))
	day = int(d.get("day", 1))
	var saved_levels: Dictionary = d.get("levels", {})
	for id in UPGRADES:
		levels[id] = int(saved_levels.get(id, 0))
	start_shift()


func save_game() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(to_dict()))


func load_game() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var data = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if typeof(data) != TYPE_DICTIONARY or int(data.get("version", 0)) != 4:
		return false
	from_dict(data)
	return true


static func format_number(n: float) -> String:
	if n < 1000.0:
		return str(int(n))
	var suffixes := ["K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No"]
	var i := -1
	while n >= 1000.0 and i < suffixes.size() - 1:
		n /= 1000.0
		i += 1
	return "%.2f %s" % [n, suffixes[i]]
