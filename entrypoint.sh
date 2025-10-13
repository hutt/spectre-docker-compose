#!/bin/bash
set -e

# ==============================================================================
# ==                      USER- & PERMISSION-HANDLING                         ==
# ==============================================================================
if [ "$(id -u)" = '0' ]; then
    echo "==> Skript als root gestartet. Wechsle zum 'node' Benutzer..."
    chown -R node:node /var/lib/ghost/content
    exec gosu node "$0" "$@"
fi
echo "==> Skript läuft jetzt als Benutzer: $(whoami)"

# ==============================================================================
# ==                        ERSTEINRICHTUNG (BOOTSTRAP)                       ==
# ==============================================================================
BOOTSTRAP_TOKEN_FILE="/var/lib/ghost/content/bootstrap/staff_access_token"

if [ -f "$BOOTSTRAP_TOKEN_FILE" ]; then
    echo "=================================================="
    echo "==> ERSTEINRICHTUNG WIRD DURCHGEFÜHRT..."
    echo "=================================================="

    echo "==> Kopiere Datenbank und Routen-Datei..."
    mkdir -p /var/lib/ghost/content/data
    mkdir -p /var/lib/ghost/content/settings
    cp /var/lib/ghost/content/bootstrap/ghost.db /var/lib/ghost/content/data/ghost.db
    cp /var/lib/ghost/content/bootstrap/routes.yaml /var/lib/ghost/content/settings/routes.yaml

    echo "==> Starte Ghost temporär für Konfiguration..."
    node current/index.js &
    GHOST_PID=$!

    echo "==> Warte, bis Ghost Admin API bereit ist..."
    n=0
    until [ "$n" -ge 30 ] || curl -s --fail http://localhost:2368/ghost/; do
        echo -n "."
        sleep 2
        n=$((n+1))
    done
    echo ""
    if ! curl -s --fail -o /dev/null http://localhost:2368/ghost/; then
        echo "FEHLER: Ghost konnte nicht temporär gestartet werden. Breche ab."
        kill $GHOST_PID
        exit 1
    fi
    echo "==> Ghost ist bereit für die Konfiguration."
    
    # ------------------ API-KONFIGURATION ------------------
    STAFF_ACCESS_TOKEN=$(cat $BOOTSTRAP_TOKEN_FILE)
    API_URL="http://localhost:2368/ghost/api/admin"

    echo "==> Erstelle neuen Admin-Benutzer: ${GHOST_SETUP_EMAIL}"
    NEW_USER_PAYLOAD=$(printf '{"users":[{"name":"%s","email":"%s","password":"%s","roles":["Administrator"]}]}' "$GHOST_SETUP_NAME" "$GHOST_SETUP_EMAIL" "$GHOST_SETUP_PASSWORD")
    NEW_USER_RESPONSE=$(curl -s -X POST "${API_URL}/users/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" -H "Content-Type: application/json" -d "$NEW_USER_PAYLOAD")
    NEW_USER_ID=$(echo "$NEW_USER_RESPONSE" | jq -r '.users[0].id')

    echo "==> Mache neuen Benutzer zum Owner..."
    OWNER_PAYLOAD='{"users":[{"roles":["Owner"]}]}'
    curl -s -X PUT "${API_URL}/users/${NEW_USER_ID}/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" -H "Content-Type: application/json" -d "$OWNER_PAYLOAD" > /dev/null

    echo "==> Lade Spectre-Theme von ${SPECTRE_ZIP_URL} herunter..."
    curl -s -L -o /tmp/spectre.zip "${SPECTRE_ZIP_URL}"

    echo "==> Lade Theme hoch und aktiviere es..."
    curl -s -X POST "${API_URL}/themes/upload/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" -F "file=@/tmp/spectre.zip" > /dev/null
    curl -s -X PUT "${API_URL}/themes/spectre/activate/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" > /dev/null

    echo "==> Setze Blog-Titel auf: ${GHOST_SETUP_BLOG_TITLE}"
    SETTINGS_PAYLOAD=$(printf '{"settings":[{"key":"title","value":"%s"}]}' "$GHOST_SETUP_BLOG_TITLE")
    curl -s -X PUT "${API_URL}/settings/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" -H "Content-Type: application/json" -d "$SETTINGS_PAYLOAD" > /dev/null

    echo "==> Lösche temporären 'superuser' und übertrage Inhalte..."
    SUPERUSER_ID=$(curl -s "${API_URL}/users/slug/superuser/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" | jq -r '.users[0].id')
    curl -s -X DELETE "${API_URL}/users/${SUPERUSER_ID}/?transfer_posts=${NEW_USER_ID}" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" > /dev/null
    # -------------------------------------------------------

    echo "==> Räume auf..."
    rm "$BOOTSTRAP_TOKEN_FILE"
    rm -f /tmp/spectre.zip

    echo "==> Beende temporären Ghost-Prozess..."
    kill $GHOST_PID
    wait $GHOST_PID
    
    echo "=================================================="
    echo "==> ERSTEINRICHTUNG ABGESCHLOSSEN."
    echo "=================================================="
fi


# ==============================================================================
# ==                           FINALE AUSFÜHRUNG                            ==
# ==============================================================================
echo "==> Übergebe Kontrolle an den Ghost-Hauptprozess..."
exec node current/index.js "$@"
