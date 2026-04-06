-- Standalone RLS fix for system vault reads
-- Run this if translation_layer.sql was deployed before the RLS fix was added
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