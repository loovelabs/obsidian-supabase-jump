-- ============================================================================
-- LOOVE OS Translation Layer: pm_roadmap_items → vault_files
-- ============================================================================
-- Extends the translation layer in loovelabs/obsidian-supabase-jump
-- to cover pm_roadmap_items (2,574 rows, largest operational table).
--
-- Status: DESIGNED, NOT YET DEPLOYED
-- Requires: vault_files table + helper functions from translation_layer.sql
-- ============================================================================

CREATE OR REPLACE FUNCTION loove_translate_pm_roadmap_items()
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
  v_category_folder text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_path := 'loove/roadmap/' || COALESCE(OLD.work_category, 'uncategorized') || '/' || COALESCE(OLD.display_id, OLD.id::text) || '.md';
    v_row_id := loove_vault_row_id(v_vault_id, v_path);
    UPDATE vault_files SET deleted = true, updated_at = now()
      WHERE id = v_row_id;
    RETURN OLD;
  END IF;

  v_category_folder := COALESCE(NEW.work_category, 'uncategorized');
  v_path := 'loove/roadmap/' || v_category_folder || '/' || COALESCE(NEW.display_id, NEW.id::text) || '.md';
  v_row_id := loove_vault_row_id(v_vault_id, v_path);

  v_frontmatter := jsonb_build_object(
    'source_table', 'pm_roadmap_items',
    'source_id', NEW.id,
    'title', NEW.title,
    'display_id', NEW.display_id,
    'item_type', NEW.item_type,
    'status', NEW.status,
    'priority', NEW.priority,
    'work_category', NEW.work_category,
    'assignee', NEW.assignee,
    'assigned_to', NEW.assigned_to,
    'start_date', NEW.start_date,
    'due_date', NEW.due_date,
    'completed_at', NEW.completed_at,
    'estimated_hours', NEW.estimated_hours,
    'actual_hours', NEW.actual_hours,
    'source', NEW.source,
    'external_id', NEW.external_id,
    'looda_status', NEW.looda_status,
    'looda_verification_status', NEW.looda_verification_status,
    'created_by', NEW.created_by,
    'created_at', NEW.created_at,
    'updated_at', NEW.updated_at
  );

  v_tags := ARRAY['roadmap', 'pm'];
  IF NEW.work_category IS NOT NULL THEN
    v_tags := v_tags || NEW.work_category;
  END IF;
  IF NEW.item_type IS NOT NULL THEN
    v_tags := v_tags || NEW.item_type::text;
  END IF;
  IF NEW.status IS NOT NULL THEN
    v_tags := v_tags || NEW.status::text;
  END IF;
  IF NEW.priority IS NOT NULL THEN
    v_tags := v_tags || NEW.priority::text;
  END IF;
  IF NEW.tags IS NOT NULL THEN
    v_tags := v_tags || NEW.tags;
  END IF;

  v_content := loove_render_frontmatter(v_frontmatter)
    || E'\n# ' || COALESCE(NEW.title, 'Untitled Roadmap Item') || E'\n\n'
    || '**Display ID:** ' || COALESCE(NEW.display_id, '-') || E'\n'
    || '**Type:** ' || COALESCE(NEW.item_type::text, '-') || E'\n'
    || '**Status:** ' || COALESCE(NEW.status::text, '-') || E'\n'
    || '**Priority:** ' || COALESCE(NEW.priority::text, '-') || E'\n'
    || '**Category:** ' || COALESCE(NEW.work_category, '-') || E'\n'
    || '**Assignee:** ' || COALESCE(NEW.assigned_to, NEW.assignee, 'unassigned') || E'\n';

  IF NEW.start_date IS NOT NULL OR NEW.due_date IS NOT NULL THEN
    v_content := v_content || E'\n## Timeline\n\n';
    IF NEW.start_date IS NOT NULL THEN
      v_content := v_content || '**Start:** ' || NEW.start_date::text || E'\n';
    END IF;
    IF NEW.due_date IS NOT NULL THEN
      v_content := v_content || '**Due:** ' || NEW.due_date::text || E'\n';
    END IF;
  END IF;

  IF NEW.description IS NOT NULL AND NEW.description != '' THEN
    v_content := v_content || E'\n## Description\n\n' || NEW.description || E'\n';
  END IF;

  IF NEW.looda_status IS NOT NULL AND NEW.looda_status != 'untracked' THEN
    v_content := v_content || E'\n## LOODA\n\n'
      || '**Status:** ' || COALESCE(NEW.looda_status, '-') || E'\n'
      || '**Verification:** ' || COALESCE(NEW.looda_verification_status, '-') || E'\n';
  END IF;

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

-- Register trigger
DROP TRIGGER IF EXISTS trg_translate_pm_roadmap_items ON pm_roadmap_items;
CREATE TRIGGER trg_translate_pm_roadmap_items
  AFTER INSERT OR UPDATE OR DELETE ON pm_roadmap_items
  FOR EACH ROW EXECUTE FUNCTION loove_translate_pm_roadmap_items();

-- Reverse sync note: pm_roadmap_items reverse sync (status/priority/assignee)
-- should be added to the CASE statement in loove_reverse_sync_vault().
-- Deferred to Phase 2 due to USER-DEFINED enum types requiring cast validation.

-- Backfill (uncomment to run once after trigger creation):
-- UPDATE pm_roadmap_items SET updated_at = updated_at;
