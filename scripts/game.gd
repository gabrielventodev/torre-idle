extends Node
## Estado y simulación del juego. No contiene UI: la escena principal lo lee y llama a sus acciones.
## Se registra como autoload "Game". Los tests lo instancian con .new() y llaman a new_game().
##
## Bucle: turno de 9 a 18 (se coordinan los aviones pedidos ese día) -> cobro -> tienda -> siguiente día.
##
## Cada avión pasa por fases como en una torre real:
##   Llegada: aproximación -> final (autorizado a una pista) -> aterrizaje -> rodaje -> puerta.
##   Salida:  puerta -> push-back y rodaje -> punto de espera -> alineado en pista -> despegue.
## Una pista solo admite una operación a la vez, y tras cada operación hay que respetar
## la separación por estela turbulenta según el tamaño del avión anterior y el siguiente.

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
const BASE_PLANES_PER_DAY := 2
const BASE_GATES := 2
const FINAL_TIME := 6.0
const LANDING_TIME := 3.0
const TAKEOFF_TIME := 2.5
const TAXI_TIME := 6.0
const PUSHBACK_TIME := 3.0
const TURNAROUND_TIME := 8.0
const GO_AROUND_FUEL := 10.0
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
	"gates": {"name": "Puerta de embarque", "base": 250.0, "growth": 1.6, "max": 7,
		"desc": "+1 puerta para salidas y llegadas"},
	"taxiway": {"name": "Calles de rodaje", "base": 300.0, "growth": 1.5, "max": 6,
		"desc": "-15 % de tiempo de rodaje"},
	"wake_monitor": {"name": "Monitor de estela", "base": 400.0, "growth": 1.0, "max": 1,
		"desc": "Muestra la cuenta atrás de separación en cada pista"},
	"rapid_exit": {"name": "Salida rápida de pista", "base": 500.0, "growth": 1.5, "max": 5,
		"desc": "-10 % de ocupación de pista al aterrizar"},
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
## Segundos restantes de escala de los aviones llegados que aún ocupan puerta.
var turnarounds: Array = []
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
	var n: int = BASE_PLANES_PER_DAY + levels["traffic"]
	if tree_owned.get("extra_traffic", false):
		n += 2
	return n


func runway_count() -> int:
	return 1 + levels["runway"]


func gate_count() -> int:
	var n: int = BASE_GATES + levels["gates"]
	if tree_owned.get("extra_gates", false):
		n += 2
	return n


func gates_used() -> int:
	var n := turnarounds.size()
	for p in planes:
		if p["state"] == "gate":
			n += 1
	return n


func taxi_time() -> float:
	return TAXI_TIME * pow(0.85, levels["taxiway"])


func landing_time() -> float:
	var t: float = LANDING_TIME * pow(0.9, levels["rapid_exit"])
	return t * (1.5 if event_id == "storm" else 1.0)


func takeoff_time() -> float:
	return TAKEOFF_TIME * (1.5 if event_id == "storm" else 1.0)


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
	if not planes.is_empty():
		return false
	for r in runways:
		if not r["op"].is_empty():
			return false
	return true


## Segundos de separación que aún faltan en una pista para un avión de la categoría dada.
func separation_left(runway: int, wake: int) -> float:
	var r: Dictionary = runways[runway]
	if r["prev_wake"] < 0:
		return 0.0
	return max(0.0, SEPARATION[r["prev_wake"]][wake] - r["since"])


## Una pista está libre si no hay nadie rodando por ella ni alineado.
func runway_clear(runway: int) -> bool:
	var r: Dictionary = runways[runway]
	return r["op"].is_empty() and r["lined"].is_empty()


func arrivals() -> Array:
	return planes.filter(func(p): return p["arrival"])


func departures() -> Array:
	return planes.filter(func(p): return not p["arrival"])


## Aviones en final hacia una pista (autorizados a aterrizar y aún en el aire).
func finals_on(runway: int) -> Array:
	return planes.filter(func(p): return p["state"] == "final" and p["runway"] == runway)


# --- Acciones del jugador: turno -------------------------------------------

## Autoriza a un avión en aproximación a aterrizar en una pista. Toca pista en FINAL_TIME s;
## si para entonces la pista está ocupada, hace motor y al aire.
func clear_landing(plane_id: int, runway: int) -> bool:
	var p := _find(plane_id)
	if p.is_empty() or p["state"] != "approach" or runway < 0 or runway >= runways.size():
		return false
	p["state"] = "final"
	p["runway"] = runway
	p["timer"] = FINAL_TIME
	return true


## Push-back y rodaje hasta el punto de espera. Libera la puerta.
func push_back(plane_id: int) -> bool:
	var p := _find(plane_id)
	if p.is_empty() or p["state"] != "gate":
		return false
	p["state"] = "taxi_out"
	p["timer"] = PUSHBACK_TIME + taxi_time()
	return true


## Entrar y esperar: el avión ocupa la pista hasta que se le autorice el despegue.
func line_up(plane_id: int, runway: int) -> bool:
	var p := _find(plane_id)
	if p.is_empty() or p["state"] != "holding" or runway < 0 or runway >= runways.size():
		return false
	if not runway_clear(runway):
		return false
	p["state"] = "lined_up"
	p["runway"] = runway
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
	r["op_left"] = takeoff_time()
	p["state"] = "takeoff"
	return true


# --- Acciones del jugador: entre turnos -----------------------------------

func start_shift() -> void:
	phase = Phase.SHIFT
	planes.clear()
	turnarounds.clear()
	runways.clear()
	for i in runway_count():
		runways.append({"op": {}, "op_left": 0.0, "lined": {}, "prev_wake": -1, "since": 0.0})
	planes_total = planes_per_day()
	planes_spawned = 0
	_spawn_interval = clamp(24.0 / planes_total, 1.5, 6.0)
	_spawn_timer = 0.5
	shift_elapsed = 0.0
	shift_length = _spawn_interval * planes_total + 25.0
	day_pay = 0.0
	day_fines = 0.0
	day_landed = 0
	day_departed = 0
	day_diverted = 0
	day_go_arounds = 0
	day_infractions = 0
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
		"go_arounds": day_go_arounds, "infractions": day_infractions,
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
	_update_runways(delta)
	_update_planes(delta)
	_update_turnarounds(delta)
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


func _update_runways(delta: float) -> void:
	for r in runways:
		r["since"] += delta
		if r["op"].is_empty():
			continue
		r["op_left"] -= delta
		if r["op_left"] > 0.0:
			continue
		var p: Dictionary = r["op"]
		r["op"] = {}
		r["prev_wake"] = p["wake"]
		r["since"] = 0.0
		if p["arrival"]:
			p["state"] = "taxi_in"
			p["timer"] = taxi_time()
		else:
			_pay(p)
			day_departed += 1
			planes.erase(p)


func _update_planes(delta: float) -> void:
	for p in planes.duplicate():
		p["wait"] += delta
		match p["state"]:
			"approach":
				p["fuel"] -= delta
				if p["fuel"] <= 0.0:
					_divert(p)
			"final":
				p["fuel"] -= delta
				p["timer"] -= delta
				if p["timer"] <= 0.0:
					_touchdown(p)
			"taxi_in":
				p["timer"] -= delta
				if p["timer"] <= 0.0:
					p["state"] = "wait_gate"
			"taxi_out":
				p["timer"] -= delta
				if p["timer"] <= 0.0:
					p["state"] = "holding"
		if p["state"] == "wait_gate" and gates_used() < gate_count():
			_pay(p)
			day_landed += 1
			turnarounds.append(TURNAROUND_TIME)
			planes.erase(p)
			if p["emergency"] and event_id == "emergency":
				_end_event(true, plane_value(p) * 3.0)


func _touchdown(p: Dictionary) -> void:
	var runway: int = p["runway"]
	var r: Dictionary = runways[runway]
	if not runway_clear(runway):
		# Pista ocupada: motor y al aire, vuelve a la aproximación con menos combustible.
		p["state"] = "approach"
		p["runway"] = -1
		p["fuel"] -= GO_AROUND_FUEL
		day_go_arounds += 1
		day_fines += plane_value(p) * 0.25
		if event_id == "storm":
			event_success = false
		toast.emit("%s: motor y al aire, la pista %d estaba ocupada." % [p["callsign"], runway + 1])
		return
	if separation_left(runway, p["wake"]) > 0.0:
		_infraction(p, "aterrizó sin separación por estela")
	p["state"] = "landing"
	r["op"] = p
	r["op_left"] = landing_time()


func _infraction(p: Dictionary, what: String) -> void:
	day_infractions += 1
	day_fines += plane_value(p) * 0.5
	toast.emit("Infracción: %s %s. Multa de %s $." % [p["callsign"], what, format_number(plane_value(p) * 0.5)])


func _divert(p: Dictionary) -> void:
	planes.erase(p)
	if p["emergency"]:
		if event_id == "emergency":
			_end_event(false, 0.0)
		return
	day_diverted += 1
	if event_id == "storm":
		event_success = false
	toast.emit("%s se desvió por falta de combustible." % p["callsign"])


## Paga un avión; las salidas pierden un 10 % por cada 10 s de espera por encima de 30 s.
func _pay(p: Dictionary) -> void:
	var pay := plane_value(p)
	var late: float = max(0.0, p["wait"] - (60.0 if p["arrival"] else 30.0))
	pay *= max(0.3, 1.0 - 0.1 * floor(late / 10.0))
	day_pay += pay


func _update_turnarounds(delta: float) -> void:
	for i in range(turnarounds.size() - 1, -1, -1):
		turnarounds[i] -= delta
		if turnarounds[i] <= 0.0:
			turnarounds.remove_at(i)


func _spawn(delta: float) -> void:
	if planes_spawned >= planes_total:
		return
	_spawn_timer -= delta
	if _spawn_timer > 0.0:
		return
	# Las salidas nacen en una puerta: si no hay puerta libre, llega una llegada en su lugar.
	var is_arrival := rng.randf() < 0.5 or gates_used() >= gate_count()
	planes.append(_make_plane(is_arrival, false))
	planes_spawned += 1
	# Llegan en oleadas irregulares, como los bancos de un aeropuerto real.
	_spawn_timer = _spawn_interval * rng.randf_range(0.3, 1.7)
	if planes_spawned == planes_total:
		toast.emit("Último avión del día en camino.")


func _make_plane(is_arrival: bool, emergency: bool) -> Dictionary:
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
		"pax": PAX_BY_RADAR[tier],
		"wake": WAKE_BY_RADAR[tier],
		"state": "approach" if is_arrival else "gate",
		"timer": 0.0,
		"runway": -1,
		"fuel": 15.0 if emergency else rng.randf_range(20.0, 35.0),
		"wait": 0.0,
		"emergency": emergency,
	}
	_next_plane_id += 1
	return plane


## El controlador de tierra hace el push-back sin saturar el punto de espera.
func _ground_control() -> void:
	if levels["ground"] == 0:
		return
	var holding := planes.filter(func(p): return p["state"] in ["taxi_out", "holding"]).size()
	for p in planes:
		if holding >= runways.size() + 1:
			return
		if p["state"] == "gate":
			push_back(p["id"])
			holding += 1


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
			event_time = 25.0
			toast.emit("Tormenta: las pistas tardan un 50 % más durante 25 s. Sin desvíos ni motores y al aire, +50 % de pago hoy.")
		"emergency":
			planes.push_front(_make_plane(true, true))
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
		"version": 3,
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
	if typeof(data) != TYPE_DICTIONARY or int(data.get("version", 0)) != 3:
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
