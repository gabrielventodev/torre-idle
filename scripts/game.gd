extends Node
## Estado y simulación del juego. No contiene UI: la escena principal lo lee y llama a sus acciones.
## Se registra como autoload "Game". Los tests lo instancian con .new() y llaman a new_game().
##
## Bucle: turno de 9 a 18 (se coordinan los aviones pedidos ese día) -> cobro -> tienda -> siguiente día.

signal toast(text: String)

enum Phase { SHIFT, PAYDAY, SHOP }

const SAVE_PATH := "user://save.json"
## Pago por avión coordinado (aterrizaje o despegue) según el nivel de radar.
const PAY_BY_RADAR := [100, 250, 600, 1500]
const PAX_BY_RADAR := [10, 50, 180, 400]
const MODEL_BY_RADAR := ["Cessna 208", "ATR 72", "A320", "B787"]
const AIRLINES := ["IB", "VY", "UX", "AA", "LH", "AF", "KL", "LA", "AV", "AM"]
const BASE_PLANES_PER_DAY := 2
const BASE_OCCUPANCY := 2.5
const MAX_QUEUE := 8
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
	"taxiway": {"name": "Calles de rodaje", "base": 300.0, "growth": 1.5, "max": 10,
		"desc": "-10 % de tiempo de pista"},
	"runway": {"name": "Pista adicional", "base": 400.0, "growth": 5.0, "max": MAX_RUNWAYS - 1,
		"desc": "+1 operación simultánea"},
	"intern": {"name": "Becario de torre", "base": 500.0, "growth": 1.5, "max": 8,
		"desc": "Aprueba 1 avión cada 5 s"},
	"radar": {"name": "Radar", "base": 800.0, "growth": 6.0, "max": 3,
		"desc": "Aviones más grandes que pagan más"},
	"controller": {"name": "Controlador", "base": 3000.0, "growth": 1.5, "max": -1,
		"desc": "Aprueba 1 avión cada 2 s, prioriza poco combustible"},
}

const XP_TREE := {
	"start_controller": {"name": "Empezar con 1 controlador", "cost": 1},
	"extra_traffic": {"name": "+2 aviones por turno", "cost": 2},
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
var arrivals: Array = []
var departures: Array = []
var runways: Array = []
var planes_total := 0
var planes_spawned := 0
var shift_elapsed := 0.0
var shift_length := 0.0
var day_pay := 0.0
var day_landed := 0
var day_diverted := 0
var day_bonus := 0.0
var last_summary := {}
var _spawn_interval := 0.0
var _spawn_timer := 0.0
var _auto_acc := 0.0
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
	if tree_owned.get("start_controller", false):
		levels["controller"] = 1
	start_shift()


# --- Fórmulas -------------------------------------------------------------

func planes_per_day() -> int:
	var n: int = BASE_PLANES_PER_DAY + levels["traffic"]
	if tree_owned.get("extra_traffic", false):
		n += 2
	return n


func runway_count() -> int:
	return 1 + levels["runway"]


func occupancy() -> float:
	var t: float = max(1.0, BASE_OCCUPANCY * pow(0.9, levels["taxiway"]))
	if event_id == "storm":
		t *= 2.0
	return t


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


func auto_rate() -> float:
	var interns: float = 0.2 * levels["intern"]
	var controllers: float = 0.5 * levels["controller"] * milestone_mult("controller")
	return interns + controllers


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


## El turno termina cuando no quedan aviones por llegar, en cola ni en pista.
func shift_done() -> bool:
	if phase != Phase.SHIFT or planes_spawned < planes_total or event_id != "":
		return false
	if not arrivals.is_empty() or not departures.is_empty():
		return false
	for r in runways:
		if r["time_left"] > 0.0:
			return false
	return true


# --- Acciones del jugador --------------------------------------------------

func start_shift() -> void:
	phase = Phase.SHIFT
	arrivals.clear()
	departures.clear()
	runways.clear()
	for i in runway_count():
		runways.append({"time_left": 0.0, "plane": {}, "vip": false})
	planes_total = planes_per_day()
	planes_spawned = 0
	# El día dura más con más aviones, pero siempre llegan seguidos para no esperar en vacío.
	_spawn_interval = clamp(20.0 / planes_total, 0.8, 5.0)
	_spawn_timer = 0.5
	shift_elapsed = 0.0
	shift_length = _spawn_interval * planes_total + 8.0
	day_pay = 0.0
	day_landed = 0
	day_diverted = 0
	day_bonus = 0.0
	_auto_acc = 0.0
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
		"day": day, "landed": day_landed, "diverted": day_diverted,
		"pay": day_pay, "bonus": day_bonus, "total": day_pay + day_bonus,
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


## Aprobación manual de un avión de cualquiera de las dos colas.
func approve(plane_id: int) -> bool:
	var runway := _free_runway()
	if runway < 0:
		return false
	for queue in [arrivals, departures]:
		for plane in queue:
			if plane["id"] == plane_id:
				queue.erase(plane)
				_assign(plane, runway)
				if plane["emergency"] and event_id == "emergency":
					_end_event(true, plane_value(plane) * 3.0)
				return true
	return false


## Evento VIP: reserva una pista libre durante 10 s.
func reserve_vip() -> bool:
	if event_id != "vip" or _any_vip_runway():
		return false
	var runway := _free_runway()
	if runway < 0:
		return false
	runways[runway] = {"time_left": 10.0, "plane": {}, "vip": true}
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
	_update_queues(delta)
	_spawn(delta)
	_automate(delta)
	_update_event(delta)
	if not _done_announced and shift_done():
		_done_announced = true
		toast.emit("Torre: no vienen más aviones hoy. Puedes terminar el día.")


func _free_runway() -> int:
	for i in runways.size():
		if runways[i]["time_left"] <= 0.0:
			return i
	return -1


func _any_vip_runway() -> bool:
	for r in runways:
		if r["vip"]:
			return true
	return false


func _assign(plane: Dictionary, runway: int) -> void:
	runways[runway] = {"time_left": occupancy(), "plane": plane, "vip": false}


func _update_runways(delta: float) -> void:
	for r in runways:
		if r["time_left"] <= 0.0:
			continue
		r["time_left"] -= delta
		if r["time_left"] > 0.0:
			continue
		r["time_left"] = 0.0
		if r["vip"]:
			r["vip"] = false
			if event_id == "vip":
				_end_event(true, PAY_BY_RADAR[levels["radar"]] * pay_mult() * 5.0)
		elif not r["plane"].is_empty():
			_complete(r["plane"])
			r["plane"] = {}


## El pago se acumula y se cobra al terminar el día.
func _complete(plane: Dictionary) -> void:
	var pay: float = plane_value(plane)
	if not plane["arrival"]:
		pay *= max(0.2, 1.0 - 0.1 * floor(plane["wait"] / 10.0))
	day_pay += pay
	day_landed += 1


func _update_queues(delta: float) -> void:
	for plane in departures:
		plane["wait"] += delta
	for plane in arrivals.duplicate():
		plane["wait"] += delta
		plane["fuel"] -= delta
		if plane["fuel"] > 0.0:
			continue
		arrivals.erase(plane)
		if plane["emergency"]:
			if event_id == "emergency":
				_end_event(false, 0.0)
			continue
		day_diverted += 1
		if event_id == "storm":
			event_success = false
		toast.emit("%s se desvió por falta de combustible." % plane["callsign"])


func _spawn(delta: float) -> void:
	if planes_spawned >= planes_total:
		return
	_spawn_timer -= delta
	if _spawn_timer > 0.0:
		return
	var is_arrival := rng.randf() < 0.5
	var queue := arrivals if is_arrival else departures
	if queue.size() >= MAX_QUEUE:
		queue = departures if is_arrival else arrivals
		is_arrival = not is_arrival
	if queue.size() >= MAX_QUEUE:
		_spawn_timer = 0.5
		return
	queue.append(_make_plane(is_arrival, false))
	planes_spawned += 1
	_spawn_timer = _spawn_interval
	if planes_spawned == planes_total:
		toast.emit("Último avión del día en camino.")


func _make_plane(is_arrival: bool, emergency: bool) -> Dictionary:
	# Con más radar, la mayoría de aviones son del tamaño máximo desbloqueado.
	var tier: int = levels["radar"]
	if tier > 0 and rng.randf() < 0.35:
		tier -= 1
	var plane := {
		"id": _next_plane_id,
		"callsign": "%s%d" % [AIRLINES[rng.randi() % AIRLINES.size()], rng.randi_range(100, 9999)],
		"arrival": is_arrival,
		"tier": tier,
		"pax": PAX_BY_RADAR[tier],
		"model": MODEL_BY_RADAR[tier],
		"fuel": 10.0 if emergency else rng.randf_range(18.0, 35.0),
		"wait": 0.0,
		"emergency": emergency,
	}
	_next_plane_id += 1
	return plane


func _automate(delta: float) -> void:
	_auto_acc += auto_rate() * delta
	while _auto_acc >= 1.0:
		var runway := _free_runway()
		var plane := _pick_for_auto()
		if runway < 0 or plane.is_empty():
			# No se acumulan aprobaciones mientras no hay pista o avión.
			_auto_acc = min(_auto_acc, 1.0)
			return
		_auto_acc -= 1.0
		(arrivals if plane["arrival"] else departures).erase(plane)
		_assign(plane, runway)


## La automatización nunca atiende emergencias: son decisión del jugador.
func _pick_for_auto() -> Dictionary:
	var best := {}
	if levels["controller"] > 0:
		for plane in arrivals:
			if not plane["emergency"] and plane["fuel"] < 15.0 and (best.is_empty() or plane["fuel"] < best["fuel"]):
				best = plane
		if not best.is_empty():
			return best
	for plane in arrivals + departures:
		if not plane["emergency"] and (best.is_empty() or plane["wait"] > best["wait"]):
			best = plane
	return best


# --- Eventos de crisis -----------------------------------------------------

func _update_event(delta: float) -> void:
	if event_id == "":
		if _event_at >= 0.0 and shift_elapsed >= _event_at:
			_event_at = -1.0
			_start_event(["storm", "emergency", "vip"][rng.randi() % 3])
		return
	event_time -= delta
	if event_time <= 0.0 and event_id != "emergency":
		# La tormenta se gana sobreviviéndola sin desvíos; el VIP caduca si no se atiende.
		if event_id == "storm" and event_success:
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
			event_time = 20.0
			toast.emit("Tormenta: las pistas rinden la mitad 20 s. Sin desvíos, +50 % de pago hoy.")
		"emergency":
			event_time = 10.0
			arrivals.push_front(_make_plane(true, true))
			toast.emit("Emergencia médica: aprueba el avión marcado en menos de 10 s.")
		"vip":
			event_time = 20.0
			toast.emit("Vuelo VIP: reserva una pista durante 10 s para cobrar un extra.")


func _end_event(success: bool, bonus: float) -> void:
	var id := event_id
	event_id = ""
	if not success:
		toast.emit("La crisis pasó sin bonificación.")
		return
	day_bonus += bonus
	match id:
		"emergency":
			toast.emit("Emergencia resuelta: bonificación de %s $." % format_number(bonus))
		"vip":
			toast.emit("Vuelo VIP atendido: bonificación de %s $." % format_number(bonus))


# --- Guardado ---------------------------------------------------------------

## Se guarda entre turnos; un turno a medias se reinicia al volver.
func to_dict() -> Dictionary:
	return {
		"version": 2,
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
	if typeof(data) != TYPE_DICTIONARY or int(data.get("version", 0)) != 2:
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
