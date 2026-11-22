// Tipos del dominio del Vigilante. Siguen las columnas del esquema `vigilante` de la base
// (db/migrations) para que el paso de datos de ejemplo a Supabase sea directo.

export type EstadoFuente = 'OK' | 'WARN' | 'CRIT' | 'UNKNOWN' | 'MANT';
export type Naturaleza = 'oportunidad' | 'riesgo' | 'mixta';
export type Etapa = 'detectada' | 'en_analisis' | 'en_verificacion' | 'confirmada' | 'publicada' | 'descartada';
export type Prioridad = 'alta' | 'media' | 'baja';
export type Rol = 'visor' | 'analista' | 'admin';
export type VistaId = 'direccion' | 'panorama' | 'mapa' | 'fuentes' | 'senales' | 'oportunidades' | 'internacional' | 'analisis' | 'bitacora';
export type CategoriaId =
  | 'clima' | 'salud' | 'vial' | 'seguridad' | 'conectividad'
  | 'eventos' | 'financiacion' | 'mercado' | 'economia' | 'normativa' | 'turismo';

/** Fuente tal como la devuelve vigilante.fuentes_web() (db/generico/06, 07 y 08) */
export interface FuenteBd {
  codigo: string; nombre: string; url: string; tipo: string; metodo: string; categorias: string[];
  frecuencia_minutos: number; activa: boolean; ultima_consulta_en: string | null; que_buscar: string | null; alta_por: string | null;
  /** desde 07_eliminar_fuentes.sql */
  eliminada?: boolean;
  /** desde 08_editar_fuentes.sql */
  palabras_clave?: string[]; creada_en?: string | null; editada_por?: string | null; editada_en?: string | null;
  /** desde 09_fuentes_seguridad.sql */
  propuesta?: boolean; errores_seguidos?: number; ultimo_exito_en?: string | null; ultimo_error?: string | null;
  /** desde 10_fuentes_bitacora.sql */
  reconocida_por?: string | null; reconocida_en?: string | null; reconocida_nota?: string | null;
  /** desde 11_fuentes_revision.sql */
  revision_pedida_en?: string | null; revision_pedida_por?: string | null;
  /** desde 47_fuentes_avia_directas.sql: quién la puso y, si la encontró AVIA, por qué */
  origen?: 'usuario' | 'avia'; motivo_avia?: string | null;
  /** desde 12_fuentes_repetidas.sql: código de la fuente con la que se juntó */
  fusionada_en?: string | null;
}

export interface Fuente {
  id: string;
  nombre: string;
  /** categoría normalizada; si no se reconoce, el texto original */
  canal: CategoriaId | string;
  tipo: string;
  url: string;
  metodo: string;
  /** minutos entre comprobaciones (desconocido en los datos del VPS) */
  freq?: number;
  estado: EstadoFuente;
  info: string;
  /** tiempo de respuesta en ms */
  lat: number | null;
  items: number;
  /** minutos en el estado actual (desconocido en los datos del VPS) */
  desde?: number;
  /** últimas 24 comprobaciones, la más reciente al final */
  hist: EstadoFuente[];
  verif: string;
  flap?: boolean;
  ack?: boolean;
  /** la fuente está en la base de datos (se puede pausar desde la web) */
  enBd?: boolean;
  /** lo que guarda la base de datos sobre la fuente (para verla y editarla) */
  bd?: FuenteBd;
  /** usuario = la puso una persona (o el catálogo inicial); avia = la encontró AVIA y se añadió sola */
  origen?: 'usuario' | 'avia';
  /** dada de alta hace tiempo y AVIA todavía no la ha comprobado nunca */
  sinLeer?: boolean;
  /** minutos desde la última comprobación */
  last?: number;
}

export interface Solucion { t: string; d: string }

export interface Enlace { nombre: string; url: string; fecha?: string }

export interface CambioEtapa { de: Etapa; a: Etapa; quien: string; cuando: string; nota: string }

/** Tres puntuaciones separadas (db/generico/22_puntuaciones.sql) */
export interface Puntuaciones {
  /** respaldo de la evidencia, 0-100, calculado por la base */
  fiabilidad: { valor: number; nivel: 'alta' | 'media' | 'baja'; motivos: string[]; noticias: number; fuentes: number; oficial: boolean; avia?: string | null };
  /** 0-1 solo si el modelo la justificó; si no, valor null y nivel «sin datos».
   *  Desde el 33, en las confirmadas: probabilidad de ocurrencia (origen «base» = cálculo de la base,
   *  «avia» = ajustada por AVIA) y su razón en «justificacion». */
  probabilidad: {
    valor: number | null; nivel: 'alta' | 'media' | 'baja' | 'sin datos'; justificacion: string;
    origen?: 'base' | 'avia'; base?: number | null; calculada_en?: string | null;
    /** por qué, según AVIA: lo que va tras «porque» (36) */
    avia?: string | null;
  };
  /** impacto turístico con su motivo */
  impacto: { nivel: 'alto' | 'medio' | 'bajo' | 'sin datos'; motivo: string; origen: 'modelo' | 'relevancia' | 'prioridad' | 'ninguno'; avia?: string | null };
}

/** Grado de certeza (db/generico/24_grado_certeza.sql) */
export type NivelCerteza = 'confirmado' | 'convocado' | 'posible' | 'rumor';
export interface Certeza {
  nivel: NivelCerteza;
  motivo: string;
  /** quién lo decidió: una persona, el modelo, el modelo corregido por la base o las reglas */
  origen: 'persona' | 'modelo' | 'modelo_ajustado' | 'reglas';
  /** lo que propuso el modelo cuando la base lo bajó */
  propuesto?: NivelCerteza;
}

/** Recomendación segura (db/generico/25_recomendaciones_seguras.sql) */
export interface RecomendacionSegura {
  /** la recomendación; empieza por «Sin confirmar:» si afirma algo sin verificar */
  texto?: string;
  /** texto original cuando se marcó como sin confirmar */
  original?: string;
  para_quien?: string;
  /** con quién comprobarlo según el tema */
  verificar_con: string;
  /** lo que hay que saber antes de actuar */
  falta_saber: string[];
  /** da algo por habilitado/operativo/seguro sin dato oficial ni persona en las últimas 24 h */
  afirma_sin_verificar: boolean;
  aviso?: string;
  /** hora del último dato oficial */
  dato_oficial?: string;
}

/** Síntesis del día en 3 bloques (db/generico/26_sintesis_dia.sql) */
export interface ItemSintesis {
  codigo?: string;
  titulo?: string;
  texto?: string;
  /** solo en «qué pasa» */
  certeza?: NivelCerteza;
  naturaleza?: Naturaleza;
  lugares?: string;
  impacto?: string;
  motivo?: string;
  para_quien?: string;
  /** solo en «qué vigilar» */
  tipo?: 'sin_confirmar' | 'convocado' | 'plazo' | 'recomendacion_sin_verificar' | 'revision_vencida' | 'fuentes';
}
export interface SintesisDia {
  generado?: string;
  /** una línea con los totales (los mismos contadores del panel) */
  totales: string;
  que_pasa: ItemSintesis[];
  por_que_importa: ItemSintesis[];
  que_vigilar: ItemSintesis[];
  /** aviso aparte, encima de todo (db/generico/45_aviso_revisiones_vencidas.sql) */
  revisiones_vencidas?: RevisionesVencidas;
}

/** Señales a las que se les pasó el plazo de revisión y nadie decidió (45_aviso_revisiones_vencidas.sql) */
export interface RevisionesVencidas {
  total: number;
  /** las más antiguas primero (hasta 5) */
  senales: { codigo: string; titulo: string; desde?: string | null }[];
  /** quien responde: el asignado por el administrador o los analistas activos; null si no hay nadie */
  responsable: string | null;
  responsable_origen?: 'asignado' | 'analistas' | null;
}

/** Cambios desde ayer (db/generico/27_comparacion_dia.sql) */
export interface ComparacionDia {
  generado?: string;
  /** false = aún no hay 24 h de registro de certezas: subieron/bajaron van vacías */
  comparable?: boolean;
  conteos: { nuevas: number; subieron: number; bajaron: number; resueltas: number };
  senales_nuevas: { codigo: string; titulo: string; certeza?: NivelCerteza; naturaleza?: Naturaleza }[];
  subieron_certeza: { codigo: string; titulo: string; antes: NivelCerteza; ahora: NivelCerteza }[];
  bajaron_certeza: { codigo: string; titulo: string; antes: NivelCerteza; ahora: NivelCerteza }[];
  resueltas: { codigo: string; titulo: string; como: 'cerrada' | 'descartada' | 'terminada' }[];
}

/** El Pulso de un día (db/generico/46_pulso_evolucion.sql) */
export interface PulsoDia {
  dia: string;
  riesgo: number;
  oportunidad: number;
  vigilancia: 'Normal' | 'Vigilancia' | 'Atención' | 'Crítico';
  activas?: number; riesgos?: number; oportunidades?: number;
  /** true = calculado después con el historial de las señales (la prioridad y la fiabilidad son las de hoy) */
  reconstruido?: boolean;
}

/** Evolución del Pulso a 7 y 30 días (db/generico/46_pulso_evolucion.sql) */
export interface PulsoEvolucion {
  hoy?: PulsoDia | null;
  /** null = ese día aún no había señales: sin datos */
  hace_7: PulsoDia | null;
  hace_30: PulsoDia | null;
  /** primer día con señales */
  desde?: string | null;
  /** desde qué día el valor se guarda en el momento (antes, reconstruido) */
  registro_desde?: string | null;
  umbral_estable?: number;
  serie?: { dia: string; riesgo: number; oportunidad: number; reconstruido?: boolean }[];
}

/** Trazabilidad mínima (db/generico/23_trazabilidad.sql) */
export interface Trazabilidad {
  /** cuándo AVIA creó la señal */
  detectada: string | null;
  /** noticias que la sostienen: la oficial primero */
  fuentes: { nombre: string; tipo?: string; oficial?: boolean; url?: string; titulo?: string;
    /** fecha que da la fuente; ausente si no la da */
    publicada?: string; recogida?: string;
    /** vigilante.json antiguo: una sola fecha sin saber de qué */
    fecha?: string; nota?: string }[];
  noticias: number;
  primera_publicacion?: string | null;
  ultima_noticia?: string | null;
  /** última vez que AVIA volvió a leer alguna de esas fuentes */
  fuente_comprobada?: string | null;
  /** última decisión de una persona; null = sin verificar por una persona */
  ultima_verificacion: { cuando: string | null; cuandoTexto?: string; quien: string; estado: string } | null;
}

export interface Senal {
  id: string;
  titulo: string;
  resumen: string;
  naturaleza: Naturaleza;
  categoria: CategoriaId;
  deps: string[];
  destinos: string[];
  estado: Etapa;
  prioridad: Prioridad;
  /** relevancia 0-10 */
  rel: number;
  /** novedad 0-10 */
  nov: number;
  /** confianza 0-1 */
  conf: number;
  fuentes: string[];
  /** número de fuentes que corroboran */
  corr: number;
  /** minutos desde la detección */
  min: number;
  /** minutos que quedan para revisar (SLA) */
  sla?: number | null;
  /** el plazo de revisión ya venció y nadie decidió */
  revisionVencida?: boolean;
  /** predicción: se etiqueta como escenario y no se publica */
  escenario?: boolean;
  /** días que faltan para el cierre, contados al mirar (lib/plazo.ts): 0 hoy, negativo si ya cerró */
  plazo?: number | null;
  /** fecha de cierre guardada (AAAA-MM-DD) y la certeza del PLAZO, aparte de la del evento (SQL 48) */
  cierre?: { fecha: string; certeza: 'confirmado' | 'pendiente de verificar'; motivo?: string };
  tipoOpp?: string;
  actores?: string[];
  importancia: string;
  soluciones: Solucion[];
  historial?: CambioEtapa[];
  /** evidencia publicada por Hermes (datos del VPS) */
  enlaces?: Enlace[];
  /** próxima revisión prevista, AAAA-MM-DD */
  revision?: string;
  /** fuente, enlace, fechas y última verificación (desde el 23) */
  traza?: Trazabilidad;
  /** fiabilidad, probabilidad e impacto (desde el 22) */
  puntos?: Puntuaciones;
  /** confirmado / convocado / posible / rumor (desde el 24) */
  certeza?: Certeza;
  /** qué hacer, para quién, con quién verificar y qué falta saber (desde el 25) */
  reco?: RecomendacionSegura;
  /** última actualización de la señal en texto */
  actualizacion?: string;
  /** fechas del evento (desde el 19), AAAA-MM-DD: para «Lo que viene» */
  evento?: { inicio?: string | null; fin?: string | null };
  /** eje, acción y ficha para la Dirección, calculados por la base (49) */
  direccion?: { eje: EjeDireccion | null; accion?: 'actuar' | 'preparar' | 'seguir'; ficha?: FichaAccion };
}

/** Los tres ejes de la premisa (db/generico/49_vista_direccion.sql) */
export type EjeDireccion = 'movilidad' | 'servicios' | 'atencion';

/** Ficha fija para la Dirección: Acción recomendada · Responsable sugerido · Plazo · Cómo verificar (49) */
export interface FichaAccion {
  accion: string;
  responsable: string;
  /** a quién afecta, si AVIA lo dice */
  afecta?: string;
  plazo: string;
  /** AAAA-MM-DD del plazo, para ordenar; null = sin fecha */
  plazo_fecha: string | null;
  verificar: string;
  /** la recomendación daba algo por bueno sin dato oficial reciente: la acción es comprobar primero */
  sin_verificar?: boolean;
}

export interface Tema { t: string; n: number; d: number; nat: Naturaleza }

export interface Serie { labels: string[]; det: number[]; opp: number[]; risk: number[] }

export type TipoEvento = EstadoFuente | 'spark' | 'check';
export interface Evento {
  /** minutos respecto a ahora (negativo = pasado) */
  t: number;
  k: TipoEvento;
  w: string;
  d: string;
}

export type PanelId =
  | 'sintesis' | 'pulso' | 'fuentes' | 'cadena' | 'oportunidades' | 'riesgos'
  | 'mapa' | 'evolucion' | 'decision' | 'actividad' | 'temas' | 'categorias' | 'valoracion';

export interface PanelDef { t: string; i: string; d: string; w: number }
export interface PanelEnTablero { id: PanelId; w: number }

export interface Preset { n: string; l: [PanelId, number][] }

export type TipoAnalisis = 'panorama' | 'destino' | 'cruce' | 'foda' | 'noticia' | 'libre';

/** Resultado de evaluar una noticia (IA o reglas locales) */
export interface Evaluacion {
  naturaleza: Naturaleza;
  categoria: string;
  departamentos: string[];
  destinos?: string[];
  relevancia: number;
  novedad: number;
  confianza: number;
  titulo: string;
  importancia: string;
  acciones: string[];
  verificar?: string;
}
