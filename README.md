# Torre de control idle (prototipo)

Prototipo del MVP descrito en el documento de diseño. Godot 4.4, GDScript y renderer Compatibility, para que exporte a web.

## Abrirlo

1. Instala [Godot 4.4](https://godotengine.org/download), la versión estándar (no hace falta la de .NET).
2. En el gestor de proyectos: **Importar**, elige `project.godot` de esta carpeta.
3. Pulsa F5 para jugar.

## Cómo se juega

El turno se juega sobre un **tablero del aeropuerto visto desde arriba**: pistas, calles de rodaje, terminal con puertas y aviones que se mueven de verdad por el mapa (sin saltos). La etiqueta de cada avión muestra indicativo y altitud en cientos de pies (`040` = 4000 ft). Haz clic en un avión (en el mapa o en la lista de tráfico) para ver pasajeros, combustible y fase, y darle órdenes por radio; el piloto colaciona cada orden.

Cada día es un turno de 9:00 a 18:00 en el que llegan los aviones pedidos: 2 al principio y más con la mejora **Más tráfico**.

| Avión | Recorrido | Tus órdenes |
| --- | --- | --- |
| Llegada | entra por el borde → espera en circuito → tramo base → final → toma → rodaje → puerta | **Mantener 3000-7000 ft**, **Aterrizar Pn** |
| Salida | puerta → push-back → rodaje al punto de espera → alineado → despegue → sale del mapa | **Push-back**, **Entrar Pn**, **Despegar** |

Reglas:
- **Altitud de espera.** Al ordenar "mantenga X pies", el avión cambia de nivel y da vueltas en el sitio donde estaba. Varios aviones pueden esperar en el mismo punto a distinta altitud. Si dejas dos a la misma altitud y se cruzan (menos de 400 ft de diferencia), **chocan y pierdes todo el dinero**. Un anillo rojo avisa antes de que pase.
- **Aproximación continua.** Al autorizar el aterrizaje, el avión vuela un tramo base, se alinea con la pista y desciende por la senda. Si al tocar la pista está ocupada, hace **motor y al aire** a 2500 ft y te multan.
- **Separación por estela.** Tras un pesado (H) hay que esperar más antes de un ligero o medio. Si no la respetas, te multan.
- **Puertas limitadas.** Una llegada necesita puerta libre y la ocupa 8 s de escala. Las salidas nacen en puerta.
- **Combustible.** Si una llegada se queda sin combustible, se desvía y no cobras.
- Cuando la torre avisa de que no vienen más aviones, pulsa **Terminar el día**, luego **Cobrar** y compra mejoras.
- La automatización solo cubre tierra (push-back). Aterrizajes, altitudes y despegues siempre son tuyos.
- El juego se guarda al cobrar y al empezar cada día. Un turno a medias se reinicia.

## Fondo del mapa

El tablero se dibuja por código. Si existe `assets/mapa.png` (1600×1000, mismo encuadre que el mundo del juego), se usa como fondo: ahí va la futura textura satelital.

## Estructura

| Archivo | Qué hace |
| --- | --- |
| `scripts/game.gd` | Autoload `Game`: simulación espacial (posición, rumbo, altitud), pistas, estela, puertas, colisiones, cobro, tienda, guardado. Sin UI. |
| `scripts/main.gd` | Interfaz construida por código: turno (mapa + panel de radio), cobro y tienda. |
| `scripts/map_view.gd` | Dibuja el tablero: suelo, pistas, rodaje, terminal, rutas, aviones con sombra según altitud y estelas. |
| `tests/pacing_sim.gd` | Bots que juegan solos para medir el ritmo de la economía. |

Todos los números de balance están en las constantes al principio de `game.gd`.

## Medir el ritmo tras cambiar números

```
godot --headless --path . -s tests/pacing_sim.gd
```

Resultado actual: los bots llegan al primer prestigio hacia el día 32 (~60 min). Los bots asignan altitudes únicas y nunca se equivocan, así que un jugador real chocará y hará más motores y al aire.

## Exportar a web (itch.io)

Proyecto, Exportar, Añadir, Web. Descarga las plantillas de exportación si te las pide. Sube el `.zip` a itch.io como juego HTML5.
