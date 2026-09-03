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
