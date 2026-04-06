# SQL Deployment Guide

## Prerequisites
- `vault_files` table must exist (created by SupaBase Jump plugin "One-Click Setup")
- Supabase Management API token or SQL Editor access

## Deployment Order
1. `translation_layer.sql` — Creates triggers, helpers, and reverse sync
2. Run backfill commands (uncomment at bottom of translation_layer.sql)
3. `rag_pipeline.sql` — Adds pgvector, pgmq queue, and search functions (Phase 3)

## Files
| File | Purpose | When to Run |
|------|---------|-------------|
| `translation_layer.sql` | Triggers projecting operational tables → vault_files | After vault_files table exists |
| `rls_system_vault.sql` | Standalone RLS policy for system vault reads | If translation_layer.sql was deployed before this fix |
| `rag_pipeline.sql` | pgvector embeddings + semantic search (Phase 3) | After translation layer is deployed |