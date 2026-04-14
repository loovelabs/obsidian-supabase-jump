-- ============================================================================
-- LOOVE OS RAG Pipeline: Automatic Embeddings for vault_files
-- ============================================================================
-- Purpose: Extend vault_files with pgvector embeddings and configure
-- automatic embedding generation using Supabase native queues + cron +
-- Edge Functions.
--
-- Status: DEPLOY-READY (pending credential approval)
-- Requires: vault_files table, translation_layer.sql already deployed
-- Reference: https://supabase.com/docs/guides/ai/automatic-embeddings
--
-- IMPORTANT:
--   This Phase 3 rollout intentionally keeps semantic search scoped to
--   vault_files. Existing LOOVE knowledge tables are not on a verified shared
--   embedding space with gte-small, so cross-table vector UNIONs are unsafe
--   until embeddings are normalized to the same model + dimension.
-- ============================================================================

-- ── Step 1: Enable required extensions ─────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgmq;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ── Step 2: Add embedding column to vault_files ────────────────────────────

ALTER TABLE public.vault_files
  ADD COLUMN IF NOT EXISTS embedding extensions.vector(384);

CREATE INDEX IF NOT EXISTS vault_files_embedding_idx
  ON public.vault_files
  USING ivfflat (embedding extensions.vector_cosine_ops)
  WITH (lists = 100);

-- ── Step 3: Utility schema and functions ───────────────────────────────────

CREATE SCHEMA IF NOT EXISTS util;

CREATE OR REPLACE FUNCTION util.project_url()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT COALESCE(
    (
      SELECT decrypted_secret
      FROM vault.decrypted_secrets
      WHERE name = 'project_url'
      LIMIT 1
    ),
    'https://ewlygzvnvqyvszdpwbww.supabase.co'
  );
$$;

CREATE OR REPLACE FUNCTION util.invoke_edge_function(
  name text,
  body jsonb,
  timeout_milliseconds integer DEFAULT 5 * 60 * 1000
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  headers_raw text;
  auth_header text;
BEGIN
  headers_raw := current_setting('request.headers', true);
  auth_header := CASE
    WHEN headers_raw IS NOT NULL THEN (headers_raw::json ->> 'authorization')
    ELSE NULL
  END;

  PERFORM net.http_post(
    url => util.project_url() || '/functions/v1/' || name,
    headers => jsonb_strip_nulls(jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', auth_header
    )),
    body => body,
    timeout_milliseconds => timeout_milliseconds
  );
END;
$$;

-- ── Step 4: Create embedding queue ─────────────────────────────────────────

DO $$
BEGIN
  PERFORM pgmq.create('embedding_jobs');
EXCEPTION
  WHEN duplicate_table OR duplicate_object THEN NULL;
  WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%already exists%' THEN
      RAISE;
    END IF;
END;
$$;

-- ── Step 5: Trigger to enqueue embedding jobs ──────────────────────────────

CREATE OR REPLACE FUNCTION loove_enqueue_embedding()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.is_binary = true OR NEW.deleted = true OR NEW.content IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.content IS DISTINCT FROM NEW.content THEN
    NEW.embedding := NULL;
  END IF;

  PERFORM pgmq.send(
    'embedding_jobs',
    jsonb_build_object('id', NEW.id)
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_vault_embedding ON public.vault_files;
CREATE TRIGGER trg_enqueue_vault_embedding
  BEFORE INSERT OR UPDATE OF content ON public.vault_files
  FOR EACH ROW
  EXECUTE FUNCTION loove_enqueue_embedding();

-- ── Step 6: Cron job to process embedding queue ────────────────────────────
-- NOTE: deploy the generate-embedding function with JWT verification disabled,
-- because pg_cron invokes it from Postgres without an end-user bearer token.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'process-embedding-queue') THEN
    PERFORM cron.unschedule('process-embedding-queue');
  END IF;
END;
$$;

SELECT cron.schedule(
  'process-embedding-queue',
  '30 seconds',
  $$
  SELECT util.invoke_edge_function(
    'generate-embedding',
    jsonb_build_object(
      'queue', 'embedding_jobs',
      'batch_size', 10,
      'visibility_timeout', 60
    )
  );
  $$
);

-- ── Step 7: Semantic search over vault_files ───────────────────────────────

CREATE OR REPLACE FUNCTION loove_semantic_search(
  p_query_embedding extensions.vector(384),
  p_match_threshold double precision DEFAULT 0.7,
  p_match_count integer DEFAULT 10,
  p_filter_tags text[] DEFAULT NULL,
  p_filter_source_table text DEFAULT NULL
)
RETURNS TABLE (
  id text,
  path text,
  content text,
  similarity double precision,
  tags text[],
  source_table text,
  source_id text,
  frontmatter jsonb
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    vf.id,
    vf.path,
    vf.content,
    1 - (vf.embedding <=> p_query_embedding) AS similarity,
    vf.tags,
    vf.frontmatter ->> 'source_table' AS source_table,
    vf.frontmatter ->> 'source_id' AS source_id,
    vf.frontmatter
  FROM public.vault_files vf
  WHERE vf.deleted = false
    AND vf.embedding IS NOT NULL
    AND 1 - (vf.embedding <=> p_query_embedding) > p_match_threshold
    AND (p_filter_tags IS NULL OR vf.tags && p_filter_tags)
    AND (
      p_filter_source_table IS NULL
      OR vf.frontmatter ->> 'source_table' = p_filter_source_table
    )
  ORDER BY vf.embedding <=> p_query_embedding
  LIMIT p_match_count;
END;
$$;

-- ── Step 8: Stable search wrapper for downstream callers ───────────────────
-- This preserves a higher-level API surface without incorrectly mixing
-- incompatible embedding spaces.

CREATE OR REPLACE FUNCTION loove_unified_search(
  p_query_embedding extensions.vector(384),
  p_match_threshold double precision DEFAULT 0.7,
  p_match_count integer DEFAULT 10
)
RETURNS TABLE (
  source text,
  id text,
  title text,
  content_preview text,
  similarity double precision,
  tags text[],
  metadata jsonb
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    'vault_files'::text AS source,
    vf.id,
    regexp_replace(vf.path, '^.*/', '') AS title,
    left(vf.content, 500) AS content_preview,
    1 - (vf.embedding <=> p_query_embedding) AS similarity,
    vf.tags,
    vf.frontmatter AS metadata
  FROM public.vault_files vf
  WHERE vf.deleted = false
    AND vf.embedding IS NOT NULL
    AND 1 - (vf.embedding <=> p_query_embedding) > p_match_threshold
  ORDER BY vf.embedding <=> p_query_embedding
  LIMIT p_match_count;
END;
$$;
