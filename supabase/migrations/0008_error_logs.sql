-- Client-side error/crash telemetry, so failures (including native Android
-- crashes, which otherwise leave zero trace without adb access) can be
-- queried here directly instead of pulled off the device by hand each time.
--
-- device_info is jsonb rather than a flat string — same reasoning as the
-- rest of this schema's jsonb columns: structured and queryable (e.g.
-- "show me every crash on Android 12") without parsing a blob later, and
-- it's easy to add fields (manufacturer, brand, sdk_int, ...) without a
-- migration.
create table error_logs (
  id                 uuid primary key default gen_random_uuid(),
  created_at         timestamptz not null default now(),
  level              text not null check (level in ('fatal', 'error', 'warning')),
  source             text not null check (source in ('dart', 'native')),
  error_type         text,
  message            text,
  stack_trace        text,
  screen_or_action   text,          -- what the user was doing, e.g. "tapped mic button"
  app_version        text,
  device_info        jsonb,         -- {"os_version": "...", "model": "...", "manufacturer": "..."}
  user_id            uuid references engineers(id) on delete set null
);

create index idx_error_logs_created_at on error_logs(created_at desc);
create index idx_error_logs_level on error_logs(level);
create index idx_error_logs_source on error_logs(source);

comment on table error_logs is
  'Client-side error/crash telemetry. Not part of the product-facing '
  'schema — purely operational, queried by the developer/owner directly.';

-- RLS: the Flutter app authenticates with the anon key (no login, v1), and
-- it's the one thing that needs to WRITE here (both the direct Dart-error
-- path and the "upload a pending native crash file from last launch"
-- path) — so anon gets insert-only. It cannot read, update, or delete a
-- single row, which is what "not exposed publicly" actually means here:
-- nobody can browse or tamper with the log via the anon key, they can only
-- append to it. Reading is service-role only (Studio, this session, or a
-- future admin view backed by an Edge Function).
alter table error_logs enable row level security;

create policy "anon can insert error logs" on error_logs
  for insert to anon
  with check (true);
