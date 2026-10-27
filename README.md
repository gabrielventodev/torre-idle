# Torre de control idle (prototipo)

Prototipo del MVP descrito en el documento de diseño. Godot 4.4, GDScript y renderer Compatibility, para que exporte a web.

## Abrirlo

1. Instala [Godot 4.4](https://godotengine.org/download), la versión estándar (no hace falta la de .NET).
2. En el gestor de proyectos: **Importar**, elige `project.godot` de esta carpeta.
3. Pulsa F5 para jugar.

## Cómo se juega

- Cada día es un turno de 9:00 a 18:00. Ese día llegan los aviones pedidos: 2 al principio, más con la mejora **Más tráfico**.
- Haz clic en una tira de **Llegadas** o **Salidas** para mandarla a una pista libre. Las llegadas pierden combustible y, si llega a 0, el avión se desvía y no cobras por él.
- Cuando la torre avisa de que no vienen más aviones, pulsa **Terminar el día**, luego **Cobrar** y compra mejoras en la tienda.
- Precios base: cada avión paga 100 $ (250, 600 y 1500 $ con el radar). Más tráfico cuesta 150 $ y sube un 35 % por nivel. El resto de precios está en `UPGRADES` en `game.gd`.
- Las crisis (tormenta, emergencia y VIP) aparecen en algunos turnos y dan una bonificación en el cobro.
- El prestigio te lleva al aeropuerto regional y da experiencia para el árbol.
- El juego se guarda al cobrar y al empezar cada día. Un turno a medias se reinicia.

## Estructura

| Archivo | Qué hace |
| --- | --- |
| `scripts/game.gd` | Autoload `Game`: turnos, cobro, tienda, fórmulas, eventos, guardado. Sin UI. |
| `scripts/main.gd` | Interfaz construida por código: pantallas de turno, cobro y tienda. |
| `tests/pacing_sim.gd` | Bots que juegan solos para medir el ritmo de la economía. |

Todos los números de balance están en las constantes al principio de `game.gd`.

## Medir el ritmo tras cambiar números

```
godot --headless --path . -s tests/pacing_sim.gd
```

Resultado actual con un bot que compra siempre la mejora más barata: primer prestigio el día 29 (unos 14 min) y el segundo, el día 21 del aeropuerto regional. Un jugador real será más lento que el bot.

## Exportar a web (itch.io)

Proyecto, Exportar, Añadir, Web. Descarga las plantillas de exportación si te las pide. Sube el `.zip` a itch.io como juego HTML5.
