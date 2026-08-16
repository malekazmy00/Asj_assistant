-- process-file now processes documents in the background (see
-- process-file/index.ts), and a ~2000-file bulk import is coming — without
-- live updates, watching files move from pending -> processing -> completed
-- in the Library screen would mean manually pull-to-refreshing repeatedly.
alter publication supabase_realtime add table files;
