-- Call recordings automatically get their own dedicated chat (see
-- chat_screen.dart's _handleAttach) instead of being dropped into whatever
-- chat happens to be open, so the agent can focus fully on that one
-- recording. seed_file_id marks which file, if any, a conversation was
-- created *for* — process-file's recording_kickoff helper uses it to know
-- when to post an opening message once that file's transcript is ready
-- (and to make sure it never does so for an ordinary conversation that
-- just happens to have a recording attached partway through).
alter table conversations add column seed_file_id uuid references files(id) on delete set null;
