// Datos de ejemplo (ficticios) de la prueba de concepto.
// Se sustituyen por consultas a Supabase en src/services/api.ts cuando la base esté montada.
import type {
  CategoriaId, Etapa, EstadoFuente, Evento, Fuente, PanelDef, PanelId, Preset, Senal, Serie, Tema, VistaId,
} from '../types';

export const DEPS: string[] =['La Paz','Cochabamba','Santa Cruz','Oruro','Potosí','Chuquisaca','Tarija','Beni','Pando'];
export const CATS: Record<CategoriaId, string> ={clima:'Clima',salud:'Salud',vial:'Vial',seguridad:'Seguridad',conectividad:'Conectividad',eventos:'Eventos',financiacion:'Financiación',mercado:'Mercado y demanda',normativa:'Normativa',turismo:'Turismo'};
export const STAGES: [Etapa, string][] =[['detectada','Detectada'],['en_analisis','En análisis'],['en_verificacion','En verificación'],['confirmada','Confirmada'],['publicada','Publicada'],['descartada','Descartada']];
export const STL = Object.fromEntries(STAGES) as Record<Etapa, string>;
export const STATE_TXT: Record<EstadoFuente, string> ={OK:'OK',WARN:'AVISO',CRIT:'CRÍTICO',UNKNOWN:'DESCONOCIDO',MANT:'MANTENIMIENTO'};
const H: Record<string, EstadoFuente> = { o: 'OK', w: 'WARN', c: 'CRIT', u: 'UNKNOWN', m: 'MANT' };
export const h24 = (pattern: string): EstadoFuente[] => pattern.split('').map((c) => H[c]);

export const FUENTES_DEMO: Fuente[] = [
 {id:'senamhi_alertas',nombre:'SENAMHI · alertas meteorológicas',canal:'clima',tipo:'oficial',url:'https://senamhi.gob.bo/alertas3.php',metodo:'HTML (tabla) + PDF',freq:30,estado:'OK',info:'HTTP 200 · tabla con 41 avisos · 1 nuevo (N° 41/26)',lat:1240,items:3,desde:180,hist:h24('oooooooooooowwoooooooooo'),verif:'verificada'},
 {id:'minsalud',nombre:'Ministerio de Salud y Deportes',canal:'salud',tipo:'oficial',url:'https://www.minsalud.gob.bo/',metodo:'HTML (sin RSS)',freq:60,estado:'WARN',info:'HTTP 200 · el selector de comunicados no devolvió filas (¿cambió la página?)',lat:3320,items:0,desde:95,hist:h24('oooooooooooooooooooowwww'),verif:'verificada'},
 {id:'ops_alertas',nombre:'OPS/OMS · alertas epidemiológicas',canal:'salud',tipo:'oficial',url:'https://www.paho.org/es/alertas-actualizaciones-epidemiologicas',metodo:'RSS general + filtro país',freq:60,estado:'OK',info:'RSS 200 · 2 entradas nuevas · 1 menciona Bolivia',lat:640,items:2,desde:720,hist:h24('oooooooooooooooooooooooo'),verif:'verificada'},
 {id:'abc_caminos',nombre:'ABC · transitabilidad vial',canal:'vial',tipo:'oficial',url:'https://transitabilidad.abc.gob.bo/mapa_reporte',metodo:'Navegador (Apify)',freq:30,estado:'CRIT',info:'Tiempo de espera agotado (30 s) en 3 de 3 intentos',lat:30000,items:0,desde:48,hist:h24('ooooowooooowoooowooccccc'),verif:'no abierta',flap:true},
 {id:'minturismo',nombre:'Min. de Turismo Sostenible, Culturas…',canal:'eventos',tipo:'oficial',url:'https://www.turismoyculturas.gob.bo/',metodo:'HTML',freq:120,estado:'WARN',info:'HTTP 200 en 8,4 s (umbral 5 s) · 1 nota nueva',lat:8400,items:1,desde:30,hist:h24('oooooowoooooooooooooowww'),verif:'no abierta'},
 {id:'gaceta_oficial',nombre:'Gaceta Oficial del Estado',canal:'normativa',tipo:'oficial',url:'http://www.gacetaoficialdebolivia.gob.bo/normas/buscar',metodo:'HTML',freq:360,estado:'OK',info:'HTTP 200 · 4 normas publicadas hoy · 1 sobre turismo',lat:2100,items:1,desde:1440,hist:h24('oooooooooooooooooooooooo'),verif:'no abierta'},
 {id:'dgac',nombre:'DGAC · comunicados y aeropuertos',canal:'conectividad',tipo:'oficial',url:'https://www.dgac.gob.bo/',metodo:'HTML',freq:120,estado:'UNKNOWN',info:'Sin comprobar: falta confirmar la URL de comunicados',lat:null,items:0,desde:300,hist:h24('uuuuuuuuuuuuuuuuuuuuuuuu'),verif:'por confirmar'},
 {id:'orbita',nombre:'ORBITA · convocatorias y fondos',canal:'financiacion',tipo:'aliado',url:'https://orbita.bo/',metodo:'HTML',freq:240,estado:'OK',info:'HTTP 200 · 2 convocatorias abiertas',lat:900,items:2,desde:2880,hist:h24('oooooooooooooooooooooooo'),verif:'por confirmar'},
 {id:'multilaterales',nombre:'CAF · BID · PNUD (licitaciones)',canal:'financiacion',tipo:'oficial',url:'https://www.caf.com/es/convocatorias/',metodo:'HTML + RSS',freq:360,estado:'OK',info:'3 sitios OK · 1 convocatoria nueva para Bolivia',lat:1800,items:1,desde:600,hist:h24('oooooooooooooooooooooooo'),verif:'por confirmar'},
 {id:'prensa',nombre:'Prensa nacional (Google News RSS)',canal:'mercado',tipo:'prensa',url:'https://news.google.com/rss/search?q=turismo+Bolivia&hl=es-419',metodo:'RSS',freq:30,estado:'OK',info:'RSS 200 · 37 notas · 6 pasan el filtro de ruido',lat:520,items:6,desde:900,hist:h24('oooooooooooooooooooooooo'),verif:'verificada'},
 {id:'tavily',nombre:'Búsqueda abierta (Tavily)',canal:'mercado',tipo:'buscador',url:'https://api.tavily.com',metodo:'API',freq:180,estado:'OK',info:'API 200 · 12 resultados · 2 temas nuevos',lat:1450,items:2,desde:420,hist:h24('oooooooooooooooooooooooo'),verif:'API'},
 {id:'rrss',nombre:'Redes sociales (temas vivos)',canal:'mercado',tipo:'social',url:'—',metodo:'AVIA + n8n',freq:60,estado:'MANT',info:'En construcción: calibrando temas y deriva',lat:null,items:0,desde:4320,hist:h24('mmmmmmmmmmmmmmmmmmmmmmmm'),verif:'en construcción'}
];

export const SENALES_DEMO: Senal[] = [
 {id:'SEN-0418',titulo:'Alerta naranja por lluvias fuertes en Yungas y Rurrenabaque (4 al 6 nov)',resumen:'Aviso de ejemplo: lluvias de moderada a fuerte intensidad con granizo y tormenta eléctrica; acumulados de 40 a 70 mm del 4 al 6 de noviembre.',naturaleza:'riesgo',categoria:'clima',deps:['La Paz','Beni'],destinos:['Coroico','Rurrenabaque'],estado:'confirmada',prioridad:'alta',rel:9,nov:8,conf:.92,fuentes:['senamhi_alertas','prensa'],corr:2,min:34,importancia:'Coincide con salidas de fin de semana largo hacia Coroico y con circuitos fluviales en Rurrenabaque. Afecta la carretera de Yungas y las salidas por río.',soluciones:[{t:'Avisar a operadores de Yungas y Rurrenabaque',d:'Mensaje con vigencia, zonas y recomendación de reprogramar salidas por río.'},{t:'Sugerir destinos alternativos',d:'Proponer Samaipata o Sucre a agencias con grupos ya vendidos.'},{t:'Seguir el aviso hasta su cierre',d:'Comparar con el siguiente aviso de SENAMHI y actualizar el estado.'}]},
 {id:'SEN-0417',titulo:'CAF abre fondo para turismo comunitario con cierre en 12 días',resumen:'Convocatoria de ejemplo para proyectos de turismo comunitario y sostenible en países andinos, con montos de hasta USD 80 000 por propuesta.',naturaleza:'oportunidad',categoria:'financiacion',deps:['La Paz','Potosí','Beni','Santa Cruz'],destinos:['Lago Titicaca','Uyuni','Madidi'],estado:'publicada',prioridad:'alta',rel:9,nov:9,conf:.95,fuentes:['multilaterales','orbita'],corr:2,min:180,plazo:12,tipoOpp:'Financiación',actores:['Comunidades','ONG','Municipios'],importancia:'El plazo es menor de 15 días (prioridad alta). Encaja con emprendimientos comunitarios ya registrados en ORBITA.',soluciones:[{t:'Avisar a las 14 iniciativas comunitarias del registro',d:'Enviar ficha con requisitos y fecha de cierre.'},{t:'Organizar taller rápido de postulación',d:'Sesión virtual de 1 hora con ORBITA.'},{t:'Recordatorios a 5 días y a 1 día',d:'Programar recordatorio automático.'}]},
 {id:'SEN-0416',titulo:'Búsquedas sobre el "efecto espejo" de Uyuni suben con la temporada de lluvias',resumen:'Ejemplo: prensa y búsqueda abierta muestran más interés internacional por Uyuni entre diciembre y marzo; tres medios lo mencionan esta semana.',naturaleza:'mixta',categoria:'mercado',deps:['Potosí'],destinos:['Salar de Uyuni'],estado:'en_analisis',prioridad:'media',rel:8,nov:6,conf:.71,fuentes:['prensa','tavily'],corr:3,min:95,importancia:'Oportunidad de demanda, pero la misma lluvia que crea el espejo puede cortar accesos. AVIA la marca como mixta.',soluciones:[{t:'Preparar campaña "espejo responsable"',d:'Con recomendaciones de acceso y operadores habilitados.'},{t:'Cruzar con alertas de clima de Potosí',d:'Vigilar SENAMHI y ABC para la ruta Oruro–Uyuni.'}]},
 {id:'SEN-0415',titulo:'Actualización epidemiológica regional por dengue en tierras bajas',resumen:'Ejemplo: la OPS publica una actualización regional; menciona aumento de casos en zonas tropicales, incluida parte de Bolivia.',naturaleza:'riesgo',categoria:'salud',deps:['Santa Cruz','Beni','Pando'],destinos:['Chiquitania','Riberalta'],estado:'en_verificacion',prioridad:'alta',rel:8,nov:7,conf:.64,fuentes:['ops_alertas'],corr:1,min:52,sla:9,importancia:'Hay que confirmar con el Ministerio de Salud antes de difundir: la fuente nacional está en AVISO y no se pudo contrastar.',soluciones:[{t:'Pedir confirmación al Ministerio de Salud',d:'Revisar boletín epidemiológico nacional a mano.'},{t:'Preparar recomendaciones al visitante',d:'Repelente, ropa, consulta médica; sin alarmar.'}]},
 {id:'SEN-0414',titulo:'Restricción de paso por trabajos en la carretera Cotapata – Santa Bárbara',resumen:'Ejemplo: medios locales reportan cierres por horario en un tramo hacia Caranavi. La ABC no responde, así que no está confirmado.',naturaleza:'riesgo',categoria:'vial',deps:['La Paz'],destinos:['Caranavi','Coroico'],estado:'detectada',prioridad:'media',rel:7,nov:8,conf:.48,fuentes:['prensa'],corr:1,min:21,importancia:'Corredor de Yungas con lluvias en alerta naranja: el efecto combinado sube el riesgo.',soluciones:[{t:'Esperar confirmación de la ABC',d:'Fuente en CRÍTICO; reintentar y comprobar a mano.'},{t:'Unir con la señal SEN-0418',d:'Mismo corredor y mismas fechas.'}]},
 {id:'SEN-0413',titulo:'Nueva frecuencia aérea Viru Viru – Lima desde diciembre',resumen:'Ejemplo: una aerolínea anuncia una frecuencia diaria adicional; prensa económica lo confirma. La DGAC aún no se vigila.',naturaleza:'oportunidad',categoria:'conectividad',deps:['Santa Cruz'],destinos:['Santa Cruz de la Sierra','Misiones jesuíticas'],estado:'confirmada',prioridad:'alta',rel:8,nov:9,conf:.83,fuentes:['prensa','tavily'],corr:2,min:240,plazo:28,tipoOpp:'Conectividad',actores:['Agencias receptivas','Hoteles','Gobernación'],importancia:'Nueva ruta aérea: es un criterio de prioridad alta. Abre paquetes combinados Lima + Chiquitania.',soluciones:[{t:'Proponer paquete Lima + Misiones',d:'Contactar agencias receptivas de Santa Cruz.'},{t:'Medir el efecto en reservas',d:'Pedir datos de ocupación a 30 y 60 días.'}]},
 {id:'SEN-0412',titulo:'Feria de turismo y gastronomía anunciada en Tarija para fin de mes',resumen:'Ejemplo: nota del Ministerio de Turismo sobre una feria con rueda de negocios y stands para operadores.',naturaleza:'oportunidad',categoria:'eventos',deps:['Tarija'],destinos:['Valle de la Concepción'],estado:'publicada',prioridad:'media',rel:7,nov:7,conf:.88,fuentes:['minturismo'],corr:1,min:400,plazo:24,tipoOpp:'Evento',actores:['Operadores','Bodegas','Restaurantes'],importancia:'Rueda de negocios: oportunidad directa para operadores del sur.',soluciones:[{t:'Difundir a operadores de Tarija y Chuquisaca',d:'Con fecha límite de inscripción.'},{t:'Recordatorios a 30, 15 y 5 días',d:'Según la regla de eventos.'}]},
 {id:'SEN-0411',titulo:'Humo por quemas en la Chiquitania reduce la visibilidad',resumen:'Ejemplo: notas de prensa y búsquedas abiertas mencionan focos de calor y humo; sin aviso oficial aún.',naturaleza:'riesgo',categoria:'clima',deps:['Santa Cruz'],destinos:['San José de Chiquitos'],estado:'en_verificacion',prioridad:'media',rel:7,nov:5,conf:.55,fuentes:['prensa','tavily'],corr:2,min:130,sla:4,importancia:'Afecta rutas de misiones y vuelos locales; puede derivar en recomendación sanitaria.',soluciones:[{t:'Buscar dato oficial de focos de calor',d:'Añadir la fuente oficial de incendios al catálogo.'},{t:'Avisar a operadores de misiones',d:'Solo si se confirma.'}]},
 {id:'SEN-0410',titulo:'Decreto amplía el fin de semana largo por feriado departamental',resumen:'Ejemplo: norma publicada en la Gaceta que traslada un feriado y crea un fin de semana de tres días.',naturaleza:'oportunidad',categoria:'normativa',deps:['Cochabamba','Chuquisaca'],destinos:['Torotoro','Sucre'],estado:'confirmada',prioridad:'media',rel:7,nov:8,conf:.9,fuentes:['gaceta_oficial'],corr:1,min:600,plazo:17,tipoOpp:'Demanda interna',actores:['Hoteles','Operadores locales'],importancia:'Fines de semana largos aumentan el turismo interno hacia destinos cercanos.',soluciones:[{t:'Campaña de escapadas a Torotoro y Sucre',d:'Con operadores locales.'}]},
 {id:'SEN-0409',titulo:'PNUD busca socios locales para rutas de turismo rural',resumen:'Ejemplo: convocatoria para asociaciones que gestionen rutas de turismo rural, con asistencia técnica.',naturaleza:'oportunidad',categoria:'financiacion',deps:['Chuquisaca','Potosí','Oruro'],destinos:['Tarabuco','Potosí'],estado:'en_analisis',prioridad:'media',rel:7,nov:7,conf:.77,fuentes:['multilaterales'],corr:1,min:310,plazo:33,tipoOpp:'Socios',actores:['Asociaciones','Municipios'],importancia:'Fortalece rutas fuera de los destinos saturados.',soluciones:[{t:'Identificar asociaciones elegibles',d:'Cruzar con el registro ORBITA.'}]},
 {id:'SEN-0408',titulo:'Anuncio de bloqueo en la ruta Oruro – Potosí',resumen:'Ejemplo: mensaje difundido en redes y una radio local; no hay confirmación oficial.',naturaleza:'riesgo',categoria:'seguridad',deps:['Oruro','Potosí'],destinos:['Uyuni','Potosí'],estado:'descartada',prioridad:'baja',rel:5,nov:6,conf:.3,fuentes:['prensa'],corr:0,min:900,importancia:'No se corroboró en 24 h; se descartó y quedó en el historial.',soluciones:[{t:'Mantener en historial',d:'Por si vuelve a aparecer.'}]},
 {id:'SEN-0407',titulo:'Samaipata gana visibilidad como ruta del vino de altura',resumen:'Ejemplo: tema que crece en búsquedas abiertas y prensa de viajes.',naturaleza:'oportunidad',categoria:'mercado',deps:['Santa Cruz'],destinos:['Samaipata'],estado:'detectada',prioridad:'baja',rel:6,nov:7,conf:.6,fuentes:['tavily'],corr:1,min:70,plazo:null,tipoOpp:'Mercado',actores:['Bodegas','Hospedajes'],importancia:'Diversifica la oferta de Santa Cruz más allá de la ciudad.',soluciones:[{t:'Seguir el tema 7 días',d:'Si se mantiene, proponer contenido y paquete.'}]}
];
/** Señales que la simulación va "detectando" cada minuto */
export const PENDIENTES_DEMO: Senal[] = [
 {id:'SEN-0419',titulo:'Granizada afecta temporalmente el aeropuerto de El Alto',resumen:'Ejemplo: retrasos de vuelos por granizo; operaciones normalizadas en 2 horas.',naturaleza:'riesgo',categoria:'conectividad',deps:['La Paz'],destinos:['La Paz'],estado:'detectada',prioridad:'media',rel:6,nov:9,conf:.58,fuentes:['prensa'],corr:1,min:0,importancia:'Puede afectar conexiones de visitantes hacia Uyuni y Rurrenabaque.',soluciones:[{t:'Verificar con el aeropuerto',d:'Confirmar normalidad.'}]},
 {id:'SEN-0420',titulo:'Festival de música barroca anuncia fechas en la Chiquitania',resumen:'Ejemplo: organizadores publican fechas y programa preliminar.',naturaleza:'oportunidad',categoria:'eventos',deps:['Santa Cruz'],destinos:['Misiones jesuíticas'],estado:'detectada',prioridad:'media',rel:8,nov:8,conf:.7,fuentes:['prensa','minturismo'],corr:2,min:0,plazo:75,tipoOpp:'Evento',actores:['Agencias','Hoteles'],importancia:'Evento de alto impacto internacional; recordatorios a 90/60/30 días.',soluciones:[{t:'Preparar paquete del festival',d:'Con agencias y hoteles de misiones.'}]},
 {id:'SEN-0421',titulo:'BID publica consultoría para planes de destino sostenible',resumen:'Ejemplo: licitación para elaborar planes de gestión en dos destinos.',naturaleza:'oportunidad',categoria:'financiacion',deps:['La Paz','Chuquisaca'],destinos:['Copacabana','Sucre'],estado:'detectada',prioridad:'media',rel:7,nov:8,conf:.8,fuentes:['multilaterales'],corr:1,min:0,plazo:21,tipoOpp:'Licitación',actores:['Consultoras','Universidades'],importancia:'Oportunidad para consultoras locales y universidades.',soluciones:[{t:'Difundir a consultoras registradas',d:'Con requisitos.'}]}
];

export const TEMAS_DEMO: Tema[] = [
 {t:'Temporada de lluvias y accesos a destinos',n:14,d:+5,nat:'mixta'},
 {t:'Fondos y convocatorias para turismo comunitario',n:9,d:+3,nat:'oportunidad'},
 {t:'Conectividad aérea con Santa Cruz',n:7,d:+2,nat:'oportunidad'},
 {t:'Salud del visitante en tierras bajas',n:6,d:+1,nat:'riesgo'},
 {t:'Eventos y ferias del último trimestre',n:5,d:0,nat:'oportunidad'},
 {t:'Conflictos y bloqueos viales',n:3,d:-2,nat:'riesgo'}
];
export const SERIE_DEMO: Serie ={labels:['21','22','23','24','25','26','27','28','29','30','31','1','2','3'],det:[22,25,19,28,31,26,24,33,29,35,38,34,41,37],opp:[5,6,4,7,8,6,7,9,8,10,11,9,12,11],risk:[6,7,5,9,8,7,6,8,10,9,12,11,13,10]};

export const EVENTOS_DEMO: Evento[] = [
 {t:-3,k:'OK',w:'SENAMHI · comprobación correcta',d:'1 aviso nuevo detectado → SEN-0418 actualizada'},
 {t:-9,k:'CRIT',w:'ABC · transitabilidad pasó a CRÍTICO',d:'Tiempo de espera agotado 3/3 · se notificó al administrador'},
 {t:-21,k:'spark',w:'AVIA detectó una señal nueva',d:'SEN-0414 · restricción vial Cotapata – Santa Bárbara'},
 {t:-34,k:'check',w:'Analista confirmó SEN-0418',d:'Alerta naranja Yungas · publicada en el resumen'},
 {t:-52,k:'WARN',w:'Ministerio de Salud pasó a AVISO',d:'El selector de comunicados no devolvió filas'},
 {t:-95,k:'spark',w:'Macrotema en crecimiento',d:'"Temporada de lluvias y accesos" sube de 9 a 14 señales'},
 {t:-180,k:'check',w:'Oportunidad publicada automáticamente',d:'SEN-0417 · fuente oficial (CAF)'}
];


export const PANELS: Record<PanelId, PanelDef> = {
 sintesis:{t:'Síntesis del día',i:'sintesis',d:'Lo más importante en una frase y cuatro cifras.',w:8},
 pulso:{t:'Pulso del observatorio',i:'pulso',d:'Índices de atención y de oportunidad.',w:4},
 fuentes:{t:'Estado de las fuentes',i:'fuentes',d:'Cada fuente vigilada con su estado y sus últimas 24 comprobaciones.',w:8},
 cadena:{t:'Cadena del conocimiento',i:'cadena',d:'De noticia dispersa a acción propuesta.',w:4},
 oportunidades:{t:'Oportunidades abiertas',i:'oportunidades',d:'Las oportunidades con mejor puntuación y su plazo.',w:6},
 riesgos:{t:'Riesgos activos',i:'riesgo',d:'Riesgos confirmados o en verificación.',w:6},
 mapa:{t:'Mapa por departamento',i:'mapa',d:'Esquema de Bolivia con señales por departamento.',w:5},
 evolucion:{t:'Evolución diaria',i:'analisis',d:'Señales detectadas, oportunidades y riesgos por día.',w:7},
 decision:{t:'Pendiente de tu decisión',i:'decision',d:'Señales que esperan verificación humana.',w:6},
 actividad:{t:'Actividad reciente',i:'actividad',d:'Registro de comprobaciones y decisiones.',w:6},
 temas:{t:'Temas emergentes',i:'temas',d:'Macrotemas que agrupa AVIA y su tendencia.',w:5},
 categorias:{t:'Señales por categoría',i:'categorias',d:'Reparto entre oportunidades, riesgos y mixtas.',w:7},
 valoracion:{t:'Valoración del público',i:'check',d:'Votos «¿Te fue útil?» de la web pública, para la revisión semanal.',w:6}
};
export const PRESETS: Record<string, Preset> = {
 ejecutivo:{n:'Ejecutivo',l:[['sintesis',8],['pulso',4],['oportunidades',6],['riesgos',6],['mapa',5],['evolucion',7]]},
 analista:{n:'Analista',l:[['decision',6],['fuentes',6],['valoracion',6],['actividad',6],['temas',4],['cadena',4],['categorias',4]]},
 operacion:{n:'Operación (fuentes)',l:[['fuentes',12],['actividad',6],['pulso',6],['evolucion',12]]},
 sencillo:{n:'Sencillo',l:[['sintesis',12],['oportunidades',6],['riesgos',6]]}
};

export const VIEWS: [VistaId, string, string][] = [
  ['panorama', 'Panorama', 'panorama'],
  ['fuentes', 'Fuentes', 'fuentes'],
  ['senales', 'Señales', 'senales'],
  ['oportunidades', 'Oportunidades', 'oportunidades'],
  ['analisis', 'Análisis', 'analisis'],
  ['bitacora', 'Bitácora', 'bitacora'],
];

/** nombre visible de una categoría o canal; si no se reconoce, el texto tal cual */
export const catName = (c: string): string => (CATS as Record<string, string>)[c] ?? c;
