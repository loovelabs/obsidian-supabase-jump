# SQL Deployment Guide

## Prerequisites
- `vault_files` table must exist (created by SupaBase Jump plugin "One-Click Setup")
- Supabase Management API token or SQL Editor access

## Deployment Order
1. `translation_layer.sql` — Creates triggers, helpers, and reverse sync
2. `pm_roadmap_items_translation.sql` — Extends translation layer for roadmap items (2,574 rows)
3. Run backfill commands (uncomment at bottom of each translation file)
4. `rag_pipeline.sql` — Adds pgvector, embedding queue, and search functions

## Files
| File | Purpose | Rows Affected | When to Run |
|------|---------|---------------|-------------|
| `translation_layer.sql` | Triggers: shared_context, loove_index_entries, artists, openclaw_tasks, trouble_reports → vault_files | ~700 | After vault_files table exists |
| `pm_roadmap_items_translation.sql` | Trigger: pm_roadmap_items → vault_files (organized by work_category) | ~2,574 | After translation_layer.sql |
| `rls_system_vault.sql` | Standalone RLS policy for system vault reads | - | If translation_layer.sql was deployed before this fix |
| `rag_pipeline.sql` | pgvector embeddings, HNSW index, embedding queue, semantic search (loove_semantic_search), text search fallback, stats view | All vault_files | After translation layer is deployed |

## Estimated vault_files row count after full backfill
- shared_context: ~599
- loove_index_entries: varies
- artists: varies
- openclaw_tasks: ~35
- trouble_reports: varies
- pm_roadmap_items: ~2,574
- **Total system notes: ~3,500+**
- Plus user-created notes from Obsidian

## RAG Pipeline Cost
- OpenAI text-embedding-3-small: ~$0.035 for initial backfill of ~3,500 notes
- Ongoing: negligible (only changed notes re-embedded)
