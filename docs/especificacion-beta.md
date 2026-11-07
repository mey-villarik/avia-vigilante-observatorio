# Especificación beta: sistema de alertas turísticas Bolivia (ORBITA + Ministerio)

Fuente: chat de Perplexity con las respuestas de Meysel (31-10-2026), corregido según el [análisis](https://claude.ai/artifact/XwjPmYVT12aP9MYqXEyCnF).
Las decisiones marcadas como **[ajuste propuesto]** son las recomendaciones del análisis, pendientes de confirmar por Meysel.

## Decisiones cerradas
| Área | Decisión |
| --- | --- |
| Objetivo | Detectar oportunidades y riesgos para el turismo boliviano, priorizando oportunidades sin descuidar riesgos climáticos y sanitarios |
| Usuario principal | Sector turismo de Bolivia |
| Ámbito | Todo Bolivia |
| Duración | Beta de 30 días |
| Éxito | Detectar riesgos, oportunidades, eventos y cambios relevantes |
| Roles | Administrador, analista (aprueba alertas) y visor final **[ajuste propuesto: son 3 roles, no 2]** |
| Correcciones | Administrador |
| WhatsApp | Solo recepción; no hay reportes ciudadanos. El usuario elige temas y departamentos |
| Categorías | Todas desde el día uno |
| Naturaleza de la señal | Riesgo, oportunidad o mixta |
| Revisión obligatoria | Riesgos sanitarios, climáticos, viales y de seguridad; todo lo que vaya por WhatsApp; fuentes no oficiales |
| SLA de revisión | 15 minutos **[ajuste propuesto: en horario de guardia, p. ej. 07:00–22:00]** |
| Sin aprobación a tiempo | Se envía con estado "en verificación" **[ajuste propuesto: solo si reproduce un aviso oficial con enlace]** |
| Resumen diario | Máximo 7 alertas; hora por definir (p. ej. 08:00 hora Bolivia) |
| Web | Pública para alertas, privada para gestión. Filtros: departamento, categoría, prioridad, fecha |
| Respuesta sin alertas | "No hay alertas confirmadas en este momento" |
| Feedback | Botones útil / no útil |
| Idioma | Español |
| Retención | 6 meses |
| Actualizaciones | Se actualiza la alerta y se guarda historial (signal_history) |
| Anticipación | 24 horas |
| Predicciones | Sí, etiquetadas como escenario **[ajuste propuesto: privadas al inicio]** |
| Infraestructura | n8n self-hosted |
| Base de datos | Supabase (plan gratuito) → PostgreSQL propio si crece |
| Presupuesto | Menos de USD 50/mes |
| Revisión del piloto | Semanal; decide la continuidad el administrador |

## Prioridad alta (basta una)
Alerta SENAMHI naranja o roja · alerta epidemiológica oficial · riesgo para vida, salud o seguridad del visitante · corte vial, cierre de aeropuerto o pérdida de acceso · convocatoria con plazo < 15 días · evento de alto impacto con fecha próxima · nueva ruta aérea o cambio importante de conectividad.

Las oportunidades de fuente oficial se publican en web automáticamente; por WhatsApp solo si las aprueba el analista o si el plazo es < 15 días.

## Estados
detectada → en_analisis → en_verificacion → confirmada → publicada → cerrada (o → descartada)

## Fuentes
Semana 1 (5): SENAMHI alertas hidrológicas y meteorológicas (carga con JavaScript, usar Apify), Ministerio de Salud (comunicados y boletines epidemiológicos), OPS/OMS alertas, Ministerio de Turismo y Culturas, ORBITA.
Semanas 3–4: SENAMHI noticias, Conoce Bolivia, CAF, BID, PNUD licitaciones, ABC caminos, DGAC/aeropuertos, Gaceta Oficial, Tavily (búsqueda abierta).

## Modelo e IA
- Clasificación en n8n: un solo modelo, Hermes 4 70B (Nous Portal USD 0,05/0,20 por M tokens; OpenRouter 0,13/0,40). ~USD 1–3/mes. Confirmar el modelo Hermes vigente.
- Hermes Agent: verificación, prospectiva y asistente del analista (no como simple llamada de clasificación).
- Consultas por WhatsApp: sin IA al inicio, consulta directa a la base de datos.
- Por decidir: si AVIA es el flujo de recolección o una capa aparte.

## Workflows n8n
1. Recolección (Schedule → fuentes activas → RSS / HTTP + HTML Extract / Tavily / Apify → normalizar → hash → raw_items)
2. Filtro (dedupe por URL/hash → menciona Bolivia/departamento → categoría → cola)
3. Análisis Hermes (prompt corto → JSON validado → signals → cola revisión / alerta / resumen)
4. Revisión humana (tarjeta al analista → espera 15 min → publicar / "en verificación" → registrar)
5. Envío (filtrar usuarios por tema y departamento → plantilla → enviar → registrar → publicar en web)
6. Resumen diario (últimas 24 h → máx. 7 → un mensaje → web)
7. Consulta por chat (webhook → comando → BD → respuesta)
8. Recordatorios (convocatorias a 30/15/5 días; eventos a 90/60/30 días)

## Tablas mínimas
sources, raw_items, signals, signal_history, alerts, users, user_preferences, feedback, follow_ups, system_logs

## Presupuesto (USD/mes)
VPS 8–15 · n8n 0 · Supabase 0 · Hermes 1–3 · Tavily 0 · Apify 5–15 · Telegram/correo 0 → total 13–33. WhatsApp después: cobro por mensaje de plantilla fuera de la ventana de 24 h.

## Plan de 30 días
1. VPS, n8n, Supabase, tablas, 5 fuentes
2. Filtro, Hermes, JSON, dedupe, panel web básico
3. Canal de envío (Telegram/correo; WhatsApp si ya está aprobado), alertas urgentes, resumen diario, preferencias
4. Oportunidades, recordatorios, feedback, métricas, revisión semanal

## Pendientes
- Contestar las preguntas 21, 25, 27, 32, 41, 44 y 54 del cuestionario
- Nombrar a las personas de cada rol
- Cuenta Meta Business + número dedicado para WhatsApp Business API
- API key de Hermes (Nous Portal u OpenRouter), Apify y Tavily
- Hora del resumen diario
