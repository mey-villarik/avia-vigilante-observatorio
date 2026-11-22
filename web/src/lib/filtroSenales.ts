// Filtro de la vista Señales en un solo sitio (CP3 de Carlos). Lo usan la vista, las flechas de pase
// en bloque y el chat: cuando AVIA dice «abrí Señales con este filtro», la lista de códigos que da
// sale de ESTA función sobre el estado real del panel, no de lo que el modelo cree que hizo.
import type { Naturaleza, Senal } from '../types';
import type { SigFilter } from '../store';
import { DEPS } from '../data/demo';
import { esReciente, norm, porRevisar } from './util';

export function filtrarSenales(senales: Senal[], f: SigFilter): Senal[] {
  const visibles = f.periodo === 'todo' ? senales : senales.filter((s) => esReciente(s));
  return visibles.filter((s) => (!f.revisar || porRevisar(s))
    && (f.nat === 'all' || s.naturaleza === f.nat)
    && (f.dep === 'all' || s.deps.includes(f.dep))
    && (!f.q || norm(`${s.titulo} ${s.resumen} ${s.destinos.join(' ')} ${s.id}`).includes(norm(f.q))));
}

/** Filtro que puede pedir AVIA en la orden «abrir» */
export interface FiltroPedido {
  naturaleza?: string; departamento?: string; texto?: string; revisar?: boolean; periodo?: string;
}

const NATS: Record<string, SigFilter['nat']> = {
  todas: 'all', all: 'all', oportunidad: 'oportunidad', oportunidades: 'oportunidad',
  riesgo: 'riesgo', riesgos: 'riesgo', mixta: 'mixta', mixtas: 'mixta',
};

/** Convierte lo que pidió AVIA en un filtro válido, o dice por qué no se puede aplicar */
export function filtroDesdePedido(p: FiltroPedido): { filtro: SigFilter } | { error: string } {
  const nat = p.naturaleza == null ? 'all' : NATS[norm(p.naturaleza)];
  if (!nat) return { error: `no reconozco la naturaleza «${p.naturaleza}» (oportunidad, riesgo o mixta)` };
  let dep = 'all';
  if (p.departamento && norm(p.departamento) !== 'todos') {
    const d = DEPS.find((x) => norm(x) === norm(p.departamento!));
    if (!d) return { error: `no reconozco el departamento «${p.departamento}»` };
    dep = d;
  }
  const periodo: SigFilter['periodo'] = p.periodo && norm(p.periodo) === 'todo' ? 'todo' : 'recientes';
  return { filtro: { nat: nat as Naturaleza | 'all', dep, q: (p.texto ?? '').trim(), revisar: Boolean(p.revisar), periodo } };
}

const NAT_TXT: Record<SigFilter['nat'], string> = { all: 'todas', oportunidad: 'oportunidades', riesgo: 'riesgos', mixta: 'mixtas' };

/** «riesgos · La Paz · texto "bloqueo"» */
export function filtroTexto(f: SigFilter): string {
  const partes = [NAT_TXT[f.nat]];
  if (f.dep !== 'all') partes.push(f.dep);
  if (f.q) partes.push(`texto «${f.q}»`);
  if (f.revisar) partes.push('solo por revisar');
  partes.push(f.periodo === 'todo' ? 'todo lo guardado' : 'recientes');
  return partes.join(' · ');
}

export const mismoFiltro = (a: SigFilter, b: SigFilter) =>
  a.nat === b.nat && a.dep === b.dep && a.q === b.q && Boolean(a.revisar) === Boolean(b.revisar) && a.periodo === b.periodo;
