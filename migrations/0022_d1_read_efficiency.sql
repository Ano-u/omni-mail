ALTER TABLE mail_state_versions
  ADD COLUMN unread_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE mail_state_versions
  ADD COLUMN starred_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE mail_state_versions
  ADD COLUMN sent_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE mail_state_versions
  ADD COLUMN trash_count INTEGER NOT NULL DEFAULT 0;

INSERT INTO mail_state_versions (
  user_id, version, updated_at,
  unread_count, starred_count, sent_count, trash_count
)
SELECT
  mb.user_id,
  0,
  unixepoch(),
  SUM(CASE
    WHEN m.direction = 'incoming' AND m.folder = 'inbox' AND m.is_read = 0
    THEN 1 ELSE 0
  END),
  SUM(CASE WHEN m.is_starred = 1 AND m.folder != 'trash' THEN 1 ELSE 0 END),
  SUM(CASE WHEN m.direction = 'outgoing' AND m.folder = 'sent' THEN 1 ELSE 0 END),
  SUM(CASE WHEN m.folder = 'trash' THEN 1 ELSE 0 END)
FROM mailboxes mb
LEFT JOIN messages m ON m.mailbox_address = mb.address
GROUP BY mb.user_id
ON CONFLICT(user_id) DO UPDATE SET
  unread_count = excluded.unread_count,
  starred_count = excluded.starred_count,
  sent_count = excluded.sent_count,
  trash_count = excluded.trash_count,
  updated_at = excluded.updated_at;

DROP TRIGGER IF EXISTS trg_messages_mail_state_insert;
CREATE TRIGGER trg_messages_mail_state_insert
AFTER INSERT ON messages BEGIN
  INSERT INTO mail_state_versions (
    user_id, version, updated_at,
    unread_count, starred_count, sent_count, trash_count
  )
  SELECT
    mb.user_id,
    1,
    unixepoch(),
    CASE
      WHEN NEW.direction = 'incoming' AND NEW.folder = 'inbox' AND NEW.is_read = 0
      THEN 1 ELSE 0
    END,
    CASE WHEN NEW.is_starred = 1 AND NEW.folder != 'trash' THEN 1 ELSE 0 END,
    CASE WHEN NEW.direction = 'outgoing' AND NEW.folder = 'sent' THEN 1 ELSE 0 END,
    CASE WHEN NEW.folder = 'trash' THEN 1 ELSE 0 END
  FROM mailboxes mb
  WHERE mb.address = NEW.mailbox_address
  ON CONFLICT(user_id) DO UPDATE SET
    version = mail_state_versions.version + 1,
    unread_count = mail_state_versions.unread_count + excluded.unread_count,
    starred_count = mail_state_versions.starred_count + excluded.starred_count,
    sent_count = mail_state_versions.sent_count + excluded.sent_count,
    trash_count = mail_state_versions.trash_count + excluded.trash_count,
    updated_at = excluded.updated_at;
END;

DROP TRIGGER IF EXISTS trg_messages_mail_state_update;
CREATE TRIGGER trg_messages_mail_state_update
AFTER UPDATE OF direction, status, folder, sender_name, sender_address, subject, preview,
  received_at, sent_at, attachment_count, is_read, is_starred, processing_error,
  delivery_status
ON messages BEGIN
  INSERT INTO mail_state_versions (
    user_id, version, updated_at,
    unread_count, starred_count, sent_count, trash_count
  )
  SELECT
    mb.user_id,
    1,
    unixepoch(),
    CASE
      WHEN NEW.direction = 'incoming' AND NEW.folder = 'inbox' AND NEW.is_read = 0
      THEN 1 ELSE 0
    END - CASE
      WHEN OLD.direction = 'incoming' AND OLD.folder = 'inbox' AND OLD.is_read = 0
      THEN 1 ELSE 0
    END,
    CASE WHEN NEW.is_starred = 1 AND NEW.folder != 'trash' THEN 1 ELSE 0 END
      - CASE WHEN OLD.is_starred = 1 AND OLD.folder != 'trash' THEN 1 ELSE 0 END,
    CASE WHEN NEW.direction = 'outgoing' AND NEW.folder = 'sent' THEN 1 ELSE 0 END
      - CASE WHEN OLD.direction = 'outgoing' AND OLD.folder = 'sent' THEN 1 ELSE 0 END,
    CASE WHEN NEW.folder = 'trash' THEN 1 ELSE 0 END
      - CASE WHEN OLD.folder = 'trash' THEN 1 ELSE 0 END
  FROM mailboxes mb
  WHERE mb.address = NEW.mailbox_address
  ON CONFLICT(user_id) DO UPDATE SET
    version = mail_state_versions.version + 1,
    unread_count = MAX(0, mail_state_versions.unread_count + excluded.unread_count),
    starred_count = MAX(0, mail_state_versions.starred_count + excluded.starred_count),
    sent_count = MAX(0, mail_state_versions.sent_count + excluded.sent_count),
    trash_count = MAX(0, mail_state_versions.trash_count + excluded.trash_count),
    updated_at = excluded.updated_at;
END;

DROP TRIGGER IF EXISTS trg_messages_mail_state_delete;
CREATE TRIGGER trg_messages_mail_state_delete
AFTER DELETE ON messages BEGIN
  INSERT INTO mail_state_versions (
    user_id, version, updated_at,
    unread_count, starred_count, sent_count, trash_count
  )
  SELECT
    mb.user_id,
    1,
    unixepoch(),
    -CASE
      WHEN OLD.direction = 'incoming' AND OLD.folder = 'inbox' AND OLD.is_read = 0
      THEN 1 ELSE 0
    END,
    -CASE WHEN OLD.is_starred = 1 AND OLD.folder != 'trash' THEN 1 ELSE 0 END,
    -CASE WHEN OLD.direction = 'outgoing' AND OLD.folder = 'sent' THEN 1 ELSE 0 END,
    -CASE WHEN OLD.folder = 'trash' THEN 1 ELSE 0 END
  FROM mailboxes mb
  WHERE mb.address = OLD.mailbox_address
  ON CONFLICT(user_id) DO UPDATE SET
    version = mail_state_versions.version + 1,
    unread_count = MAX(0, mail_state_versions.unread_count + excluded.unread_count),
    starred_count = MAX(0, mail_state_versions.starred_count + excluded.starred_count),
    sent_count = MAX(0, mail_state_versions.sent_count + excluded.sent_count),
    trash_count = MAX(0, mail_state_versions.trash_count + excluded.trash_count),
    updated_at = excluded.updated_at;
END;

CREATE INDEX idx_messages_search_backfill
  ON messages(id) WHERE body_key IS NOT NULL;

PRAGMA optimize;
