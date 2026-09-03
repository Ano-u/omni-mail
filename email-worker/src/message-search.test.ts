import { describe, expect, it, vi } from 'vitest'
import {
  enqueueMissingMessageSearch,
  searchContent,
  searchLikePattern,
} from './message-search'
import type { Env } from './types'

describe('message body search', () => {
  it('normalizes searchable metadata and body text', () => {
    expect(searchContent({
      subject: ' Hello ',
      sender: 'Sender@Example.com',
      recipients: ['Owner@Example.com'],
      body: 'First\n\nSECOND',
    })).toBe('hello sender@example.com owner@example.com first second')
  })

  it('escapes LIKE wildcards supplied by the user', () => {
    expect(searchLikePattern('50%_off\\now')).toBe('%50\\%\\_off\\\\now%')
  })

  it('bounds indexed content so a D1 row remains below its size limit', () => {
    const content = searchContent({
      subject: '',
      sender: '',
      recipients: [],
      body: 'x'.repeat(300_000),
    })
    expect(content.length).toBe(200_000)
  })

  it('skips a completed backfill until its weekly recheck is due', async () => {
    const statements: string[] = []
    const db = {
      prepare(sql: string) {
        statements.push(sql)
        return {
          bind() { return this },
          all: async () => ({ results: [
            { key: 'message_search_backfill_cursor', value: '' },
            { key: 'message_search_backfill_checked_at', value: '1999999999' },
          ] }),
        }
      },
    }
    const send = vi.fn(async () => undefined)

    await enqueueMissingMessageSearch({
      DB: db,
      MAIL_QUEUE: { send },
    } as unknown as Env, 2_000_000_000)

    expect(statements).toHaveLength(1)
    expect(send).not.toHaveBeenCalled()
  })

  it('pages by message ID and queues only missing search rows', async () => {
    const statements: Array<{ sql: string; bindings: unknown[] }> = []
    const batch = vi.fn(async () => [])
    const db = {
      prepare(sql: string) {
        const entry = { sql, bindings: [] as unknown[] }
        statements.push(entry)
        return {
          bind(...bindings: unknown[]) {
            entry.bindings = bindings
            return this
          },
          all: async () => ({
            results: sql.includes('FROM settings')
              ? [{ key: 'message_search_backfill_cursor', value: 'message-1' }]
              : [
                { id: 'message-2', indexed_id: 'message-2' },
                { id: 'message-3', indexed_id: null },
              ],
          }),
          run: async () => ({ meta: { changes: 1 } }),
        }
      },
      batch,
    }
    const send = vi.fn(async () => undefined)

    await enqueueMissingMessageSearch({
      DB: db,
      MAIL_QUEUE: { send },
    } as unknown as Env, 2_000_000_000)

    const page = statements.find(({ sql }) => sql.includes('FROM messages m'))
    expect(page?.sql).toContain('m.id > ?')
    expect(page?.sql).toContain('ORDER BY m.id')
    expect(page?.bindings).toEqual(['message-1', 200])
    expect(send).toHaveBeenCalledOnce()
    expect(send).toHaveBeenCalledWith({ kind: 'index', messageId: 'message-3' })
    expect(batch).toHaveBeenCalledOnce()
  })
})
