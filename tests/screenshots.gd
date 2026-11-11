extends SceneTree
## Genera las capturas de docs/capturas recorriendo todas las pantallas con estados forzados.
## Uso (necesita pantalla o Xvfb): xvfb-run godot --path . --rendering-driver opengl3 -s tests/screenshots.gd
var _main: Node
var _step := 0
var _wait := 0

func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)

func _shot(name: String) -> void:
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("res://docs/capturas/%s.png" % name)
	print("shot ", name)

func _process(_d: float) -> bool:
	var g = root.get_node("Game")
	_wait += 1
	if _wait < 8:
		return false
	_wait = 0
	match _step:
		0:
			g.save_enabled = false
			_shot("menu")
			g.new_run(false, 7)
			g.day = 7
			g.levels["meteo"] = 1
			g.levels["wake_monitor"] = 1
			g.levels["vip"] = 1
			g.levels["cargo"] = 1
			g.levels["runway"] = 1
			g.start_shift()
			g._wind_at = 70.0
			g._events.append({"t": 1.0, "kind": "medical"})
			g._events.append({"t": 2.0, "kind": "storm"})
			g._events.sort_custom(func(a, b): return a["t"] < b["t"])
			for i in 400:
				g.simulate(0.1)
				for p in g.planes:
					if p["state"] == "inbound":
						g.hold_at(p["id"], [3000,4000,5000,6000,7000][p["id"] % 5])
					if p["state"] == "gate":
						g.push_back(p["id"])
				if i % 40 == 0:
					for p in g.planes:
						if p["state"] == "holding" and g.approaches_on(0).is_empty():
							g.clear_landing(p["id"], 0)
							break
			if not g.planes.is_empty():
				_main._radar.selected_id = g.planes[0]["id"]
		1:
			_shot("turno")
			var air = g.planes.filter(func(p): return p["state"] == "holding")
			if air.size() >= 2:
				air[1]["hold_center"] = air[0]["hold_center"]
				air[1]["hold_angle"] = air[0]["hold_angle"] + 0.7
				air[1]["alt"] = air[0]["alt"]
				air[1]["target_alt"] = air[0]["alt"]
			g.simulate(0.1)
		2:
			_shot("tcas")
			for i in 40:
				g.simulate(0.1)
			g.planes.clear()
			g._spawn_queue.clear()
			g.planes_spawned = g.planes_total
			g.shift_elapsed = g.SHIFT_SECONDS
			g.end_day()
		3:
			_shot("resumen")
			g.open_draft()
		4:
			_shot("cartas")
			g.pick_card(0)
			g.strikes = 2
			for i in 300:
				g.simulate(0.1)
				for p in g.planes:
					if p["state"] == "inbound":
						g.hold_at(p["id"], 4000)
			var air = g.planes.filter(func(p): return p["state"] == "holding")
			if air.size() >= 2:
				air[1]["hold_center"] = air[0]["hold_center"] + Vector2(70, 0)
				air[1]["hold_angle"] = air[0]["hold_angle"] + PI
				air[1]["alt"] = air[0]["alt"]
				air[1]["target_alt"] = air[0]["alt"]
			else:
				g._add_strike("ATR desviado sin combustible")
			for i in 60:
				g.simulate(0.1)
				if g.phase != g.Phase.SHIFT:
					break
		5:
			_shot("despido")
			quit(0)
	_step += 1
	return false
