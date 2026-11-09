// Datos de EJEMPLO para ver las pantallas de oportunidades y fuentes candidatas sin conexión.
// Son ficticios: las señales a las que apuntan son las de ejemplo de demo.ts. Las evidencias no llevan
// enlace porque no existen; con datos reales cada una enlaza a la noticia guardada en la base.
import type { Candidata, Oportunidad } from '../services/recolector';

const dia = (n: number) => new Date(Date.now() + n * 86400000).toISOString().slice(0, 10);
const hace = (min: number) => new Date(Date.now() - min * 60000).toISOString();

export const OPORTUNIDADES_DEMO: Oportunidad[] = [
  {
    id: 1, nivel: 'explicita', tipo: 'convocatoria', estado: 'propuesta', senal: 'SEN-0417', importancia: 4,
    hecho: 'Ejemplo: CAF abre un fondo para proyectos de turismo comunitario y sostenible, hasta USD 80 000 por propuesta, con cierre en 12 días.',
    beneficiarios: ['comunidades', 'operadores', 'asociaciones'],
    accion: 'Avisar a las asociaciones de turismo comunitario y ofrecer apoyo para preparar la postulación.',
    plazo_hasta: dia(12), creada_por: 'analizador', creada: hace(95),
    evidencias: [{ id: 101, titulo: 'CAF lanza convocatoria de turismo comunitario (ejemplo)', url: '', fuente: 'CAF' }],
  },
  {
    id: 2, nivel: 'inferida', tipo: 'conectividad', estado: 'propuesta', senal: 'SEN-0413', importancia: 3,
    hecho: 'Ejemplo: una aerolínea anuncia una frecuencia diaria adicional Viru Viru – Lima desde diciembre.',
    interpretacion: 'Operadores y alojamientos de Santa Cruz podrían ofrecer paquetes cortos al viajero que llega desde Lima. No permite afirmar que aumentarán las reservas.',
    beneficiarios: ['operadores', 'alojamientos'],
    accion: 'Contactar a operadores de Santa Cruz para armar una oferta de 2 a 3 días antes de diciembre.',
    plazo_hasta: dia(25), creada_por: 'avia', creada: hace(300),
    evidencias: [
      { id: 102, titulo: 'Nueva frecuencia diaria a Lima (ejemplo)', url: '', fuente: 'Prensa económica' },
      { id: 103, titulo: 'La aerolínea confirma la ruta (ejemplo)', url: '', fuente: 'Nota de la aerolínea' },
    ],
  },
  {
    id: 3, nivel: 'explicita', tipo: 'evento', estado: 'validada', senal: 'SEN-0412', importancia: 3,
    hecho: 'Ejemplo: el Ministerio de Turismo anuncia una feria de turismo y gastronomía en Tarija con rueda de negocios.',
    beneficiarios: ['operadores', 'restaurantes', 'bodegas'],
    accion: 'Inscribir stands antes del cierre de inscripciones.',
    plazo_hasta: dia(18), creada_por: 'analizador', creada: hace(1440),
    evidencias: [{ id: 104, titulo: 'Feria de turismo y gastronomía en Tarija (ejemplo)', url: '', fuente: 'Ministerio de Turismo' }],
  },
];

export const CANDIDATAS_DEMO: Candidata[] = [
  {
    id: 1, nombre: 'Gobernación de Potosí · noticias (ejemplo)', url: 'https://potosi.gob.bo/noticias',
    motivo: 'Ejemplo: publica cortes de ruta y eventos del departamento que hoy solo llegan por la prensa.',
    propuesta_por: 'avia', veces: 3, estado: 'pendiente', propuesta_en: hace(180),
    decidida_por: null, decidida_en: null, nota: null, codigo: null,
    evidencia: [{ id: 105, titulo: 'Anuncio de bloqueo en la ruta Oruro – Potosí (ejemplo)', url: '' }],
  },
  {
    id: 2, nombre: 'Radio local de Uyuni (ejemplo)', url: 'https://radio-uyuni.example/noticias',
    motivo: 'Ejemplo: apareció en una búsqueda; no estaba en el catálogo.',
    propuesta_por: 'sincronizacion', veces: 1, estado: 'pendiente', propuesta_en: hace(60 * 26),
    decidida_por: null, decidida_en: null, nota: null, codigo: null, evidencia: [],
  },
];
