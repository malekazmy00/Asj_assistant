-- Registers `messages` with Supabase's realtime publication. Without this,
-- supabase-flutter's `.stream()` only ever delivers its initial snapshot —
-- no INSERT/UPDATE events ever arrive, so new agent replies silently never
-- appear in the chat UI until the app is fully restarted (which re-fetches
-- fresh instead of relying on a live subscription).
alter publication supabase_realtime add table messages;
