-- ============================================================================
-- Email notifications  (Resend)
-- Staff sign in with internal @assettrack.local addresses, which are not real
-- inboxes. notify_email holds each person's real address for notifications.
-- Safe to run more than once.
-- ============================================================================

alter table public.profiles add column if not exists notify_email text;

-- The notifications table already exists (schema.sql). Nothing else to add:
-- the sender logs each email there with channel='email'.
