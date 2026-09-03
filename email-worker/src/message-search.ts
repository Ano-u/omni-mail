import { safeJsonArray } from './api-helpers'
import type { Env, StoredBody } from './types'

const MAX_SEARCH_CONTENT_CHARS = 200_000
const SEARCH_BACKFILL_BATCH_SIZE = 200
const SEARCH_BACKFILL_RECHECK_SECONDS = 7 * 24 * 60 * 60
const SEARCH_BACKFILL_CURSOR_KEY = 'message_search_backfill_cursor'
const SEARCH_BACKFILL_CHECKED_AT_KEY = 'message_search_backfill_checked_at'

export type SearchContentInput = {
  subject: string
  sender: string
  recipients: string[]
  body: string
}

export function searchContent(input: SearchContentInput): string {
  return [
    input.subject,
    input.sender,
    input.recipients.join(' '),
    input.body,
  ].join(' ').replace(/\s+/g, ' ').trim().toLowerCase().slice(0, MAX_SEARCH_CONTENT_CHARS)
}

export function searchLikePattern(query: string): string {
  const escaped = query.trim().toLowerCase()
    .replaceAll('\\', '\\\\')
    .replaceAll('%', '\\%')
    .replaceAll('_', '\\_')
  return `%${escaped}%`
}

export function messageSearchStatement(
  db: D1Database,
  messageId: string,
  input: SearchContentInput,
): D1PreparedStatement {
  return db.prepare(
    `INSERT INTO message_search (message_id, content, indexed_at)
     VALUES (?, ?, unixepoch())
     ON CONFLICT(message_id) DO UPDATE SET
       content = excluded.content, indexed_at = excluded.indexed_at`,
  ).bind(messageId, searchContent(input))
}

export async function indexStoredMessage(env: Env, messageId: string): Promise<void> {
  const message = await env.DB.prepare(
    `SELECT id, subject, sender_address, recipients_json, cc_json, body_key
       FROM messages WHERE id = ?`,
  ).bind(messageId).first<{
    id: string
    subject: string
    sender_address: string
    recipients_json: string
    cc_json: string
    body_key: string | null
  }>()
  if (!message?.body_key) return
  const object = await env.MAIL_BUCKET.get(message.body_key)
  if (!object) throw new Error('Search index message body is missing')
  const body = await object.json<StoredBody>()
  await messageSearchStatement(env.DB, message.id, {
    subject: message.subject,
    sender: message.sender_address,
    recipients: [
      ...safeJsonArray(message.recipients_json),
      ...safeJsonArray(message.cc_json),
    ],
    body: body.text || '',
  }).run()
}

export async function enqueueMissingMessageSearch(
  env: Env,
  now = Math.floor(Date.now() / 1000),
): Promise<void> {
  const { results: settings } = await env.DB.prepare(
    `SELECT key, value FROM settings
      WHERE key IN (?, ?)`,
  ).bind(SEARCH_BACKFILL_CURSOR_KEY, SEARCH_BACKFILL_CHECKED_AT_KEY)
    .all<{ key: string; value: string }>()
  const state = new Map(settings.map((setting) => [setting.key, setting.value]))
  const cursor = state.get(SEARCH_BACKFILL_CURSOR_KEY) || ''
  const checkedAt = Number(state.get(SEARCH_BACKFILL_CHECKED_AT_KEY) || 0)
  if (!cursor && Number.isFinite(checkedAt) && checkedAt > now - SEARCH_BACKFILL_RECHECK_SECONDS) {
    return
  }

  const { results } = await env.DB.prepare(
    `SELECT m.id, s.message_id AS indexed_id
       FROM messages m
       LEFT JOIN message_search s ON s.message_id = m.id
      WHERE m.id > ? AND m.body_key IS NOT NULL
      ORDER BY m.id
      LIMIT ?`,
  ).bind(cursor, SEARCH_BACKFILL_BATCH_SIZE)
    .all<{ id: string; indexed_id: string | null }>()
  for (const message of results.filter((row) => !row.indexed_id)) {
    await env.MAIL_QUEUE.send({ kind: 'index', messageId: message.id })
  }

  if (results.length < SEARCH_BACKFILL_BATCH_SIZE) {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO settings (key, value, updated_at) VALUES (?, '', ?)
         ON CONFLICT(key) DO UPDATE SET value = '', updated_at = excluded.updated_at`,
      ).bind(SEARCH_BACKFILL_CURSOR_KEY, now),
      env.DB.prepare(
        `INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
      ).bind(SEARCH_BACKFILL_CHECKED_AT_KEY, String(now), now),
    ])
    return
  }

  await env.DB.prepare(
    `INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
  ).bind(SEARCH_BACKFILL_CURSOR_KEY, results.at(-1)?.id || cursor, now).run()
}
