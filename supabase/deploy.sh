#!/usr/bin/env bash
# Deploys the chat/process-file/embed Edge Functions and sets the
# ANTHROPIC_API_KEY secret. Requires SUPABASE_ACCESS_TOKEN and
# SUPABASE_PROJECT_REF in the environment.
set -euo pipefail

: "${SUPABASE_ACCESS_TOKEN:?Set SUPABASE_ACCESS_TOKEN (personal access token)}"
: "${SUPABASE_PROJECT_REF:?Set SUPABASE_PROJECT_REF (e.g. abcdefghij from https://abcdefghij.supabase.co)}"
: "${ANTHROPIC_API_KEY:?Set ANTHROPIC_API_KEY}"

cd "$(dirname "$0")"

supabase functions deploy chat process-file embed \
  --project-ref "$SUPABASE_PROJECT_REF" --use-api

supabase secrets set ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --project-ref "$SUPABASE_PROJECT_REF"

echo "Deployed. Functions live at:"
echo "  https://${SUPABASE_PROJECT_REF}.supabase.co/functions/v1/chat"
echo "  https://${SUPABASE_PROJECT_REF}.supabase.co/functions/v1/process-file"
echo "  https://${SUPABASE_PROJECT_REF}.supabase.co/functions/v1/embed"
