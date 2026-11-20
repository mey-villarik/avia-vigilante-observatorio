# Vista Mapa: Bolivia por departamentos

Pestaña **Mapa** del menú del panel (`#mapa`). Muestra los 9 departamentos de Bolivia coloreados según lo que pesa
más en cada uno (oportunidades en oro, riesgos en rojo, mixto en violeta). Cuantas más señales tiene un
departamento, más intenso es el color.

Al tocar un departamento se abre a la derecha (debajo en el móvil) su resumen:

- cifras: señales, oportunidades, riesgos y eventos, con la proporción en una barra;
- lo más importante (las 3 señales de más prioridad y puntuación);
- eventos compuestos del departamento (se abren en la ventana de Eventos);
- oportunidades (con días para actuar) y riesgos;
- cambios en las noticias de las últimas 24 h;
- noticias más importantes, con fuente, fecha y si es oficial;
- destinos y temas que aparecen;
- señales que afectan a todo el país.

Sin departamento elegido se ve el resumen de Bolivia: totales, ranking de departamentos y señales nacionales.
Filtros: Todo / Oportunidades / Riesgos y periodo (recientes o todo lo guardado). El panel «Mapa por
departamento» del Panorama usa el mismo mapa y lleva a esta vista.

## De dónde salen los datos

No hace falta SQL nuevo: usa lo que el panel ya carga de Supabase (señales con sus territorios, fichas de
oportunidad, eventos compuestos y cambios). `web/src/lib/regiones.ts` traduce cada lugar a su departamento:
un departamento va a sí mismo, «Bolivia» o «nacional» van a todo el país, y un destino conocido (Uyuni,
Copacabana, Rurrenabaque…) va a su departamento. Lo que no se reconoce aparece en «Sin lugar reconocido».

## El dibujo

`web/src/data/mapaBolivia.ts` tiene los contornos de Natural Earth 1:10m (dominio público), simplificados sin
huecos entre departamentos, el lago Titicaca, las capitales y unos 25 destinos turísticos. Es SVG propio, sin
librerías nuevas (unos 18 KB). Para añadir destinos, sumar una línea a `DESTINOS_GEO` con su departamento y
coordenadas en el viewBox.
