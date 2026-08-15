# Setup & deployment

## 1. Environment variables

| Variable | Used by | Where it comes from |
|---|---|---|
| `SUPABASE_URL` | Edge Functions, worker, Flutter build | Supabase dashboard → Project Settings → API |
| `SUPABASE_SERVICE_ROLE_KEY` | Edge Functions, worker (never ships to the app) | same page |
| `SUPABASE_ANON_KEY` | Flutter app build | same page |
| `ANTHROPIC_API_KEY` | `chat` Edge Function only | console.anthropic.com |
| `HF_TOKEN` | worker, only once real WhisperX is wired in | huggingface.co settings → Access Tokens (needs the pyannote gated-model terms accepted) |

Local copies:
- Root `.env` — used only by ad-hoc scripts/testing in this repo, never
  committed.
- `app/dart_define.json` — `SUPABASE_URL` / `SUPABASE_ANON_KEY`, consumed by
  `flutter build` via `--dart-define-from-file`. Template at
  `app/dart_define.example.json`.
- `worker/.env` — see `worker/.env.example`.

## 2. Database schema

Apply `supabase/migrations/0001_init.sql` once, against the project's
Postgres connection string (Project Settings → Database → Connection
string, "URI" / direct connection):

```bash
psql "$DATABASE_URL" -f supabase/migrations/0001_init.sql
```

(or paste the file into the Supabase Dashboard's SQL Editor and run it —
equivalent, no CLI needed).

This enables `pgvector`, creates all tables, sets up permissive v1 RLS
policies (anon key = the one user, no login system), creates the `uploads`
Storage bucket, and seeds one row in `engineers` for the business owner.

## 3. Edge Functions

Requires the Supabase CLI (already vendored for this session at
`/home/user/sdk/supabase-cli/supabase`) and a **personal access token**
(supabase.com/dashboard/account/tokens) — separate from the keys above,
only used for deployment.

```bash
export SUPABASE_ACCESS_TOKEN=<personal access token>
cd supabase
supabase functions deploy chat process-file embed \
  --project-ref <your-project-ref> --use-api

# Set the one secret the functions need that isn't auto-injected by Supabase:
supabase secrets set ANTHROPIC_API_KEY=<key> --project-ref <your-project-ref>
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are automatically available
inside Edge Functions — no need to set those as secrets.

## 4. WhisperX worker

Stubbed by default (see `worker/README.md`). To run it:

```bash
cd worker
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY
python main.py
```

## 5. Building the APK

```bash
export PATH="/home/user/sdk/flutter/bin:/home/user/sdk/android/platform-tools:$PATH"
export ANDROID_HOME=/home/user/sdk/android ANDROID_SDK_ROOT=/home/user/sdk/android
cd app
flutter build apk --release --dart-define-from-file=dart_define.json
```

Output: `app/build/app/outputs/flutter-apk/app-release.apk`.

The release build is signed with a self-signed keystore at
`app/android/keystore/release.keystore` (config in `app/android/key.properties`,
both gitignored — see `app/android/key.properties.example`). This is fine
for sideloading onto your own device; it is not intended for Play Store
distribution.

To install: copy the APK to the phone and open it (enable "install unknown
apps" for whichever app you copy it with, e.g. Files or a chat app).
