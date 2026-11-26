# Más servicios esenciales y más turismo (SQL 58 y prompt 1.13)

2026-11-26. Pedido de Meysel: que el Vigilante detecte más cortes de luz, de agua y temas de salud, y más cosas de viajes, aerolíneas y eventos.

Hay dos puertas por las que pasa una noticia y las dos se amplían:

1. **Filtro previo sin IA** (base de datos): decide qué noticias llegan a la IA. → `db/generico/58_ampliar_servicios_turismo.sql`
2. **Clasificador** (IA, en el VPS): decide si la noticia es relevante y en qué categoría va. → `hermes/analizador/prompt_clasificador.md`, versión **clasificador-1.13**

Además, el 58 amplía `eje_de`, que reparte las señales en los ejes de la vista Dirección.

## Qué se añade

| | Servicios esenciales | Atención turística |
|---|---|---|
| Agua y luz | cortes programados, baja presión, agua turbia, mantenimiento de redes, EPSAS, SEMAPA, SAGUAPAC, ELAPAS, DELAPAZ, CRE, ELFEC… | |
| Salud | dengue, chikungunya, zika, fiebre amarilla, sarampión, influenza, covid, alerta epidemiológica, terapia intensiva, paro médico, SEDES, intoxicación, vacunación | |
| Otros | gas domiciliario, recojo de basura, cajeros, falta de dólares o efectivo, subida de pasajes | |
| Aerolíneas | vuelos cancelados, suspendidos o retrasados, pasajeros varados, huelga de pilotos, controladores, cierre de aeropuerto | BoA, EcoJet, Amaszonas, LATAM, Avianca, Copa…, pasajes y tarifas aéreas, frecuencias, vuelos directos, chárter |
| Eventos | | Gran Poder, Urkupiña, Alasitas, Carnaval de Oruro, Todos Santos, Año Nuevo Andino, Música Barroca, Expocruz, Feicobol, conciertos, peregrinaciones, rally, Dakar, maratones, juegos y campeonatos internacionales |
| Alojamiento y actividades | | resort, albergue, lodge, camping, Airbnb, tours, excursiones, trekking, turismo de aventura, comunitario, gastronómico, ruta del vino y del singani, teleférico, miradores, sitios arqueológicos, misiones jesuíticas, UNESCO, visas, terminales de buses |

Lo que ya estaba (55 y antes) no se repite. Se dejaron fuera palabras que darían ruido: «ENDE» (salta con «por ende»), «viaje», «exposición», «cumbre», «congreso» en los ejes (congreso de un partido).

El prompt 1.13 explica al clasificador cada grupo, su categoría y su prioridad. Un partido de liga sigue siendo «deporte sin efecto turístico»; un rally o un campeonato internacional con sede en Bolivia, no. Un paro médico va a **salud**, no a conflicto.

## Pasos

1. **Supabase**: ejecutar `58_ampliar_servicios_turismo.sql` entero. Al final sale una **vista previa**: cuántas noticias descartadas de los últimos 7 días pasarían ahora (`ahora_pasan`) y 15 ejemplos. No cambia nada.
2. **VPS**: copiar el prompt nuevo junto al analizador (comparar antes):
   ```bash
   cd /root/avia-repo && git fetch origin && git checkout claude/project-thread-79mhzr && git pull
   diff /root/avia/prompt_clasificador.md hermes/analizador/prompt_clasificador.md
   cp /root/avia/prompt_clasificador.md /root/avia/prompt_clasificador.md.1-12
   cp hermes/analizador/prompt_clasificador.md /root/avia/prompt_clasificador.md
   head -1 /root/avia/prompt_clasificador.md    # debe decir clasificador-1.13
   ```
   No hace falta reiniciar nada: el analizador lee el prompt en cada ejecución.
3. **Solo si Meysel lo aprueba** tras ver la vista previa: recuperar esas noticias y vaciar la cola sin esperar al cron.
   ```sql
   SELECT vigilante.repuntuar_descartadas('orbita-bolivia', 7, true);
   ```
   ```bash
   python3 /root/avia/analizador.py --lotes 40     # sin flock delante: el script tiene su propio candado
   ```
4. Comprobar al día siguiente con `diagnostico_recuperadas_55.sql` (filas de señales por eje).

## Volver atrás

- Prompt: `cp /root/avia/prompt_clasificador.md.1-12 /root/avia/prompt_clasificador.md`.
- Palabras: son listas del cliente en `vigilante.parametros` (`palabras_alerta`, `palabras_oportunidad`, `reglas_oportunidad`); se puede quitar cualquiera con un `UPDATE` o desde la web.
- `eje_de`: la versión anterior es el bloque «1a. Eje de una señal» del 49; basta con pegar solo ese `CREATE OR REPLACE FUNCTION` (no el 49 entero).

## Prueba

`99_prueba_ampliar_servicios_turismo.sql` en PostgreSQL 16 con 01–58: pasan 13 titulares nuevos (EPSAS, CRE, dengue, paro médico, basura, cajeros, cancelación de vuelos, BoA, Gran Poder, Expocruz, rally, turismo comunitario, teleférico) y no pasan fútbol, «por ende» ni «Juan Montero». Los ejes nuevos salen bien y el conflicto sigue yendo a movilidad. Siguen pasando las pruebas del 55 y del 49.
