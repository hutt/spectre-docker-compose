#!/bin/bash
# Lädt das Spectre-Theme herunter, lädt es in Ghost hoch und aktiviert es.

set -e

echo "==> [INIT] Installiere und aktiviere Spectre-Theme..."

STAFF_ACCESS_TOKEN=$(cat /var/lib/ghost/content/bootstrap/staff_access_token)
API_URL="http://localhost:2368/ghost/api/admin"

# Theme herunterladen
curl -s -L -o /tmp/spectre.zip "${SPECTRE_ZIP_URL}"

# Theme hochladen und aktivieren
curl -s -X POST "${API_URL}/themes/upload/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" -F "file=@/tmp/spectre.zip" > /dev/null
curl -s -X PUT "${API_URL}/themes/spectre/activate/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" > /dev/null
