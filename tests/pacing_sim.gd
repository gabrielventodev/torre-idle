extends SceneTree
## Simula partidas con bots para medir el ritmo de la economía por días.
## Uso: godot --headless --path . -s tests/pacing_sim.gd

const GameScript := preload("res://scripts/game.gd")
const DT := 0.1
const MAX_DAYS := 300
## Segundos que se estima que un jugador pasa en cobro y tienda cada día.
const MENU_SECONDS := 8.0


func _init() -> void:
	_run("activo (1 clic/s)", 1.0)
	_run("rápido (2 clics/s)", 2.0)
	quit()


func _run(label: String, clicks_per_s: float) -> void:
	var g = GameScript.new()
	g.save_enabled = false
	g.rng.seed = 42
	g.new_game()
	var real_time := 0.0
	var click_acc := 0.0
	var prestiges := 0
	print("\n== %s ==" % label)
	while g.day <= MAX_DAYS:
		# Turno.
		while not g.shift_done():
			click_acc += clicks_per_s * DT
			while click_acc >= 1.0:
				click_acc -= 1.0
				_click(g)
			if g.event_id == "vip":
				g.reserve_vip()
			g.simulate(DT)
			real_time += DT
		g.end_day()
		var s: Dictionary = g.last_summary
		g.collect_pay()
		real_time += MENU_SECONDS
		var bought := []
		while true:
			var id := _cheapest(g)
			if id == "" or not g.buy(id):
				break
			bought.append(id)
		if g.day <= 5 or g.day % 10 == 0:
			print("  día %3d  %5.1f min  aviones %2d  desvíos %d  cobro %s $  compras %s" % [
				g.day, real_time / 60.0, s["landed"], s["diverted"], GameScript.format_number(s["total"]), bought])
		if g.can_prestige():
			prestiges += 1
			print("  >> prestigio %d disponible el día %d (%.1f min)" % [prestiges, g.day, real_time / 60.0])
			if prestiges == 2:
				break
			g.prestige()
			for t in g.XP_TREE:
				g.buy_tree(t)
			real_time = 0.0
			print("  -- %s --" % g.AIRPORTS[g.airport_level])
			continue
		g.next_day()
	print("  niveles: %s" % [g.levels])
	g.free()


## Clic manual: emergencias primero, luego la llegada con menos combustible, luego salidas.
func _click(g) -> void:
	var target := {}
	for p in g.arrivals:
		if p["emergency"] or target.is_empty() or p["fuel"] < target["fuel"]:
			target = p
			if p["emergency"]:
				break
	if target.is_empty() and not g.departures.is_empty():
		target = g.departures[0]
	if not target.is_empty():
		g.approve(target["id"])


func _cheapest(g) -> String:
	var best := ""
	for id in g.UPGRADES:
		if g.can_buy(id) and (best == "" or g.upgrade_cost(id) < g.upgrade_cost(best)):
			best = id
	return best
