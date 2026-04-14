import 'jsr:@supabase/functions-js/edge-runtime.d.ts'

import postgres from 'https://deno.land/x/postgresjs@v3.4.5/mod.js'

const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, {
  prepare: false,
  max: 1,
})

const model = new Supabase.ai.Session('gte-small')
const DEFAULT_QUEUE = 'embedding_jobs'
const DEFAULT_BATCH_SIZE = 10
const DEFAULT_VISIBILITY_TIMEOUT = 60
const MAX_INPUT_CHARS = 8000

interface QueueRow {
  msg_id: number
  message: {
    id?: string
  }
}

function stripFrontmatter(content: string): string {
  return content.replace(/^---[\s\S]*?---\s*\n/, '')
}

function truncateForModel(content: string): string {
  const stripped = stripFrontmatter(content).trim()
  return stripped.length > MAX_INPUT_CHARS
    ? stripped.slice(0, MAX_INPUT_CHARS)
    : stripped
}

function vectorLiteral(values: number[]): string {
  return `[${values.join(',')}]`
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return Response.json({ error: 'expected POST request' }, { status: 405 })
  }

  const body = await req.json().catch(() => ({})) as {
    queue?: string
    batch_size?: number
    visibility_timeout?: number
  }

  const queue = body.queue ?? DEFAULT_QUEUE
  const batchSize = body.batch_size ?? DEFAULT_BATCH_SIZE
  const visibilityTimeout = body.visibility_timeout ?? DEFAULT_VISIBILITY_TIMEOUT

  const messages = await sql<QueueRow[]>`
    select msg_id, message
    from pgmq.read(${queue}, ${visibilityTimeout}, ${batchSize})
  `

  if (messages.length === 0) {
    return Response.json({ processed: 0, failed: 0, total: 0 })
  }

  let processed = 0
  let failed = 0
  const failures: Array<{ msg_id: number; error: string }> = []

  for (const msg of messages) {
    const rowId = msg.message?.id

    if (!rowId) {
      failed += 1
      failures.push({ msg_id: msg.msg_id, error: 'missing row id in queue message' })
      continue
    }

    try {
      const rows = await sql<{ id: string; content: string | null; embedding: unknown }[]>`
        select id, content, embedding
        from public.vault_files
        where id = ${rowId}
        limit 1
      `

      const row = rows[0]
      if (!row) {
        await sql`select pgmq.delete(${queue}, ${msg.msg_id}::bigint)`
        processed += 1
        continue
      }

      if (row.embedding) {
        await sql`select pgmq.delete(${queue}, ${msg.msg_id}::bigint)`
        processed += 1
        continue
      }

      const content = row.content?.trim()
      if (!content) {
        await sql`select pgmq.delete(${queue}, ${msg.msg_id}::bigint)`
        processed += 1
        continue
      }

      const embedding = await model.run(truncateForModel(content), {
        mean_pool: true,
        normalize: true,
      }) as number[]

      await sql`
        update public.vault_files
        set embedding = ${vectorLiteral(embedding)}::extensions.vector,
            updated_at = now()
        where id = ${rowId}
      `

      await sql`select pgmq.delete(${queue}, ${msg.msg_id}::bigint)`
      processed += 1
    } catch (error) {
      failed += 1
      failures.push({
        msg_id: msg.msg_id,
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }

  return Response.json({
    processed,
    failed,
    total: messages.length,
    failures,
  })
})
