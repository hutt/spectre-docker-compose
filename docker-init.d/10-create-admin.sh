#!/bin/bash
# Erstellt den neuen Admin-User per Ghost Admin API, macht ihn zum Owner
# und speichert seine ID für das Cleanup-Skript.

set -e

echo "==> [INIT] Erstelle neuen Admin-Benutzer..."

STAFF_ACCESS_TOKEN=$(cat /var/lib/ghost/content/bootstrap/staff_access_token)
API_URL="http://localhost:2368/ghost/api/admin"

NEW_USER_PAYLOAD=$(printf '{"users":[{"name":"%s","email":"%s","password":"%s","roles":["Administrator"]}]}' "$GHOST_SETUP_NAME" "$GHOST_SETUP_EMAIL" "$GHOST_SETUP_PASSWORD")
NEW_USER_RESPONSE=$(curl -s -X POST "${API_URL}/users/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" -H "Content-Type: application/json" -d "$NEW_USER_PAYLOAD")

NEW_USER_ID=$(echo "$NEW_USER_RESPONSE" | jq -r '.users[0].id')
echo "$NEW_USER_ID" > /tmp/new_user_id

echo "==> [INIT] Mache neuen Benutzer zum Owner..."
OWNER_PAYLOAD='{"users":[{"roles":["Owner"]}]}'
curl -s -X PUT "${API_URL}/users/${NEW_USER_ID}/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" -H "Content-Type: application/json" -d "$OWNER_PAYLOAD" > /dev/null
