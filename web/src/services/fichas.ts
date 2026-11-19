// Ficha de aprobación de riesgos (db/generico/32_ficha_aprobacion.sql, skill avia-ficha-aprobacion).
// Antes de publicar un riesgo, AVIA resume en seis líneas qué afirma, qué lo sostiene y cuánto pesa,
// qué falta, el riesgo U1-U4, si conviene publicar y cómo contarlo. Solo analistas y administradores.
import { useEffect, useState } from 'react';
import { supabase, traducir } from './auth';

export type Sugerencia = 'publicar' | 'esperar' | 'no_publicar';
export type NivelRiesgo = 'U1' | 'U2' | 'U3' | 'U4';

export interface NoticiaCitada { id: number; titulo: string; url?: string; fuente: string; peso_max: number }

export interface FichaAprobacion {
  senal: string;
  /** AVIA aún no la ha preparado (o la está rehaciendo por primera vez) */
  preparando?: boolean;
  afirmacion?: string;
  evidencia?: { noticias: number[]; peso: number; peso_max: number; por_que: string };
  falta?: string[];
  riesgo?: { nivel: NivelRiesgo; motivo: string };
  sugerencia?: { decision: Sugerencia; motivo: string };
  texto_prudente?: string;
  verificar_con?: string;
  preparada_en?: string;
  version?: number;
  /** llegaron noticias nuevas después de la ficha: AVIA la está rehaciendo */
  desactualizada?: boolean;
  noticias_citadas?: NoticiaCitada[];
}

export const SUGERENCIA_TXT: Record<Sugerencia, string> = {
  publicar: 'Publicar',
  esperar: 'Esperar',
  no_publicar: 'No publicar',
};

export const RIESGO_TXT: Record<NivelRiesgo, string> = {
  U1: 'U1 · molestia menor',
  U2: 'U2 · afecta planes',
  U3: 'U3 · cancelaciones o gente varada',
  U4: 'U4 · vida, salud o daño grave',
};

/** Lee la ficha de una señal. null = no lleva ficha, o falta el 32 en la base. */
export async function leerFicha(codigo: string): Promise<FichaAprobacion | null> {
  if (!supabase) return null;
  const { data, error } = await supabase.schema('vigilante').rpc('ficha_aprobacion', { p_codigo: codigo });
  if (error) {
    if (/ficha_aprobacion/.test(error.message) && /(not find|no existe|does not exist|schema cache)/i.test(error.message)) return null;
    throw new Error(traducir(error.message));
  }
  return (data as FichaAprobacion | null) ?? null;
}

/** Ficha de una señal, pedida al abrirla y cada minuto mientras se prepara. */
export function useFicha(codigo: string, activa: boolean) {
  const [ficha, setFicha] = useState<FichaAprobacion | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!activa || !supabase) return;
    let vivo = true;
    let t: ReturnType<typeof setTimeout> | undefined;
    const pedir = async () => {
      try {
        const f = await leerFicha(codigo);
        if (!vivo) return;
        setFicha(f); setError(null);
        if (f && (f.preparando || f.desactualizada)) t = setTimeout(pedir, 60 * 1000);
      } catch (e) {
        if (vivo) setError((e as Error).message);
      }
    };
    void pedir();
    return () => { vivo = false; if (t) clearTimeout(t); };
  }, [codigo, activa]);
  return { ficha, error };
}
