-- Prueba de 16_tareas_programadas.sql: plazo de revisión, ventana de 7 días en la web pública,
-- resumen diario, recordatorios y datos del panel.
-- Requiere 01 a 16 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
-- Prueba el comportamiento del 16 tal cual: ejecutarla ANTES del 18. Desde el 18 nada se publica
-- sin aprobación al vencer el plazo (lo prueba 99_prueba_aprobacion.sql).
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

-- 0. Preparación: canal de Telegram y publicación automática al vencer encendida (solo en la prueba)
INSERT INTO vigilante.parametros (cliente_id, clave, valor)
SELECT id, k, v::jsonb FROM vigilante.clientes,
       (VALUES ('telegram_canal', '"@prueba"'), ('publicar_al_vencer', 'true')) AS p(k, v)
 WHERE slug = 'orbita-bolivia';

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';

-- Señales:
--  T-A  salud, oficial con enlace, hace 23 h, pide revisión → vence y se publica «En verificación»
--  T-B  vial, no oficial, hace 23 h → vence pero NO se publica
--  T-C  clima, recién detectada → aún en plazo
--  T-D  riesgo publicado hace 10 días → fuera de la ventana de 7 días
--  T-E  oportunidad publicada hace 10 días con plazo dentro de 20 días → se sigue viendo
--  T-F  predicción (escenario)
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad,
                               fuente_oficial, enlace_oficial, plazo_hasta, es_escenario, created_at)
SELECT c, x.codigo, x.titulo, 'Resumen ' || x.codigo, x.nat::vigilante.naturaleza_senal, x.cat, x.prio::vigilante.prioridad,
       x.oficial, x.enlace, x.plazo, x.esc, now() - x.hace
  FROM ids, (VALUES
    ('T-A', 'Alerta epidemiológica por dengue en Santa Cruz', 'riesgo',      'salud',          'alta',  true,  'https://minsalud.gob.bo/a', NULL::timestamptz, false, interval '23 hours'),
    ('T-B', 'Rumor de bloqueo en la ruta a Uyuni',            'riesgo',      'vial',           'media', false, NULL,                        NULL,              false, interval '23 hours'),
    ('T-C', 'Aviso de heladas en el altiplano',               'riesgo',      'clima',          'media', true,  'https://senamhi.gob.bo/c',  NULL,              false, interval '0 minutes'),
    ('T-D', 'Corte de luz en Tarija',                         'riesgo',      'eventos',        'baja',  true,  'https://ej.bo/d',           NULL,              false, interval '11 days'),
    ('T-E', 'Fondo para turismo comunitario',                 'oportunidad', 'financiamiento', 'alta',  true,  'https://ej.bo/e',           now() + interval '20 days', false, interval '11 days'),
    ('T-F', 'Escenario: más demanda en Uyuni en enero',       'oportunidad', 'eventos',        'media', true,  'https://ej.bo/f',           NULL,              true,  interval '1 hour')
  ) AS x(codigo, titulo, nat, cat, prio, oficial, enlace, plazo, esc, hace);

-- T-D y T-E: una persona las publicó hace 10 días
UPDATE vigilante.signals SET estado = 'en_analisis' WHERE codigo IN ('T-D', 'T-E');
UPDATE vigilante.signals SET estado = 'confirmada' WHERE codigo IN ('T-D', 'T-E');
UPDATE vigilante.signals SET estado = 'publicada', estado_manual = true WHERE codigo IN ('T-D', 'T-E');
UPDATE vigilante.alerts SET publicada_en = now() - interval '10 days'
 WHERE signal_id IN (SELECT id FROM vigilante.signals WHERE codigo IN ('T-D', 'T-E'));
DELETE FROM vigilante.deliveries;

-- 1. Plazo de revisión
SELECT vigilante.vencer_plazos_revision() AS plazos;
DO $$ BEGIN
  ASSERT (SELECT revision_vencida_en IS NOT NULL FROM vigilante.signals WHERE codigo = 'T-A'), 'T-A vencida';
  ASSERT (SELECT estado FROM vigilante.signals WHERE codigo = 'T-A') = 'publicada', 'T-A oficial con enlace → publicada';
  ASSERT (SELECT a.estado_verificacion FROM vigilante.alerts a JOIN vigilante.signals s ON s.id = a.signal_id WHERE s.codigo = 'T-A') = 'en_verificacion',
         'T-A sale con la etiqueta «En verificación»';
  ASSERT (SELECT revision_vencida_en IS NOT NULL FROM vigilante.signals WHERE codigo = 'T-B'), 'T-B vencida';
  ASSERT (SELECT estado FROM vigilante.signals WHERE codigo = 'T-B') = 'detectada', 'T-B no oficial → no se publica sola';
  ASSERT (SELECT revision_vencida_en IS NULL FROM vigilante.signals WHERE codigo = 'T-C'), 'T-C sigue en plazo';
  ASSERT (SELECT count(*) FROM vigilante.deliveries WHERE alert_id IS NOT NULL) = 1, 'aviso de Telegram de T-A en cola';
  ASSERT EXISTS (SELECT 1 FROM vigilante.signal_history h JOIN vigilante.signals s ON s.id = h.signal_id
                  WHERE s.codigo = 'T-A' AND h.nota LIKE 'Plazo de revisión vencido%'), 'queda en el historial';
END $$;
SELECT (vigilante.vencer_plazos_revision() ->> 'vencidas')::int AS segunda_vez_vencidas;   -- 0: no se repite

-- Con el parámetro apagado (por defecto) no se publica nada solo
DELETE FROM vigilante.parametros WHERE clave = 'publicar_al_vencer' AND cliente_id IS NOT NULL;
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, fuente_oficial, enlace_oficial, created_at)
SELECT c, 'T-G', 'Alerta oficial de inundación', 'Resumen', 'riesgo', 'clima', true, 'https://senamhi.gob.bo/g', now() - interval '23 hours' FROM ids;
SELECT vigilante.vencer_plazos_revision() AS plazos_apagado;
DO $$ BEGIN
  ASSERT (SELECT estado FROM vigilante.signals WHERE codigo = 'T-G') = 'detectada', 'apagado: solo se marca vencida';
  ASSERT (SELECT revision_vencida_en IS NOT NULL FROM vigilante.signals WHERE codigo = 'T-G'), 'apagado: marcada vencida';
END $$;

-- 2. Web pública: ventana de 7 días
DO $$
DECLARE j jsonb := vigilante.alertas_publicas('orbita-bolivia');
        k jsonb := vigilante.alertas_publicas('orbita-bolivia', true);
BEGIN
  ASSERT (SELECT array_agg(a ->> 'codigo' ORDER BY a ->> 'codigo') FROM jsonb_array_elements(j -> 'alertas') a) = ARRAY['T-A', 'T-E'],
         'actuales: T-A (hoy) y T-E (plazo abierto); T-D queda fuera';
  ASSERT (j ->> 'n_anteriores')::int = 1, 'hay 1 anterior';
  ASSERT (SELECT array_agg(a ->> 'codigo' ORDER BY a ->> 'codigo') FROM jsonb_array_elements(k -> 'alertas') a) = ARRAY['T-A', 'T-D', 'T-E'],
         'con «Ver anteriores» sale también T-D';
  ASSERT j ->> 'mensaje_sin_alertas' = 'No hay alertas confirmadas en este momento', 'texto acordado';
  ASSERT (j ->> 'dias_visibles')::int = 7, '7 días por defecto';
END $$;

-- 3. Resumen diario: la hora fijada es «hace un minuto» en Bolivia
INSERT INTO vigilante.parametros (cliente_id, clave, valor)
SELECT c, 'resumen_hora', to_jsonb(to_char((now() AT TIME ZONE 'America/La_Paz') - interval '1 minute', 'HH24:MI')) FROM ids;
SELECT vigilante.tareas_programadas() AS tareas;
DO $$
DECLARE d bigint := (SELECT id FROM vigilante.daily_digests ORDER BY id DESC LIMIT 1);
BEGIN
  ASSERT d IS NOT NULL, 'resumen generado';
  ASSERT (SELECT count(*) FROM vigilante.daily_digest_items WHERE digest_id = d) = 1, 'solo T-A es de las últimas 24 h';
  ASSERT EXISTS (SELECT 1 FROM vigilante.deliveries WHERE digest_id = d AND canal = 'telegram'), 'resumen en cola de Telegram';
  ASSERT vigilante.texto_resumen(d) LIKE '%Alerta epidemiológica por dengue%', 'el texto lleva la alerta';
  ASSERT jsonb_array_length(vigilante.alertas_publicas('orbita-bolivia') #> '{resumen,alertas}') = 1, 'la web muestra el resumen';
END $$;
SELECT vigilante.tareas_programadas() AS tareas_otra_vez;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.daily_digests) = 1, 'un solo resumen al día';
  ASSERT (SELECT count(*) FROM vigilante.deliveries WHERE digest_id IS NOT NULL) = 1, 'no se reenvía';
END $$;

-- 4. Recordatorios: T-E cierra en 20 días → 15 y 5 días programados (30 ya pasó)
DO $$ BEGIN
  ASSERT (SELECT array_agg(dias_antes ORDER BY dias_antes) FROM vigilante.follow_ups f JOIN vigilante.signals s ON s.id = f.signal_id
           WHERE s.codigo = 'T-E') = ARRAY[5, 15]::smallint[], 'recordatorios a 15 y 5 días';
END $$;
-- uno que ya toca y otro que llegó tarde
INSERT INTO vigilante.follow_ups (signal_id, tipo, fecha_objetivo, dias_antes, programado_para)
SELECT id, 'plazo_convocatoria', plazo_hasta, 25, now() - interval '1 minute' FROM vigilante.signals WHERE codigo = 'T-E';
INSERT INTO vigilante.follow_ups (signal_id, tipo, fecha_objetivo, dias_antes, programado_para)
SELECT id, 'plazo_convocatoria', plazo_hasta, 27, now() - interval '2 days' FROM vigilante.signals WHERE codigo = 'T-E';
SELECT vigilante.enviar_recordatorios() AS recordatorios;
DO $$ BEGIN
  ASSERT (SELECT enviado_en IS NOT NULL FROM vigilante.follow_ups WHERE dias_antes = 25), 'el de hoy se envía';
  ASSERT (SELECT cancelado FROM vigilante.follow_ups WHERE dias_antes = 27), 'el atrasado se cancela';
  ASSERT (SELECT count(*) FROM vigilante.deliveries WHERE follow_up_id IS NOT NULL) = 1, 'un recordatorio en cola';
  ASSERT vigilante.texto_recordatorio((SELECT id FROM vigilante.follow_ups WHERE dias_antes = 25)) LIKE '%faltan 25 días%', 'texto del recordatorio';
END $$;

-- 5. Envío sin token en el Vault: avisa y no rompe
SELECT vigilante.enviar_telegram_pendientes() AS telegram;

-- 6. Panel: plazo de revisión, vencidas y escenario
DO $$
DECLARE j jsonb := vigilante._vigilante_json((SELECT c FROM ids));
BEGIN
  ASSERT (SELECT s ? 'revision_vence' FROM jsonb_array_elements(j -> 'senales') s WHERE s ->> 'id' = 'T-C'), 'T-C con su plazo';
  ASSERT (SELECT s ? 'revision_vencida' FROM jsonb_array_elements(j -> 'senales') s WHERE s ->> 'id' = 'T-B'), 'T-B marcada vencida';
  ASSERT (SELECT (s ->> 'escenario')::boolean FROM jsonb_array_elements(j -> 'senales') s WHERE s ->> 'id' = 'T-F'), 'T-F es escenario';
  ASSERT NOT (SELECT s ? 'revision_vence' FROM jsonb_array_elements(j -> 'senales') s WHERE s ->> 'id' = 'T-A'), 'T-A publicada: sin plazo';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(j -> 'senales') s WHERE s ->> 'id' = 'T-D') = 1, 'el panel ve también lo de hace 11 días';
END $$;

-- 7. Retención: no borra nada reciente
SELECT * FROM vigilante.purgar_retencion();

\echo 'PRUEBA OK'
ROLLBACK;
