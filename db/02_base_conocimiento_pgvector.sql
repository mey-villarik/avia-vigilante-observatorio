-- =============================================================================
-- ORBITA · Migración 02 (opcional): base de conocimiento con pgvector
-- Para que Hermes Agent consulte documentos de referencia (planes de turismo,
-- fichas de destinos, normativa, alertas pasadas) por similitud semántica.
--
-- Requiere 01_orbita_schema.sql y la extensión pgvector
--   (Supabase: Database → Extensions → vector; Postgres propio: paquete postgresql-16-pgvector).
-- La dimensión 1536 corresponde a modelos de embeddings como text-embedding-3-small.
-- Si usas otro modelo, cambia vector(1536) en las dos tablas y en la función.
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

SET search_path = orbita, public;

CREATE TABLE orbita.kb_documents (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  titulo        text NOT NULL,
  tipo          text NOT NULL CHECK (tipo IN ('plan', 'normativa', 'destino', 'informe', 'alerta_historica', 'otro')),
  url           text,
  source_id     smallint REFERENCES orbita.sources(id) ON DELETE SET NULL,
  signal_id     bigint   REFERENCES orbita.signals(id) ON DELETE SET NULL,   -- si viene de una alerta pasada
  departamento_ids smallint[] NOT NULL DEFAULT '{}',
  categorias    text[] NOT NULL DEFAULT '{}',
  fecha_documento date,
  content_hash  text UNIQUE,
  metadatos     jsonb NOT NULL DEFAULT '{}',
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orbita.kb_chunks (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  document_id  bigint NOT NULL REFERENCES orbita.kb_documents(id) ON DELETE CASCADE,
  orden        integer NOT NULL,
  contenido    text NOT NULL,
  tokens       integer,
  embedding    public.vector(1536),
  modelo_embedding text,
  busqueda     tsvector GENERATED ALWAYS AS (to_tsvector('spanish', contenido)) STORED,
  UNIQUE (document_id, orden)
);
CREATE INDEX kb_chunks_embedding_idx ON orbita.kb_chunks USING hnsw (embedding public.vector_cosine_ops);
CREATE INDEX kb_chunks_busqueda_idx  ON orbita.kb_chunks USING gin (busqueda);

-- Búsqueda semántica con filtros opcionales por categoría y departamento
CREATE FUNCTION orbita.buscar_conocimiento(
  p_embedding     public.vector(1536),
  p_limite        int DEFAULT 8,
  p_categoria     text DEFAULT NULL,
  p_departamento  smallint DEFAULT NULL
)
RETURNS TABLE (chunk_id bigint, document_id bigint, titulo text, url text, contenido text, similitud float8)
LANGUAGE sql STABLE AS $$
  SELECT c.id, d.id, d.titulo, d.url, c.contenido,
         1 - (c.embedding OPERATOR(public.<=>) p_embedding) AS similitud
    FROM orbita.kb_chunks c JOIN orbita.kb_documents d ON d.id = c.document_id
   WHERE c.embedding IS NOT NULL
     AND (p_categoria IS NULL OR p_categoria = ANY (d.categorias))
     AND (p_departamento IS NULL OR p_departamento = ANY (d.departamento_ids) OR d.departamento_ids = '{}')
   ORDER BY c.embedding OPERATOR(public.<=>) p_embedding
   LIMIT p_limite
$$;

ALTER TABLE orbita.kb_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE orbita.kb_chunks    ENABLE ROW LEVEL SECURITY;
GRANT ALL ON orbita.kb_documents, orbita.kb_chunks TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON orbita.kb_documents, orbita.kb_chunks TO authenticated;
CREATE POLICY staff_todo ON orbita.kb_documents FOR ALL TO authenticated USING (orbita.es_staff()) WITH CHECK (orbita.es_staff());
CREATE POLICY staff_todo ON orbita.kb_chunks    FOR ALL TO authenticated USING (orbita.es_staff()) WITH CHECK (orbita.es_staff());

COMMIT;
