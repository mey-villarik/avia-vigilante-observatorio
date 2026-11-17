// Glosario único del observatorio (mejora 2 de la PoC). Panel, web pública, AVIA (avia_api.py)
// y la skill de Hermes usan estas cuatro palabras con este significado y no otro.
// Si cambias una definición, cámbiala también en docs/glosario.md y en GLOSARIO de avia_api.py.

export type Termino = 'noticia' | 'senal' | 'alerta' | 'recomendacion';

export interface DefTermino { t: string; plural: string; def: string; ejemplo: string; noEs: string }

export const GLOSARIO: Record<Termino, DefTermino> = {
  noticia: {
    t: 'Noticia', plural: 'Noticias',
    def: 'Lo que publica una fuente, tal cual llega: una nota de prensa, un comunicado oficial, una norma, una convocatoria. AVIA la recoge y la guarda con su enlace y su fecha.',
    ejemplo: 'Comunicado del SENAMHI con aviso naranja por lluvias en los Yungas.',
    noEs: 'No es todavía una conclusión: una noticia sola puede ser parcial o falsa.',
  },
  senal: {
    t: 'Señal', plural: 'Señales',
    def: 'Un hecho que importa al turismo, armado por AVIA a partir de una o varias noticias sobre lo mismo. Tiene naturaleza (oportunidad, riesgo o mixta), territorio y etapa: detectada, en análisis, en verificación, confirmada, publicada o descartada.',
    ejemplo: 'Lluvias fuertes en Yungas y Rurrenabaque que pueden cortar rutas (3 noticias).',
    noEs: 'No es una alerta: casi todas las señales se quedan en el panel del equipo.',
  },
  alerta: {
    t: 'Alerta', plural: 'Alertas',
    def: 'Una señal que una persona del equipo confirmó y publicó en la web pública o en Telegram. Puede ser un riesgo o una oportunidad.',
    ejemplo: 'Alerta publicada: «Lluvias en Yungas: consulte la transitabilidad antes de viajar».',
    noEs: 'No hay alerta sin aprobación de una persona; una predicción (escenario) nunca es alerta.',
  },
  recomendacion: {
    t: 'Recomendación', plural: 'Recomendaciones',
    def: 'Lo que AVIA propone hacer ante una señal: una acción concreta, para quién y qué falta comprobar antes de actuar.',
    ejemplo: 'Avisar a operadores de Rurrenabaque y confirmar con la ABC el estado de la ruta antes de recomendarla.',
    noEs: 'No es una orden ni un hecho: la decide una persona.',
  },
};

export const TERMINOS = Object.keys(GLOSARIO) as Termino[];
