-- ============================================================================
-- LOOVE OS Translation Layer: Operational Tables → vault_files
-- ============================================================================
-- Purpose: Postgres triggers and functions that automatically project
--          operational table rows into the vault_files table as markdown
--          documents, enabling SupaBase Jump to sync them to Obsidian.
--
-- Status: DESIGNED, NOT YET DEPLOYED
-- Requires: vault_files table (created by SupaBase Jump plugin on first run)
-- Dependencies: SupaBase Jump schema (main.ts SCHEMA_SQL)
--
-- Row ID Convention:
--   SupaBase Jump uses: {vaultId}::{path_with_slashes_replaced}
--   Path slashes are replaced with __SLASH__
--   Example: abc123::loove__SLASH__shared-context__SLASH__my-note.md
--
-- The translation layer uses a dedicated vault_id ('loove-system') and
-- a service-level user_id to distinguish system-generated notes from
-- user-created notes. This prevents RLS conflicts.
-- ============================================================================

-- ── Configuration ───────────────────────────────────────────────────────────

-- System vault ID for all translation-layer-generated notes.
-- Must match the vault_id configured in the principal's Obsidian plugin
-- OR use a dedicated system vault that the principal subscribes to.
DO $$ BEGIN
  PERFORM set_config('loove.system_vault_id', 'loove-system', false);
END $$;

-- ── Helper: Generate a vault_files row ID ───────────────────────────────────

CREATE OR REPLACE FUNCTION loove_vault_row_id(
  p_vault_id text,
  p_path text
) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT p_vault_id || '::' || replace(p_path, '/', '__SLASH__');
$$;

-- ── Helper: Render a JSONB object as YAML frontmatter ───────────────────────

CREATE OR REPLACE FUNCTION loove_render_frontmatter(p_meta jsonb)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  result text := '---' || E'\n';
  k text;
  v jsonb;
BEGIN
  FOR k, v IN SELECT * FROM jsonb_each(p_meta)
  LOOP
    IF jsonb_typeof(v) = 'array' THEN
      result := result || k || ':' || E'\n';
      FOR i IN 0..jsonb_array_length(v) - 1
      LOOP
        result := result || '  - ' || trim(both '"' from (v->i)::text) || E'\n';
      END LOOP;
    ELSIF jsonb_typeof(v) = 'null' THEN
      -- skip nulls
      CONTINUE;
    ELSE
      result := result || k || ': ' || trim(both '"' from v::text) || E'\n';
    END IF;
  END LOOP;
  result := result || '---' || E'\n';
  RETURN result;
END;
$$;

-- ============================================================================
-- TRANSLATION FUNCTIONS — one per source table
-- ============================================================================
-- Each function converts a source row into a markdown document with
-- YAML frontmatter and upserts it into vault_files.
--
-- Design principles:
--   1. Deterministic path: domain/table-name/slug.md
--   2. Frontmatter contains all structured fields (queryable via JSONB)
--   3. Body contains the human-readable narrative content
--   4. Tags array enables cross-referencing in Obsidian
--   5. Soft delete on source row deletion (deleted = true)
-- ============================================================================

-- ── shared_context → vault_files ────────────────────────────────────────────

CREATE OR REPLACE FUNCTION loove_translate_shared_context()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_vault_id text := 'loove-system';
  v_path text;
  v_content text;
  v_frontmatter jsonb;
  v_tags text[];
  v_row_id text;
  v_now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_path := 'loove/shared-context/' || OLD.id || '.md';
    v_row_id := loove_vault_row_id(v_vault_id, v_path);
    UPDATE vault_files SET deleted = true, updated_at = now()
      WHERE id = v_row_id;
    RETURN OLD;
  END IF;

  -- Build path from ID (slugified title would be nicer but ID is deterministic)
  v_path := 'loove/shared-context/' || NEW.id || '.md';
  v_row_id := loove_vault_row_id(v_vault_id, v_path);

  -- Build frontmatter (FIX B: Added 'title' field)
  v_frontmatter := jsonb_build_object(
    'source_table', 'shared_context',
    'source_id', NEW.id,
    'title', NEW.title,
    'component', NEW.component,
    'content_type', NEW.content_type,
    'visibility', NEW.visibility,
    'severity', NEW.severity,
    'created_by', NEW.created_by,
    'created_at', NEW.created_at,
    'updated_at', NEW.updated_at,
    'trouble_status', NEW.trouble_status
  );

  -- Build tags
  v_tags := ARRAY['shared-context', 'loove-system'];
  IF NEW.component IS NOT NULL THEN
    v_tags := v_tags || NEW.component;
  END IF;
  IF NEW.content_type IS NOT NULL THEN
    v_tags := v_tags || NEW.content_type;
  END IF;

  -- Build markdown body
  v_content := loove_render_frontmatter(v_frontmatter)
    || E'\n# ' || COALESCE(NEW.title, 'Untitled') || E'\n\n'
    || COALESCE(NEW.content, '');

  -- Upsert into vault_files (FIX C: Added user_id column with explicit NULL)
  INSERT INTO vault_files (
    id, vault_id, path, content, is_binary, frontmatter, tags,
    mtime, ctime, size, deleted, updated_at, platform, user_id
  ) VALUES (
    v_row_id, v_vault_id, v_path, v_content, false, v_frontmatter, v_tags,
    v_now_ms, v_now_ms, length(v_content), false, now(), 'all', NULL
  )
  ON CONFLICT (id) DO UPDATE SET
    content = EXCLUDED.content,
    frontmatter = EXCLUDED.frontmatter,
    tags = EXCLUDED.tags,
    mtime = EXCLUDED.mtime,
    size = EXCLUDED.size,
    deleted = false,
    updated_at = now();

  RETURN NEW;
END;
$$;

-- ── loove_index_entries → vault_files ───────────────────────────────────────

CREATE OR REPLACE FUNCTION loove_translate_index_entries()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_vault_id text := 'loove-system';
  v_path text;
  v_content text;
  v_frontmatter jsonb;
  v_tags text[];
  v_row_id text;
  v_now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
  v_domain_label text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_path := 'loove/knowledge/' || OLD.id || '.md';
    v_row_id := loove_vault_row_id(v_vault_id, v_path);
    UPDATE vault_files SET deleted = true, updated_at = now()
      WHERE id = v_row_id;
    RETURN OLD;
  END IF;

  -- Domain label for folder structure
  v_domain_label := COALESCE('d' || NEW.domain_id::text, 'uncategorized');
  v_path := 'loove/knowledge/' || v_domain_label || '/' || NEW.id || '.md';
  v_row_id := loove_vault_row_id(v_vault_id, v_path);

  v_frontmatter := jsonb_build_object(
    'source_table', 'loove_index_entries',
    'source_id', NEW.id,
    'entry_type', NEW.entry_type,
    'category', NEW.category,
    'domain_id', NEW.domain_id,
    'subdomain', NEW.subdomain,
    'status', NEW.status,
    'priority', NEW.priority,
    'tier', NEW.tier,
    'strategic_tier', NEW.strategic_tier,
    'is_queryable', NEW.is_queryable,
    'is_strategic', NEW.is_strategic,
    'feature_name', NEW.feature_name,
    'github_url', NEW.github_url,
    'gdrive_path', NEW.gdrive_path,
    'repo_path', NEW.repo_path,
    'created_by', NEW.created_by,
    'created_at', NEW.created_at,
    'updated_at', NEW.updated_at
  );

  -- Build tags from existing tags column + metadata
  v_tags := COALESCE(NEW.tags, ARRAY[]::text[]) || ARRAY['knowledge', 'ob1'];
  IF NEW.category IS NOT NULL THEN
    v_tags := v_tags || NEW.category;
  END IF;
  IF NEW.subdomain IS NOT NULL THEN
    v_tags := v_tags || NEW.subdomain;
  END IF;

  -- Build markdown body with cross-references
  v_content := loove_render_frontmatter(v_frontmatter)
    || E'\n# ' || COALESCE(NEW.description, NEW.feature_name, 'Untitled Entry') || E'\n\n'
    || COALESCE(NEW.content_preview, '') || E'\n\n';

  -- Add cross-reference links if available
  IF NEW.github_url IS NOT NULL THEN
    v_content := v_content || '**GitHub:** ' || NEW.github_url || E'\n';
  END IF;
  IF NEW.gdrive_path IS NOT NULL THEN
    v_content := v_content || '**Google Drive:** ' || NEW.gdrive_path || E'\n';
  END IF;
  IF NEW.external_url IS NOT NULL THEN
    v_content := v_content || '**External:** ' || NEW.external_url || E'\n';
  END IF;

  -- FIX C: Added user_id column with explicit NULL
  INSERT INTO vault_files (
    id, vault_id, path, content, is_binary, frontmatter, tags,
    mtime, ctime, size, deleted, updated_at, platform, user_id
  ) VALUES (
    v_row_id, v_vault_id, v_path, v_content, false, v_frontmatter, v_tags,
    v_now_ms, v_now_ms, length(v_content), false, now(), 'all', NULL
  )
  ON CONFLICT (id) DO UPDATE SET
    content = EXCLUDED.content,
    frontmatter = EXCLUDED.frontmatter,
    tags = EXCLUDED.tags,
    mtime = EXCLUDED.mtime,
    size = EXCLUDED.size,
    deleted = false,
    updated_at = now();

  RETURN NEW;
END;
$$;

-- ── artists → vault_files ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION loove_translate_artists()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_vault_id text := 'loove-system';
  v_path text;
  v_content text;
  v_frontmatter jsonb;
  v_tags text[];
  v_row_id text;
  v_now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
  v_slug text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_slug := COALESCE(OLD.handle, OLD.id::text);
    v_path := 'loove/artists/' || v_slug || '.md';
    v_row_id := loove_vault_row_id(v_vault_id, v_path);
    UPDATE vault_files SET deleted = true, updated_at = now()
      WHERE id = v_row_id;
    RETURN OLD;
  END IF;

  v_slug := COALESCE(NEW.handle, NEW.id::text);
  v_path := 'loove/artists/' || v_slug || '.md';
  v_row_id := loove_vault_row_id(v_vault_id, v_path);

  v_frontmatter := jsonb_build_object(
    'source_table', 'artists',
    'source_id', NEW.id,
    'handle', NEW.handle,
    'creator_type', NEW.creator_type,
    'shopify_gid', NEW.shopify_gid,
    'primary_image_url', NEW.primary_image_url,
    'is_staged', NEW.is_staged,
    'created_at', NEW.created_at,
    'updated_at', NEW.updated_at
  );

  v_tags := ARRAY['artist', 'content'];
  IF NEW.creator_type IS NOT NULL THEN
    v_tags := v_tags || NEW.creator_type;
  END IF;

  v_content := loove_render_frontmatter(v_frontmatter)
    || E'\n# ' || COALESCE(NEW.display_name, v_slug) || E'\n\n'
    || COALESCE(NEW.about, '_No biography available._') || E'\n';

  IF NEW.primary_image_url IS NOT NULL THEN
    v_content := v_content || E'\n![Artist Image](' || NEW.primary_image_url || ')' || E'\n';
  END IF;

  -- FIX C: Added user_id column with explicit NULL
  INSERT INTO vault_files (
    id, vault_id, path, content, is_binary, frontmatter, tags,
    mtime, ctime, size, deleted, updated_at, platform, user_id
  ) VALUES (
    v_row_id, v_vault_id, v_path, v_content, false, v_frontmatter, v_tags,
    v_now_ms, v_now_ms, length(v_content), false, now(), 'all', NULL
  )
  ON CONFLICT (id) DO UPDATE SET
    content = EXCLUDED.content,
    frontmatter = EXCLUDED.frontmatter,
    tags = EXCLUDED.tags,
    mtime = EXCLUDED.mtime,
    size = EXCLUDED.size,
    deleted = false,
    updated_at = now();

  RETURN NEW;
END;
$$;

-- ── openclaw_tasks → vault_files ────────────────────────────────────────────

CREATE OR REPLACE FUNCTION loove_translate_openclaw_tasks()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_vault_id text := 'loove-system';
  v_path text;
  v_content text;
  v_frontmatter jsonb;
  v_tags text[];
  v_row_id text;
  v_now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_path := 'loove/tasks/' || OLD.task_id || '.md';
    v_row_id := loove_vault_row_id(v_vault_id, v_path);
    UPDATE vault_files SET deleted = true, updated_at = now()
      WHERE id = v_row_id;
    RETURN OLD;
  END IF;

  v_path := 'loove/tasks/' || NEW.task_id || '.md';
  v_row_id := loove_vault_row_id(v_vault_id, v_path);

  -- Build frontmatter (FIX B: Added 'title' field)
  v_frontmatter := jsonb_build_object(
    'source_table', 'openclaw_tasks',
    'source_id', NEW.id,
    'task_id', NEW.task_id,
    'title', NEW.title,
    'status', NEW.status,
    'priority', NEW.priority,
    'assignee', NEW.assignee,
    'domain', NEW.domain,
    'tier', NEW.tier,
    'blocker', NEW.blocker,
    'pm_roadmap_item_id', NEW.pm_roadmap_item_id,
    'created_at', NEW.created_at,
    'updated_at', NEW.updated_at
  );

  v_tags := ARRAY['task', 'openclaw'];
  IF NEW.domain IS NOT NULL THEN
    v_tags := v_tags || NEW.domain;
  END IF;
  IF NEW.priority IS NOT NULL THEN
    v_tags := v_tags || ('p' || NEW.priority::text);
  END IF;

  v_content := loove_render_frontmatter(v_frontmatter)
    || E'\n# ' || COALESCE(NEW.title, 'Untitled Task') || E'\n\n'
    || '**Status:** ' || COALESCE(NEW.status, 'unknown') || E'\n'
    || '**Assignee:** ' || COALESCE(NEW.assignee, 'unassigned') || E'\n'
    || '**Priority:** ' || COALESCE(NEW.priority::text, '-') || E'\n\n'
    || '## Next Action' || E'\n\n'
    || COALESCE(NEW.next_action, '_No next action defined._') || E'\n';

  IF NEW.blocker IS NOT NULL THEN
    v_content := v_content || E'\n## Blocker\n\n' || NEW.blocker || E'\n';
  END IF;

  -- FIX C: Added user_id column with explicit NULL
  INSERT INTO vault_files (
    id, vault_id, path, content, is_binary, frontmatter, tags,
    mtime, ctime, size, deleted, updated_at, platform, user_id
  ) VALUES (
    v_row_id, v_vault_id, v_path, v_content, false, v_frontmatter, v_tags,
    v_now_ms, v_now_ms, length(v_content), false, now(), 'all', NULL
  )
  ON CONFLICT (id) DO UPDATE SET
    content = EXCLUDED.content,
    frontmatter = EXCLUDED.frontmatter,
    tags = EXCLUDED.tags,
    mtime = EXCLUDED.mtime,
    size = EXCLUDED.size,
    deleted = false,
    updated_at = now();

  RETURN NEW;
END;
$$;

-- ── trouble_reports → vault_files ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION loove_translate_trouble_reports()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_vault_id text := 'loove-system';
  v_path text;
  v_content text;
  v_frontmatter jsonb;
  v_tags text[];
  v_row_id text;
  v_now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_path := 'loove/trouble-reports/' || OLD.id || '.md';
    v_row_id := loove_vault_row_id(v_vault_id, v_path);
    UPDATE vault_files SET deleted = true, updated_at = now()
      WHERE id = v_row_id;
    RETURN OLD;
  END IF;

  v_path := 'loove/trouble-reports/' || NEW.id || '.md';
  v_row_id := loove_vault_row_id(v_vault_id, v_path);

  -- Build frontmatter (FIX B: Added 'title' field)
  v_frontmatter := jsonb_build_object(
    'source_table', 'trouble_reports',
    'source_id', NEW.id,
    'title', NEW.title,
    'component', NEW.component,
    'severity', NEW.severity,
    'trouble_status', NEW.trouble_status,
    'created_by', NEW.created_by,
    'created_at', NEW.created_at,
    'updated_at', NEW.updated_at
  );

  v_tags := ARRAY['trouble-report', 'maintenance'];
  IF NEW.component IS NOT NULL THEN
    v_tags := v_tags || NEW.component;
  END IF;
  IF NEW.severity IS NOT NULL THEN
    v_tags := v_tags || NEW.severity;
  END IF;

  v_content := loove_render_frontmatter(v_frontmatter)
    || E'\n# ' || COALESCE(NEW.title, 'Untitled Report') || E'\n\n'
    || '**Severity:** ' || COALESCE(NEW.severity, 'unknown') || E'\n'
    || '**Component:** ' || COALESCE(NEW.component, 'unknown') || E'\n'
    || '**Status:** ' || COALESCE(NEW.trouble_status, 'open') || E'\n\n'
    || COALESCE(NEW.content, '') || E'\n';

  -- FIX C: Added user_id column with explicit NULL
  INSERT INTO vault_files (
    id, vault_id, path, content, is_binary, frontmatter, tags,
    mtime, ctime, size, deleted, updated_at, platform, user_id
  ) VALUES (
    v_row_id, v_vault_id, v_path, v_content, false, v_frontmatter, v_tags,
    v_now_ms, v_now_ms, length(v_content), false, now(), 'all', NULL
  )
  ON CONFLICT (id) DO UPDATE SET
    content = EXCLUDED.content,
    frontmatter = EXCLUDED.frontmatter,
    tags = EXCLUDED.tags,
    mtime = EXCLUDED.mtime,
    size = EXCLUDED.size,
    deleted = false,
    updated_at = now();

  RETURN NEW;
END;
$$;

-- ============================================================================
-- TRIGGER REGISTRATION
-- ============================================================================

-- shared_context
DROP TRIGGER IF EXISTS trg_translate_shared_context ON shared_context;
CREATE TRIGGER trg_translate_shared_context
  AFTER INSERT OR UPDATE OR DELETE ON shared_context
  FOR EACH ROW EXECUTE FUNCTION loove_translate_shared_context();

-- loove_index_entries
DROP TRIGGER IF EXISTS trg_translate_index_entries ON loove_index_entries;
CREATE TRIGGER trg_translate_index_entries
  AFTER INSERT OR UPDATE OR DELETE ON loove_index_entries
  FOR EACH ROW EXECUTE FUNCTION loove_translate_index_entries();

-- artists
DROP TRIGGER IF EXISTS trg_translate_artists ON artists;
CREATE TRIGGER trg_translate_artists
  AFTER INSERT OR UPDATE OR DELETE ON artists
  FOR EACH ROW EXECUTE FUNCTION loove_translate_artists();

-- openclaw_tasks
DROP TRIGGER IF EXISTS trg_translate_openclaw_tasks ON openclaw_tasks;
CREATE TRIGGER trg_translate_openclaw_tasks
  AFTER INSERT OR UPDATE OR DELETE ON openclaw_tasks
  FOR EACH ROW EXECUTE FUNCTION loove_translate_openclaw_tasks();

-- trouble_reports
DROP TRIGGER IF EXISTS trg_translate_trouble_reports ON trouble_reports;
CREATE TRIGGER trg_translate_trouble_reports
  AFTER INSERT OR UPDATE OR DELETE ON trouble_reports
  FOR EACH ROW EXECUTE FUNCTION loove_translate_trouble_reports();

-- ============================================================================
-- BACKFILL — Run once to populate vault_files from existing data
-- ============================================================================
-- These statements trigger the translation functions for all existing rows.
-- Run them AFTER the triggers are created.
-- WARNING: This will generate ~3,500 vault_files rows. Ensure vault_files
--          table exists first (SupaBase Jump creates it on plugin setup).
-- ============================================================================

-- Backfill shared_context
-- UPDATE shared_context SET updated_at = updated_at;

-- Backfill loove_index_entries
-- UPDATE loove_index_entries SET updated_at = updated_at;

-- Backfill artists
-- UPDATE artists SET updated_at = updated_at;

-- Backfill openclaw_tasks
-- UPDATE openclaw_tasks SET updated_at = updated_at;

-- Backfill trouble_reports
-- UPDATE trouble_reports SET updated_at = updated_at;

-- ── RLS Policy for System Vault ─────────────────────────────────────────────
-- System-generated notes (vault_id = 'loove-system') have user_id = NULL.
-- This policy allows any authenticated user to READ them.
-- Write access remains restricted — only triggers can modify system notes.

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename='vault_files' AND policyname='System vault readable by authenticated'
  ) THEN
    CREATE POLICY "System vault readable by authenticated" ON vault_files
      FOR SELECT
      USING (vault_id = 'loove-system');
  END IF;
END $$;

-- ============================================================================
-- REVERSE SYNC — vault_files edits back to source tables
-- ============================================================================
-- This is the hard direction. When a user edits a markdown note in Obsidian,
-- the change propagates to vault_files via SupaBase Jump. We need a trigger
-- on vault_files that detects system-generated notes (source_table in
-- frontmatter) and pushes changes back to the source table.
--
-- DESIGN DECISION: For Phase 1, reverse sync is LIMITED to:
--   1. Frontmatter field edits (parsed from YAML, mapped back to columns)
--   2. Content/body edits (mapped to the text column in the source table)
--
-- Complex structural changes (adding new fields, changing the source_id)
-- are NOT supported in reverse sync. The source table schema is authoritative.
-- ============================================================================

CREATE OR REPLACE FUNCTION loove_reverse_sync_vault()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_source_table text;
  v_source_id text;
  v_fm jsonb;
BEGIN
  -- Only process updates to non-deleted, system-generated notes
  IF NEW.deleted = true THEN RETURN NEW; END IF;
  IF NEW.vault_id != 'loove-system' THEN RETURN NEW; END IF;

  v_fm := NEW.frontmatter;
  IF v_fm IS NULL THEN RETURN NEW; END IF;

  v_source_table := v_fm->>'source_table';
  v_source_id := v_fm->>'source_id';

  IF v_source_table IS NULL OR v_source_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Extract the body content (everything after the second '---')
  -- The frontmatter is between the first and second '---' lines.
  -- We parse the title from the first '# ' line after frontmatter.

  CASE v_source_table
    WHEN 'shared_context' THEN
      UPDATE shared_context SET
        title = v_fm->>'title',
        content = regexp_replace(
          NEW.content,
          '^---[\s\S]*?---\s*\n#\s+[^\n]*\n\n',
          '',
          'n'
        ),
        updated_at = now()
      WHERE id = (v_source_id)::uuid;

    WHEN 'openclaw_tasks' THEN
      UPDATE openclaw_tasks SET
        status = v_fm->>'status',
        priority = (v_fm->>'priority')::int,
        assignee = v_fm->>'assignee',
        updated_at = now()
      WHERE id = (v_source_id)::uuid;

    WHEN 'trouble_reports' THEN
      UPDATE trouble_reports SET
        severity = v_fm->>'severity',
        trouble_status = v_fm->>'trouble_status',
        content = regexp_replace(
          NEW.content,
          '^---[\s\S]*?---\s*\n#\s+[^\n]*\n\n(\*\*[^\n]*\n)*\n?',
          '',
          'n'
        ),
        updated_at = now()
      WHERE id = (v_source_id)::uuid;

    -- artists and loove_index_entries: read-only in Phase 1
    -- (too many fields, too much risk of data corruption from manual edits)
    ELSE
      NULL;
  END CASE;

  RETURN NEW;
END;
$$;

-- Register reverse sync trigger
-- NOTE: This trigger must fire AFTER SupaBase Jump's own update processing.
-- Use a later trigger name alphabetically or explicit ordering if needed.
DROP TRIGGER IF EXISTS trg_reverse_sync_vault ON vault_files;
CREATE TRIGGER trg_reverse_sync_vault
  AFTER UPDATE ON vault_files
  FOR EACH ROW
  WHEN (OLD.content IS DISTINCT FROM NEW.content
     OR OLD.frontmatter IS DISTINCT FROM NEW.frontmatter)
  EXECUTE FUNCTION loove_reverse_sync_vault();

-- ============================================================================
-- ECHO PREVENTION
-- ============================================================================
-- The forward trigger (source → vault_files) and reverse trigger
-- (vault_files → source) could create an infinite loop:
--   source UPDATE → vault_files INSERT → vault_files UPDATE → source UPDATE → ...
--
-- Prevention strategy:
--   1. Forward triggers use AFTER INSERT OR UPDATE — they write to vault_files
--   2. Reverse trigger uses AFTER UPDATE on vault_files — it writes to source
--   3. The reverse trigger's source UPDATE fires the forward trigger again
--   4. The forward trigger upserts vault_files with ON CONFLICT DO UPDATE
--   5. If the content hasn't changed, the vault_files row is identical
--   6. The WHEN clause on the reverse trigger (OLD.content IS DISTINCT FROM
--      NEW.content) prevents re-firing when content is unchanged
--
-- This breaks the loop because:
--   - Forward trigger produces identical content → no DISTINCT change
--   - Reverse trigger doesn't fire → loop terminates
--
-- Edge case: If the reverse sync modifies the source row in a way that
-- produces DIFFERENT markdown (e.g., truncation, normalization), the loop
-- will cycle once more and then stabilize. This is acceptable.
-- ============================================================================