#!/bin/bash
# Setzt den Blog-Titel gemäß der Umgebungsvariable.

set -e

echo "==> [INIT] Setze Blog-Titel..."

STAFF_ACCESS_TOKEN=$(cat /var/lib/ghost/content/bootstrap/staff_access_token)
API_URL="http://localhost:2368/ghost/api/admin"

SETTINGS_PAYLOAD=$(printf '{"settings":[{"key":"title","value":"%s"}]}' "$GHOST_SETUP_BLOG_TITLE")
curl -s -X PUT "${API_URL}/settings/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" -H "Content-Type: application/json" -d "$SETTINGS_PAYLOAD" > /dev/null
