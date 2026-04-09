-- ============================================================================
-- LOOVE OS RAG Pipeline: pgvector Embeddings + Semantic Search
-- ============================================================================
-- Purpose: Adds vector embedding support to vault_files for Karpathy-style
--          semantic search across the entire knowledge base.
--
-- Status: DESIGNED, NOT YET DEPLOYED
-- Requires: vault_files table, pgvector extension, OpenAI API key
-- Dependencies: Translation layer triggers must be deployed first
--
-- Architecture:
--   1. pgvector extension + embedding column on vault_files
--   2. pgmq queue for async embedding generation
--   3. Edge Function that processes the queue (calls OpenAI embeddings API)
--   4. Semantic search function for tRPC / claw consumption
-- ============================================================================

-- ── Step 1: Enable pgvector ─────────────────────────────────────────────────
-- Supabase projects have pgvector available but it needs to be enabled.

CREATE EXTENSION IF NOT EXISTS vector;

-- ── Step 2: Add embedding column to vault_files ─────────────────────────────
-- Using 1536 dimensions (OpenAI text-embedding-3-small)
-- Only add if not already present

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'vault_files' AND column_name = 'embedding'
  ) THEN
    ALTER TABLE vault_files ADD COLUMN embedding vector(1536);
  END IF;
END $$;

-- Add a column to track when embedding was last generated
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'vault_files' AND column_name = 'embedding_updated_at'
  ) THEN
    ALTER TABLE vault_files ADD COLUMN embedding_updated_at timestamptz;
  END IF;
END $$;

-- ── Step 3: Create HNSW index for fast similarity search ────────────────────
-- HNSW provides better recall than IVFFlat and doesn't require training data.
-- Good default for our scale (~3,500-6,000 rows).

DROP INDEX IF EXISTS idx_vault_files_embedding_hnsw;
CREATE INDEX IF NOT EXISTS idx_vault_files_embedding_hnsw ON vault_files
  USING hnsw (embedding vector_cosine_ops);

-- ── Step 4: Embedding queue table ───────────────────────────────────────────
-- Simple queue table that an Edge Function polls for pending embedding jobs.

CREATE TABLE IF NOT EXISTS vault_embedding_queue (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vault_file_id text NOT NULL REFERENCES vault_files(id) ON DELETE CASCADE,
  action text NOT NULL DEFAULT 'embed',  -- 'embed' or 'delete'
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  error text
);

CREATE INDEX IF NOT EXISTS idx_embedding_queue_unprocessed
  ON vault_embedding_queue (created_at)
  WHERE processed_at IS NULL;

-- ── Step 5: Trigger to enqueue embedding jobs ───────────────────────────────
-- Fires when vault_files content changes, queues an embedding job.

CREATE OR REPLACE FUNCTION loove_enqueue_embedding()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    INSERT INTO vault_embedding_queue (vault_file_id, action)
      VALUES (OLD.id, 'delete')
      ON CONFLICT DO NOTHING;
    RETURN OLD;
  END IF;

  -- Only enqueue if content actually changed (or is new)
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.content IS DISTINCT FROM NEW.content) THEN
    IF NEW.is_binary = true THEN RETURN NEW; END IF;
    IF NEW.deleted = true THEN RETURN NEW; END IF;

    INSERT INTO vault_embedding_queue (vault_file_id, action)
      VALUES (NEW.id, 'embed');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_embedding ON vault_files;
CREATE TRIGGER trg_enqueue_embedding
  AFTER INSERT OR UPDATE OR DELETE ON vault_files
  FOR EACH ROW EXECUTE FUNCTION loove_enqueue_embedding();

-- ── Step 6: Semantic search function ────────────────────────────────────────
-- Primary query interface for claws, tRPC, and Edge Functions.
-- Takes a pre-computed query embedding and returns most similar notes.

CREATE OR REPLACE FUNCTION loove_semantic_search(
  query_embedding vector(1536),
  match_threshold float DEFAULT 0.7,
  match_count int DEFAULT 10,
  filter_vault_id text DEFAULT NULL,
  filter_tags text[] DEFAULT NULL
)
RETURNS TABLE (
  id text,
  vault_id text,
  path text,
  title text,
  content text,
  tags text[],
  frontmatter jsonb,
  similarity float
)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  SELECT
    vf.id,
    vf.vault_id,
    vf.path,
    vf.frontmatter->>'title' AS title,
    vf.content,
    vf.tags,
    vf.frontmatter,
    1 - (vf.embedding <=> query_embedding) AS similarity
  FROM vault_files vf
  WHERE
    vf.deleted = false
    AND vf.embedding IS NOT NULL
    AND 1 - (vf.embedding <=> query_embedding) > match_threshold
    AND (filter_vault_id IS NULL OR vf.vault_id = filter_vault_id)
    AND (filter_tags IS NULL OR vf.tags && filter_tags)
  ORDER BY vf.embedding <=> query_embedding
  LIMIT match_count;
END;
$$;

-- ── Step 7: Text search fallback ────────────────────────────────────────────
-- Full-text search for when embeddings aren't available or as a complement.

CREATE OR REPLACE FUNCTION loove_text_search(
  query_text text,
  match_count int DEFAULT 10,
  filter_vault_id text DEFAULT NULL,
  filter_tags text[] DEFAULT NULL
)
RETURNS TABLE (
  id text,
  vault_id text,
  path text,
  title text,
  content_snippet text,
  tags text[],
  rank float
)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  SELECT
    vf.id,
    vf.vault_id,
    vf.path,
    vf.frontmatter->>'title' AS title,
    left(vf.content, 500) AS content_snippet,
    vf.tags,
    ts_rank_cd(
      to_tsvector('english', COALESCE(vf.frontmatter->>'title', '') || ' ' || COALESCE(vf.content, '')),
      plainto_tsquery('english', query_text)
    ) AS rank
  FROM vault_files vf
  WHERE
    vf.deleted = false
    AND to_tsvector('english', COALESCE(vf.frontmatter->>'title', '') || ' ' || COALESCE(vf.content, ''))
        @@ plainto_tsquery('english', query_text)
    AND (filter_vault_id IS NULL OR vf.vault_id = filter_vault_id)
    AND (filter_tags IS NULL OR vf.tags && filter_tags)
  ORDER BY rank DESC
  LIMIT match_count;
END;
$$;

-- ── Step 8: Full-text search GIN index ──────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_vault_files_fts ON vault_files
  USING gin (to_tsvector('english', COALESCE(frontmatter->>'title', '') || ' ' || COALESCE(content, '')));

-- ── Step 9: Stats view ──────────────────────────────────────────────────────

CREATE OR REPLACE VIEW loove_embedding_stats AS
SELECT
  vault_id,
  count(*) AS total_files,
  count(embedding) AS embedded_files,
  count(*) - count(embedding) AS pending_files,
  round(100.0 * count(embedding) / GREATEST(count(*), 1), 1) AS coverage_pct,
  max(embedding_updated_at) AS last_embedding_at
FROM vault_files
WHERE deleted = false
GROUP BY vault_id;

-- ============================================================================
-- EDGE FUNCTION SPEC: process-embedding-queue
-- ============================================================================
-- Deploy as Supabase Edge Function, triggered by cron (every 60s) or webhook.
--
-- Algorithm:
--   1. SELECT * FROM vault_embedding_queue WHERE processed_at IS NULL
--      ORDER BY created_at LIMIT 50
--   2. For each job:
--      a. action='delete': UPDATE vault_files SET embedding=NULL
--      b. action='embed':
--         - Fetch content from vault_files
--         - Call OpenAI text-embedding-3-small
--         - UPDATE vault_files SET embedding=<vec>, embedding_updated_at=now()
--   3. UPDATE vault_embedding_queue SET processed_at=now() WHERE id IN (...)
--
-- Cost at ~3,500 notes: ~$0.035 for initial backfill (negligible ongoing)
-- ============================================================================
