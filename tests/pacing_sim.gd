extends SceneTree
## Simula partidas con bots para medir el ritmo y la dificultad por días.
## Uso: godot --headless --path . -s tests/pacing_sim.gd

const GameScript := preload("res://scripts/game.gd")
const DT := 0.1
const MAX_DAYS := 120
## Segundos que se estima que un jugador pasa en cobro y tienda cada día.
const MENU_SECONDS := 8.0


func _init() -> void:
	# actions_per_s: órdenes por segundo que da el jugador; careful: respeta la estela o no.
	_run("experto (2 órdenes/s, respeta estela)", 2.0, true)
	_run("normal (1 orden/s, respeta estela)", 1.0, true)
	_run("lento (0,4 órdenes/s, respeta estela)", 0.4, true)
	_run("descuidado (1 orden/s, ignora estela)", 1.0, false)
	quit()


func _run(label: String, actions_per_s: float, careful: bool) -> void:
	var g = GameScript.new()
	g.save_enabled = false
	g.rng.seed = 42
	g.new_game()
	var real_time := 0.0
	var act_acc := 0.0
	var totals := {"diverted": 0, "go_arounds": 0, "infractions": 0, "crashes": 0}
	print("\n== %s ==" % label)
	while g.day <= MAX_DAYS:
		var shift_time := 0.0
		while not g.shift_done() and shift_time < 900.0:
			act_acc = min(act_acc + actions_per_s * DT, 3.0)
			while act_acc >= 1.0 and _act(g, careful):
				act_acc -= 1.0
			g.simulate(DT)
			shift_time += DT
		real_time += shift_time
		if not g.end_day():
			print("  día %d no terminó (bloqueado)" % g.day)
			for p in g.planes:
				print("    %s %s pos %s alt %d ruta %s" % [p["callsign"], p["state"], p["pos"], p["alt"], p["path"]])
			break
		var s: Dictionary = g.last_summary
		for k in totals:
			totals[k] += s[k]
		g.collect_pay()
		real_time += MENU_SECONDS
		var bought := []
		while true:
			var id := _cheapest(g)
			if id == "" or not g.buy(id):
				break
			bought.append(id)
		if g.day <= 5 or g.day % 10 == 0:
			print("  día %3d  %5.1f min  turno %3ds  aviones %2d  desv %d  al aire %d  infr %d  cobro %s $  %s" % [
				g.day, real_time / 60.0, shift_time, s["landed"] + s["departed"], s["diverted"], s["go_arounds"],
				s["infractions"], GameScript.format_number(s["total"]), bought])
		if g.can_prestige():
			print("  >> prestigio disponible el día %d (%.1f min)" % [g.day, real_time / 60.0])
			break
		g.next_day()
	print("  totales: %s" % [totals])
	print("  niveles: %s" % [g.levels])
	g.free()


## Una orden de torre según prioridades de un controlador razonable. Devuelve si dio alguna.
func _act(g, careful: bool) -> bool:
	# 1. Despegar a quien esté alineado y con separación cumplida.
	for p in g.planes:
		if p["state"] == "lined_up" and (not careful or g.separation_left(p["runway"], p["wake"]) <= 0.0):
			return g.clear_takeoff(p["id"])
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
		if p["state"] == "holding" and (p["emergency"] or arrival.is_empty() or p["fuel"] < arrival["fuel"]):
			arrival = p
			if p["emergency"]:
				break
	if not arrival.is_empty():
		for i in g.runways.size():
			if g.runways[i]["lined"].is_empty() and g.approaches_on(i).is_empty() and g.runways[i]["op"].is_empty():
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


func _cheapest(g) -> String:
	var best := ""
	for id in g.UPGRADES:
		if g.can_buy(id) and (best == "" or g.upgrade_cost(id) < g.upgrade_cost(best)):
			best = id
	return best
