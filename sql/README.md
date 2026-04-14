# SQL Deployment Guide

## Prerequisites
- `vault_files` table must exist (created by SupaBase Jump plugin "One-Click Setup")
- Supabase Management API token or SQL Editor access

## Deployment Order
1. `translation_layer.sql` — Creates triggers, helpers, and reverse sync
2. Run backfill commands (uncomment at bottom of `translation_layer.sql`)
3. `rag_pipeline.sql` — Adds pgvector, pgmq queue, and vault_files semantic search
4. Deploy `supabase/functions/generate-embedding/index.ts` with JWT verification disabled

## Deployment Notes
- `rag_pipeline.sql` uses `extensions.vector(384)` for Supabase `gte-small` embeddings.
- The current Phase 3 search surface is intentionally *vault_files-only*. A direct vector union with `loove_index_entries` is deferred until LOOVE is on one verified embedding space.
- Deploy the edge function with `--no-verify-jwt` (or equivalent config), because `pg_cron` invokes it from Postgres without an end-user bearer token.

## Files
| File | Purpose | When to Run |
|------|---------|-------------|
| `translation_layer.sql` | Triggers projecting operational tables → vault_files | After `vault_files` table exists |
| `rls_system_vault.sql` | Standalone RLS policy for system vault reads | If `translation_layer.sql` was deployed before this fix |
| `rag_pipeline.sql` | pgvector embeddings + queue + vault_files search | After translation layer is deployed |
| `supabase/functions/generate-embedding/index.ts` | Queue processor using `Supabase.ai.Session('gte-small')` | After `rag_pipeline.sql` |
