// Tipos del dominio del Vigilante. Siguen las columnas del esquema `vigilante` de la base
// (db/migrations) para que el paso de datos de ejemplo a Supabase sea directo.

export type EstadoFuente = 'OK' | 'WARN' | 'CRIT' | 'UNKNOWN' | 'MANT';
export type Naturaleza = 'oportunidad' | 'riesgo' | 'mixta';
export type Etapa = 'detectada' | 'en_analisis' | 'en_verificacion' | 'confirmada' | 'publicada' | 'descartada';
export type Prioridad = 'alta' | 'media' | 'baja';
export type Rol = 'visor' | 'analista' | 'admin';
export type VistaId = 'panorama' | 'fuentes' | 'senales' | 'oportunidades' | 'analisis' | 'bitacora';
export type CategoriaId =
  | 'clima' | 'salud' | 'vial' | 'seguridad' | 'conectividad'
  | 'eventos' | 'financiacion' | 'mercado' | 'normativa' | 'turismo';

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
  /** dada de alta hace tiempo y AVIA todavía no la ha comprobado nunca */
  sinLeer?: boolean;
  /** minutos desde la última comprobación */
  last?: number;
}

export interface Solucion { t: string; d: string }

export interface Enlace { nombre: string; url: string; fecha?: string }

export interface CambioEtapa { de: Etapa; a: Etapa; quien: string; cuando: string; nota: string }

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
  /** días para actuar */
  plazo?: number | null;
  tipoOpp?: string;
  actores?: string[];
  importancia: string;
  soluciones: Solucion[];
  historial?: CambioEtapa[];
  /** evidencia publicada por Hermes (datos del VPS) */
  enlaces?: Enlace[];
  /** próxima revisión prevista, AAAA-MM-DD */
  revision?: string;
  /** última actualización de la señal en texto */
  actualizacion?: string;
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
