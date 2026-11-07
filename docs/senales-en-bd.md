# Señales en la base de datos

Hermes sigue publicando `vigilante.json`. Ese archivo se lleva a las tablas `vigilante.sources` y `vigilante.signals` de Supabase con `vigilante.sincronizar_vigilante()`, y la web guarda allí las decisiones de las personas.

## Qué se guarda ya

- **Etapa de cada señal** (arrastrar en Señales, o Confirmar / Publicar / Pedir verificación / Descartar en su ficha), con quién lo hizo y la nota. Queda en `vigilante.signal_history` y aparece en la Bitácora.
- Las reglas de etapas son las de la base (`transicion_valida`): por ejemplo, una señal confirmada no vuelve a «Detectada». La web avisa antes de intentarlo.
- Cuando una persona mueve una señal, la sincronización deja de cambiarle la etapa (`estado_manual`).

## Instalar

1. SQL Editor: ejecutar `db/generico/04_sincronizar_vigilante.sql` (se puede repetir).
2. Elegir cómo llega el archivo a las tablas:
   - **Desde Supabase** (lo más rápido, mientras el archivo del VPS sea público): ejecutar `db/generico/05_sincronizar_desde_supabase.sql`. Lo descarga cada 5 minutos.
   - **Desde el VPS** (cuando se cierre `/data`): `integraciones/hermes-web/subir_vigilante_json.sh` sube el archivo al almacenamiento privado y sincroniza las tablas.

## Pendiente

Fuentes (reconocer, mantenimiento, alta), señales nuevas desde Análisis, y conversaciones de «Pregunta a AVIA».
