-- Support safe client-side retry of a send: the client generates the
-- message id itself and resends the same id on retry. The chat function
-- (see supabase/functions/chat/index.ts) uses this to make retries
-- idempotent — resuming a half-finished turn instead of creating a
-- duplicate user message or double-charging a Claude call.

alter table messages
  add column replies_to_message_id uuid references messages(id) on delete set null;

comment on column messages.replies_to_message_id is
  'For agent messages: the user message this replies to. Lets a retried '
  'send detect "already got a reply" and short-circuit instead of calling '
  'Claude again.';

create index idx_messages_replies_to on messages(replies_to_message_id);
