// Categorías en la web pública: un solo código por categoría y siempre un nombre legible.
// Misma regla que la base (db/generico/42_categorias_correctas.sql → categoria_canonica y
// categoria_nombre_defecto): «financiacion» es «financiamiento», «mercado» es «mercados», y si el
// catálogo no trae nombre (o trae el propio código, como «financiacion») se usa el de esta lista.

const ALIAS: Record<string, string> = {
  financiacion: 'financiamiento', 'financiación': 'financiamiento',
  mercado: 'mercados', economia: 'mercados', 'economía': 'mercados',
};

const NOMBRES: Record<string, string> = {
  clima: 'Clima y desastres',
  salud: 'Salud y epidemiología',
  vial: 'Vías y transporte terrestre',
  seguridad: 'Seguridad del visitante',
  conectividad: 'Conectividad aérea',
  eventos: 'Eventos y festividades',
  financiamiento: 'Financiación y convocatorias',
  mercados: 'Mercados y normativa',
  normativa: 'Normativa',
  turismo: 'Turismo',
};

export function categoriaCanonica(codigo: string | null | undefined): string {
  const c = (codigo ?? '').trim().toLowerCase();
  return ALIAS[c] ?? c;
}

/** ¿Es un código interno y no un nombre para personas? (minúsculas y guiones bajos, sin espacios) */
const esCodigo = (s: string) => /^[a-z_]+$/.test(s.trim());

export function nombreCategoria(codigo: string | null | undefined, nombre?: string | null): string {
  if (nombre && nombre.trim() && !esCodigo(nombre)) return nombre.trim();
  const c = categoriaCanonica(codigo);
  if (NOMBRES[c]) return NOMBRES[c];
  if (!c) return 'Sin categoría';
  const t = c.replace(/_/g, ' ');
  return t.charAt(0).toUpperCase() + t.slice(1);
}
