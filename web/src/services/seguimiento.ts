// Guarda en la base el estado de una recomendación (db/generico/50_seguimiento_recomendaciones.sql).
// Solo analistas y administradores; la base lo vuelve a comprobar.
import type { EstadoSeguimiento, Seguimiento } from '../types';
import { supabase, traducir } from './auth';

export async function seguirRecomendacion(codigo: string, estado: EstadoSeguimiento, nota?: string): Promise<Seguimiento> {
  if (!supabase) throw new Error('El acceso no está configurado.');
  const { data, error } = await supabase.schema('vigilante').rpc('seguir_recomendacion', {
    p_codigo: codigo, p_estado: estado, p_nota: nota?.trim() || null,
  });
  if (error) {
    const m = error.message;
    if (/seguir_recomendacion/.test(m) && /(not find|no existe|does not exist|schema cache)/i.test(m)) {
      throw new Error('Falta ejecutar 50_seguimiento_recomendaciones.sql en la base.');
    }
    if (/aún no está en la base/.test(m)) throw new Error(`${codigo} aún no está en la base de datos.`);
    throw new Error(traducir(m));
  }
  return data as Seguimiento;
}
