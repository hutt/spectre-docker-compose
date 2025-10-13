#!/bin/bash
# Löscht den temporären 'superuser', überträgt seine Posts
# und räumt alle temporären Dateien auf.

set -e

echo "==> [INIT] Führe Cleanup durch..."

STAFF_ACCESS_TOKEN=$(cat /var/lib/ghost/content/bootstrap/staff_access_token)
API_URL="http://localhost:2368/ghost/api/admin"

# ID des neuen Users aus der temporären Datei lesen
NEW_USER_ID=$(cat /tmp/new_user_id)

echo "==> [INIT] Lösche 'superuser' und übertrage Inhalte an neuen User..."
SUPERUSER_ID=$(curl -s "${API_URL}/users/slug/superuser/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" | jq -r '.users[0].id')
curl -s -X DELETE "${API_URL}/users/${SUPERUSER_ID}/?transfer_posts=${NEW_USER_ID}" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" > /dev/null

echo "==> [INIT] Lösche temporäre Dateien..."
rm /var/lib/ghost/content/bootstrap/staff_access_token
rm -f /tmp/spectre.zip
rm -f /tmp/new_user_id
