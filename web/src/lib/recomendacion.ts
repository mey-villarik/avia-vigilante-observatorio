// Recomendaciones seguras (mejora 7 de la PoC). La fuente es la base: vigilante.recomendacion_segura()
// en db/generico/25_recomendaciones_seguras.sql. Aquí se repiten las mismas reglas solo para los datos
// de ejemplo y para vigilante.json antiguos que no la traen.
import type { CategoriaId, RecomendacionSegura, Senal } from '../types';
import { certezaDe } from './certeza';
import { trazaDe } from './trazabilidad';

/** Con quién verificar cada tema (mismo texto que el parámetro «verificar_con» de ORBITA) */
export const VERIFICAR_CON: Partial<Record<CategoriaId, string>> & { _: string } = {
  vial: 'la ABC (transitabilidad.abc.gob.bo) o la Policía caminera',
  conectividad: 'la DGAC, NAABOL (aeropuertos) o la aerolínea',
  clima: 'el SENAMHI (avisos vigentes)',
  salud: 'el Ministerio de Salud o el SEDES del departamento',
  seguridad: 'la Policía Boliviana o la gobernación',
  eventos: 'el organizador o la alcaldía',
  financiacion: 'las bases oficiales de la entidad que convoca',
  normativa: 'la Gaceta Oficial de Bolivia',
  mercado: 'la fuente del dato (INE o Viceministerio de Turismo)',
  economia: 'el INE o el Banco Central de Bolivia',
  _: 'la fuente oficial del tema',
};

const NEGACION = /(^|[^\p{L}])(no|ni|nunca) (est[aá]n? |es |son |se |hay |siguen? |quedan? )?[\p{L}]+/giu;
const AFIRMA = new RegExp(
  '(habilitad[oa]s?|operativ[oa]s?|transitables?|expedit[oa]s?|normalidad|restablecid[oa]s?'
  + '|sin (problemas|riesgos?|restricci[oó]n(es)?|novedad(es)?|inconvenientes)'
  + '|(es|son|resulta|está|están) segur[oa]s?|pueden? viajar'
  + '|abiert[oa]s? al (tr[aá]nsito|tr[aá]fico|p[uú]blico|turismo)'
  + '|(ruta|carretera|camino|tramo|vuelo|aeropuerto|paso|frontera)s? (est[aá]n? |siguen? )?(abiert|libre|disponible|funcionando))', 'iu');

/** ¿El texto da algo por habilitado, operativo o seguro? (sin contar las negaciones) */
export const afirmaOperativo = (t?: string) => !!t && AFIRMA.test(t.replace(NEGACION, ' '));

const HORA = 3600_000;

/** La de la base si llegó; si no, las mismas reglas con lo que hay en la señal */
export function recoDe(s: Senal): RecomendacionSegura {
  if (s.reco) return s.reco;
  const texto = s.soluciones[0]?.t;
  const con = VERIFICAR_CON[s.categoria] ?? VERIFICAR_CON._;
  const cert = certezaDe(s).nivel;
  const t = trazaDe(s);
  const oficiales = t.fuentes.filter((f) => f.oficial).map((f) => Date.parse(f.recogida ?? f.publicada ?? '')).filter((n) => !Number.isNaN(n));
  const datoOficial = oficiales.length ? Math.max(...oficiales) : null;
  const persona = t.ultima_verificacion && ['confirmada', 'publicada'].includes(t.ultima_verificacion.estado) && t.ultima_verificacion.cuando
    ? Date.parse(t.ultima_verificacion.cuando) : null;
  const reciente = Math.max(datoOficial ?? 0, persona ?? 0) > Date.now() - 24 * HORA;
  const afirma = afirmaOperativo(texto) && !reciente;
  const falta: string[] = [];
  if (cert === 'posible' || cert === 'rumor') falta.push(`Confirmar que el hecho es cierto con ${con} o una segunda fuente`);
  else if (cert === 'convocado') falta.push('Si se mantiene en la fecha anunciada (puede suspenderse o cambiar)');
  if ((['vial', 'conectividad', 'clima'] as CategoriaId[]).includes(s.categoria) && !reciente) {
    const tema = s.categoria === 'vial' ? 'de la ruta' : s.categoria === 'conectividad' ? 'de vuelos y aeropuertos' : 'del aviso';
    falta.push(`Estado actual ${tema} según ${con}: ${datoOficial ? 'el último dato oficial es de hace más de 24 h' : t.fuentes.some((f) => f.oficial) ? 'la fuente oficial no da la hora del dato' : 'no hay dato oficial'}`);
  }
  if (s.naturaleza !== 'riesgo' && s.plazo == null && (['financiacion', 'eventos'] as CategoriaId[]).includes(s.categoria)) {
    falta.push('Fecha límite: la fuente no la da');
  }
  return {
    texto: texto ? (afirma ? `Sin confirmar: ${texto}` : texto) : undefined,
    original: afirma ? texto : undefined,
    para_quien: s.actores?.join(', ') || undefined,
    verificar_con: con,
    falta_saber: falta,
    afirma_sin_verificar: afirma,
    aviso: afirma ? `La recomendación da algo por habilitado, operativo o seguro, pero ninguna fuente oficial ni persona lo comprobó en las últimas 24 h. Comprobar con ${con} antes de recomendarlo.` : undefined,
    dato_oficial: datoOficial ? new Date(datoOficial).toISOString() : undefined,
  };
}

/** Texto para el chat: qué hacer, para quién, con quién verificar y qué falta saber */
export function recoTexto(s: Senal): string {
  const r = recoDe(s);
  return [
    r.texto ? r.texto.replace(/\.?$/, '.') : 'Sin recomendación todavía.',
    r.para_quien ? `Para: ${r.para_quien}.` : '',
    `Verificar con ${r.verificar_con}.`,
    r.falta_saber.length ? `Falta saber: ${r.falta_saber.join('; ')}.` : '',
  ].filter(Boolean).join(' ');
}

/** Versión corta para listas: si afirma algo sin verificar, solo pide comprobar */
export function recoCorta(s: Senal): string {
  const r = recoDe(s);
  if (r.afirma_sin_verificar) return `comprobar con ${r.verificar_con} antes de recomendar nada (no hay dato oficial reciente)`;
  const t = (r.texto ?? 'revisar la señal').replace(/\.$/, '');
  return `${t[0].toLowerCase()}${t.slice(1)}${r.falta_saber.length ? ` (falta saber: ${r.falta_saber[0].toLowerCase()})` : ''}`;
}
