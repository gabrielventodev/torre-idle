# Torre de control idle (prototipo)

Prototipo del MVP descrito en el documento de diseño. Godot 4.4, GDScript y renderer Compatibility, para que exporte a web.

## Abrirlo

1. Instala [Godot 4.4](https://godotengine.org/download), la versión estándar (no hace falta la de .NET).
2. En el gestor de proyectos: **Importar**, elige `project.godot` de esta carpeta.
3. Pulsa F5 para jugar.

## Cómo se juega

Cada día es un turno de 9:00 a 18:00 en el que llegan los aviones pedidos: 2 al principio y más con la mejora **Más tráfico**. Cada avión pasa por fases, como en una torre real, y cada fase pide una orden tuya:

| Avión | Fases | Tus órdenes |
| --- | --- | --- |
| Llegada | aproximación → final → aterrizaje → rodaje → puerta | **Aterrizar Pn** |
| Salida | puerta → push-back y rodaje → punto de espera → alineado → despegue | **Push-back**, **Entrar Pn**, **Despegar** |

Reglas:
- **Una pista, una operación.** Un avión autorizado a aterrizar toca tierra 6 s después. Si en ese momento la pista está ocupada (otro avión rodando o alineado), hace **motor y al aire**: vuelve a la aproximación con 10 s menos de combustible y te multan.
- **Separación por estela.** Tras un avión pesado (H) hay que esperar 6 s antes de un ligero (L), 4 s antes de un medio (M) y 3 s antes de otro pesado. Tras un medio, 3 s antes de un ligero. Si no la respetas, el avión opera igual pero te multan.
- **Puertas limitadas.** Una llegada necesita puerta libre al terminar el rodaje y la ocupa 8 s de escala. Las salidas nacen en puerta: hay que sacarlas para hacer sitio.
- **Combustible.** Si una llegada se queda sin combustible en aproximación, se desvía y no cobras.
- Cuando la torre avisa de que no vienen más aviones, pulsa **Terminar el día**, luego **Cobrar** (pago menos multas) y compra mejoras en la tienda.
- La automatización solo cubre tierra: el **Controlador de tierra** hace los push-back. Aterrizajes y despegues siempre son tuyos.
- Las crisis (tormenta y emergencia médica) aparecen en algunos turnos y dan una bonificación en el cobro.
- El juego se guarda al cobrar y al empezar cada día. Un turno a medias se reinicia.

## Estructura

| Archivo | Qué hace |
| --- | --- |
| `scripts/game.gd` | Autoload `Game`: fases de cada avión, pistas, estela, puertas, cobro, tienda, eventos, guardado. Sin UI. |
| `scripts/main.gd` | Interfaz construida por código: pantallas de turno, cobro y tienda. |
| `tests/pacing_sim.gd` | Bots que juegan solos para medir el ritmo de la economía. |

Todos los números de balance están en las constantes al principio de `game.gd`.

## Medir el ritmo tras cambiar números

```
godot --headless --path . -s tests/pacing_sim.gd
```

Resultado actual: los bots que respetan la estela llegan al primer prestigio el día 28 (25-31 min según su ritmo de órdenes). Un bot que ignora la estela acumula 56 infracciones hasta el día 30. Los bots planifican sin errores, así que un jugador real sufrirá más motores y al aire.

## Exportar a web (itch.io)

Proyecto, Exportar, Añadir, Web. Descarga las plantillas de exportación si te las pide. Sube el `.zip` a itch.io como juego HTML5.
