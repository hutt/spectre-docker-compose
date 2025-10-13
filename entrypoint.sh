#!/bin/bash

set -e

BOOTSTRAP_SOURCE_DIR="/var/lib/ghost/bootstrap_files"
BOOTSTRAP_TOKEN_FILE="/var/lib/ghost/content/bootstrap/staff_access_token"
CONTENT_DIR="/var/lib/ghost/content"

# --- Logik für den ersten Start ---
if [ -f "$BOOTSTRAP_TOKEN_FILE" ]; then
    echo "=================================================="
    echo "==> ERSTEINRICHTUNG WIRD DURCHGEFÜHRT..."
    echo "=================================================="

    # 1. Vorbereitungen: Kopieren der Datenbank und Routen
    echo "==> Kopiere Datenbank und Routen-Datei..."
    mkdir -p ${CONTENT_DIR}/data
    mkdir -p ${CONTENT_DIR}/settings

    cp ${BOOTSTRAP_SOURCE_DIR}/ghost.db ${CONTENT_DIR}/data/ghost.db
    cp ${BOOTSTRAP_SOURCE_DIR}/routes.yaml ${CONTENT_DIR}/settings/routes.yaml

    echo "==> Korrigiere Dateiberechtigungen..."
    chown -R node:node ${CONTENT_DIR}/data
    chown -R node:node ${CONTENT_DIR}/settings

    # 2. Ghost im Hintergrund starten, um Migrationen auszuführen
    echo "==> Starte Ghost temporär für Datenbank-Migrationen..."
    # Wir leiten die Ausgabe nach /dev/null um, damit sie nicht stört
    node current/index.js &
    # Speichern der Prozess-ID (PID), um Ghost später zu beenden
    GHOST_PID=$!

    # 3. Warten, bis der Ghost-Admin erreichbar ist
    echo "Warte, bis Ghost Admin API bereit ist..."
    while ! curl -s -o /dev/null http://localhost:2368/ghost/; do
        echo -n "."
        sleep 1
    done
    echo ""
    echo "==> Ghost ist bereit für die Konfiguration."

    # 4. API-Konfiguration durchführen
    STAFF_ACCESS_TOKEN=$(cat $BOOTSTRAP_TOKEN_FILE)
    API_URL="http://localhost:2368/ghost/api/admin"

    echo "==> Erstelle neuen Admin-Benutzer: ${GHOST_SETUP_EMAIL}"
    # JSON-Payload für den neuen Benutzer erstellen
    NEW_USER_PAYLOAD=$(printf '{
        "users": [{
            "name": "%s",
            "email": "%s",
            "password": "%s",
            "roles": ["Administrator"]
        }]
    }' "$GHOST_SETUP_NAME" "$GHOST_SETUP_EMAIL" "$GHOST_SETUP_PASSWORD")

    # Neuen Benutzer per API anlegen und seine ID extrahieren
    NEW_USER_RESPONSE=$(curl -s -X POST "${API_URL}/users/" \
        -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$NEW_USER_PAYLOAD")
    NEW_USER_ID=$(echo "$NEW_USER_RESPONSE" | jq -r '.users[0].id')

    echo "==> Mache neuen Benutzer zum Owner..."
    OWNER_PAYLOAD=$(printf '{
        "users": [{
            "roles": ["Owner"]
        }]
    }')
    curl -s -X PUT "${API_URL}/users/${NEW_USER_ID}/" \
        -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$OWNER_PAYLOAD" > /dev/null

    echo "==> Lade Spectre-Theme von ${SPECTRE_ZIP_URL} herunter..."
    curl -s -L -o /tmp/spectre.zip "${SPECTRE_ZIP_URL}"

    echo "==> Lade Theme hoch und aktiviere es..."
    curl -s -X POST "${API_URL}/themes/upload/" \
        -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" \
        -F "file=@/tmp/spectre.zip" > /dev/null
    
    # Der Theme-Name ist im Fall von Spectre "spectre"
    curl -s -X PUT "${API_URL}/themes/spectre/activate/" \
        -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" > /dev/null

    echo "==> Setze Blog-Titel auf: ${GHOST_SETUP_BLOG_TITLE}"
    SETTINGS_PAYLOAD=$(printf '{
        "settings": [{
            "key": "title",
            "value": "%s"
        }]
    }' "$GHOST_SETUP_BLOG_TITLE")
    curl -s -X PUT "${API_URL}/settings/" \
        -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$SETTINGS_PAYLOAD" > /dev/null

    echo "==> Lösche temporären 'superuser' und übertrage Inhalte..."
    # ID des superuser holen
    SUPERUSER_ID=$(curl -s "${API_URL}/users/slug/superuser/" \
        -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" | jq -r '.users[0].id')
    
    # Superuser löschen und Inhalte an den neuen Owner übertragen
    curl -s -X DELETE "${API_URL}/users/${SUPERUSER_ID}/?transfer_posts=${NEW_USER_ID}" \
        -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" > /dev/null

    # 5. Aufräumen
    echo "==> Räume auf..."
    rm -rf "$BOOTSTRAP_SOURCE_DIR"
    rm /tmp/spectre.zip

    # Temporären Ghost-Prozess beenden
    kill $GHOST_PID
    wait $GHOST_PID
    
    echo "=================================================="
    echo "==> ERSTEINRICHTUNG ABGESCHLOSSEN."
    echo "==> Starte Ghost jetzt im normalen Modus."
    echo "=================================================="

# --- Logik für den normalen Start ---
else
    echo "==> Übergebe Kontrolle an den originalen Ghost Entrypoint..."
    exec /usr/local/bin/docker-entrypoint.sh "$@"
fi
