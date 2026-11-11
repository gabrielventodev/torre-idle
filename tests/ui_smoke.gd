extends SceneTree
## Prueba de humo de la interfaz: monta la escena principal y recorre todas las pantallas
## forzando tormenta, emergencias, cambio de viento, aviso TCAS y despido.
## Uso: godot --headless --path . -s tests/ui_smoke.gd

var _main: Node
var _step := 0
var _frames := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	var g = root.get_node("Game")
	_frames += 1
	match _step:
		0:
			g.save_enabled = false
			g.new_run(true)
			g.day = 6
			g.levels["meteo"] = 1
			g.levels["wake_monitor"] = 1
			g.levels["vip"] = 1
			g.levels["cargo"] = 1
			g.start_shift()
			g._spawn_storm()
			g._wind_at = 5.0
			g._events.append({"t": 0.5, "kind": "medical"})
			g._events.append({"t": 0.6, "kind": "engine"})
			_step = 1
		1:
			for i in 20:
				g.simulate(0.1)
			if g.wind_dir == -1 and g.planes.size() >= 3:
				# Fuerza un TCAS poniendo dos aviones en vuelo en el mismo sitio y altitud.
				var air = g.planes.filter(func(p): return g.is_airborne(p))
				if air.size() >= 2:
					air[1]["pos"] = air[0]["pos"] + Vector2(30, 0)
					air[1]["alt"] = air[0]["alt"]
					_step = 2
			if _frames > 600:
				print("FALLO: no hubo cambio de viento o tráfico")
				quit(1)
		2:
			for i in 40:
				g.simulate(0.1)
			print("tcas=%d strikes=%d replays=%d storms=%d wind=%s" % [g.day_tcas, g.strikes, g.replays.size(), g.storms.size(), g.runway_name()])
			# Vacía el turno y pasa por resumen y cartas.
			g.planes.clear()
			g._spawn_queue.clear()
			g.planes_spawned = g.planes_total
			g.shift_elapsed = g.SHIFT_SECONDS
			g._fire_timer = -1.0
			if g.phase == g.Phase.SHIFT and g.end_day():
				_step = 3
			else:
				print("FALLO: no se pudo terminar el día, fase %d" % g.phase)
				quit(1)
		3:
			if _frames % 10 == 0:
				g.open_draft()
				print("cartas: %s" % [g.offer])
				_step = 4
		4:
			if _frames % 10 == 0:
				g.pick_card(0)
				g.strikes = 2
				_step = 5
		5:
			if _frames % 10 == 0:
				g._add_strike("prueba")
				_step = 6
		6:
			g.simulate(0.5)
			if g.phase == g.Phase.GAMEOVER:
				print("despedido: %s" % g.fired_reason)
				_step = 7
		7:
			if _frames % 10 == 0:
				g.back_to_menu()
				_step = 8
		8:
			if _frames % 10 == 0:
				print("OK")
				quit(0)
	return false
