extends SceneTree
## Simula partidas con bots para medir cuántos días aguanta cada tipo de jugador.
## Uso: godot --headless --path . -s tests/pacing_sim.gd
## Cada bot juega varias partidas con semillas distintas; se informa la media de días y dinero.

const GameScript := preload("res://scripts/game.gd")
const DT := 0.1
const MAX_DAYS := 40
const SEEDS := [1, 2, 3, 4, 5, 6, 7, 8]


func _init() -> void:
	# actions_per_s: órdenes por segundo que da el jugador; careful: respeta estela, meteo y viento.
	_run("experto (2 órdenes/s, cuidadoso)", 2.0, true)
	_run("normal (1 orden/s, cuidadoso)", 1.0, true)
	_run("lento (0,5 órdenes/s, cuidadoso)", 0.5, true)
	_run("descuidado (1 orden/s, ignora estela y meteo)", 1.0, false)
	_check_daily()
	quit()


func _run(label: String, actions_per_s: float, careful: bool) -> void:
	print("\n== %s ==" % label)
	var days_sum := 0.0
	var money_sum := 0.0
	var minutes_sum := 0.0
	var reasons := {}
	for s in SEEDS:
		var r := _play(s, actions_per_s, careful, s == SEEDS[0])
		days_sum += r["days"]
		money_sum += r["money"]
		minutes_sum += r["minutes"]
		reasons[r["reason"]] = reasons.get(r["reason"], 0) + 1
	var n := float(SEEDS.size())
	print("  media: %.1f días, %s $, %.1f min por partida" % [days_sum / n, GameScript.format_number(money_sum / n), minutes_sum / n])
	print("  fin de partida: %s" % [reasons])


func _play(seed: int, actions_per_s: float, careful: bool, verbose: bool) -> Dictionary:
	var g = GameScript.new()
	g.save_enabled = false
	g.new_run(false, seed)
	var real_time := 0.0
	var act_acc := 0.0
	while g.day <= MAX_DAYS and g.phase != g.Phase.GAMEOVER:
		var shift_time := 0.0
		while g.phase == g.Phase.SHIFT and not g.shift_done() and shift_time < 900.0:
			act_acc = min(act_acc + actions_per_s * DT, 3.0)
			while act_acc >= 1.0 and _act(g, careful):
				act_acc -= 1.0
			g.simulate(DT)
			shift_time += DT
		real_time += shift_time
		if g.phase == g.Phase.GAMEOVER:
			break
		if not g.end_day():
			print("  día %d no terminó (bloqueado)" % g.day)
			for p in g.planes:
				print("    %s %s pos %s alt %d ruta %s" % [p["callsign"], p["state"], p["pos"], p["alt"], p["path"]])
			break
		var s: Dictionary = g.last_summary
		if verbose and (g.day <= 5 or g.day % 5 == 0):
			print("  día %2d  %5.1f min  aviones %2d  desv %d  tcas %d  al aire %d  infr %d  cobro %s $  incidentes %d  %s" % [
				g.day, real_time / 60.0, s["landed"] + s["departed"], s["diverted"], s["tcas"], s["go_arounds"],
				s["infractions"], GameScript.format_number(s["total"]), g.strikes,
				g.levels.keys().filter(func(k): return g.levels[k] > 0)])
		g.open_draft()
		real_time += 10.0
		g.pick_card(_choose(g))
	var reason := "límite de días"
	if g.phase == g.Phase.GAMEOVER:
		reason = "tres incidentes" if g.fired_reason.begins_with("Tres") else "colisión"
	var result := {"days": g.day - 1, "money": g.money, "minutes": real_time / 60.0, "reason": reason}
	if verbose:
		print("  semilla %d: %d días, %s $ (%s: %s)" % [seed, result["days"], GameScript.format_number(g.money), reason, g.fired_reason])
	g.free()
	return result


## Elige carta como un jugador prudente: mejoras de capacidad primero, contratos si no hay otra.
func _choose(g) -> int:
	var prefs := ["union", "runway", "gates", "ground", "rapid_exit", "fuel_reserve", "taxiway", "meteo", "wake_monitor", "fees"]
	for want in prefs:
		var i: int = g.offer.find(want)
		if i >= 0:
			return i
	return 0


## El reto diario debe repartir el mismo tráfico a todos los que usan la misma semilla.
func _check_daily() -> void:
	var a = GameScript.new()
	var b = GameScript.new()
	a.save_enabled = false
	b.save_enabled = false
	a.new_run(true, 20261111)
	b.new_run(true, 20261111)
	var same: bool = str(a._spawn_queue) == str(b._spawn_queue) and str(a._events) == str(b._events)
	print("\nReto diario determinista: %s" % ("sí" if same else "NO"))
	a.free()
	b.free()


## Una orden de torre según prioridades de un controlador razonable. Devuelve si dio alguna.
func _act(g, careful: bool) -> bool:
	# 1. Despegar a quien esté alineado y con separación cumplida.
	for p in g.planes:
		if p["state"] == "lined_up" and (not careful or (g.separation_left(p["runway"], p["wake"]) <= 0.0 and not g.runway_stormy(p["runway"]))):
			if g.clear_takeoff(p["id"]):
				return true
	# 2. Entrantes: esperar a una altitud que no use ningún otro avión en vuelo.
	for p in g.planes:
		if p["state"] == "inbound":
			var used := []
			for q in g.planes:
				if q != p and g.is_airborne(q):
					used.append(int(q["target_alt"]))
			for alt in g.HOLD_ALTITUDES:
				if not alt in used:
					return g.hold_at(p["id"], alt)
	# 3. Autorizar aterrizaje a la llegada en espera con menos combustible, en una pista sin tráfico.
	var arrival := {}
	for p in g.planes:
		if p["state"] == "holding" and (arrival.is_empty() or p["fuel"] < arrival["fuel"]):
			arrival = p
	var wind_soon: bool = g.wind_change_in >= 0.0 and g.wind_change_in < 12.0
	if not arrival.is_empty() and not (careful and wind_soon):
		for i in g.runways.size():
			if careful and g.runway_stormy(i):
				continue
			if g.runway_clear(i) and g.approaches_on(i).is_empty():
				return g.clear_landing(arrival["id"], i)
	# 4. Alinear salidas en pistas sin aproximaciones cercanas.
	for p in g.planes:
		if p["state"] == "hold_point":
			for i in g.runways.size():
				if g.runway_clear(i) and g.approaches_on(i).filter(func(a): return g.time_to_touchdown(a) < 12.0).is_empty():
					return g.line_up(p["id"], i)
	# 5. Push-back si el punto de espera no está saturado.
	var queued := 0
	for p in g.planes:
		if p["state"] in ["pushback", "hold_point"]:
			queued += 1
	if queued <= g.runways.size():
		for p in g.planes:
			if p["state"] == "gate":
				return g.push_back(p["id"])
	return false
