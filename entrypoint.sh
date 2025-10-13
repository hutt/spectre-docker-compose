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

# ==============================================================================
# ==                                BOOTSTRAP                                 ==
# ==============================================================================
BOOTSTRAP_TOKEN_FILE="/var/lib/ghost/content/bootstrap/staff_access_token"

if [ -f "$BOOTSTRAP_TOKEN_FILE" ]; then
    echo "=================================================="
    echo "==> ERSTEINRICHTUNG WIRD DURCHGEFÜHRT..."
    echo "=================================================="

    # === SCHRITT 1: DATEISYSTEM VORBEREITEN ===
    echo "==> [INIT] Stelle Standard-Verzeichnisstruktur sicher..."
    baseDir="$GHOST_INSTALL/content.orig"
    for src in "$baseDir"/*/ "$baseDir"/themes/*; do
        src="${src%/}"
        target="$GHOST_CONTENT/${src#$baseDir/}"
        mkdir -p "$(dirname "$target")"
        if [ ! -e "$target" ]; then
            tar -cC "$(dirname "$src")" "$(basename "$src")" | tar -xC "$(dirname "$target")"
        fi
    done
    
    echo "==> [INIT] Kopiere vorbereitete Datenbank und Routen..."
    DB_PATH="/var/lib/ghost/content/data/ghost.db"
    cp /var/lib/ghost/content/bootstrap/ghost.db "$DB_PATH"
    cp /var/lib/ghost/content/bootstrap/routes.yaml /var/lib/ghost/content/settings/routes.yaml
    chown node:node "$DB_PATH" /var/lib/ghost/content/settings/routes.yaml

    # === SCHRITT 2: RESTLICHE KONFIGURATION PER API ===
    echo "==> [INIT] Starte Ghost temporär für API-Konfiguration..."
    node current/index.js &
    GHOST_PID=$!
    
    # Robuste Warteschleife...
    API_HEALTH_CHECK_URL="http://localhost:2368/ghost/api/admin/site/"
    echo "==> Warte, bis die Ghost Admin API bereit ist..."
    n=0
    until [ "$n" -ge 45 ] || curl -s --head --fail "$API_HEALTH_CHECK_URL" > /dev/null; do
        echo -n "."
        sleep 2
        n=$((n+1))
    done
    echo ""
    if ! curl -s --head --fail -o /dev/null "$API_HEALTH_CHECK_URL"; then
        echo "FEHLER: Ghost Admin API konnte nicht rechtzeitig gestartet werden. Breche ab."
        kill $GHOST_PID
        exit 1
    fi
    echo "==> Ghost Admin API ist bereit."

    # API-Aufrufe für Theme und Blog-Titel
    STAFF_ACCESS_TOKEN=$(cat $BOOTSTRAP_TOKEN_FILE)
    API_URL="http://localhost:2368/ghost/api/admin"

    echo "==> [API] Installiere und aktiviere Spectre-Theme..."
    curl -s -L -o /tmp/spectre.zip "${SPECTRE_ZIP_URL}"
    curl -s -X POST "${API_URL}/themes/upload/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" -F "file=@/tmp/spectre.zip" > /dev/null
    curl -s -X PUT "${API_URL}/themes/spectre/activate/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" > /dev/null

    echo "==> [API] Setze Blog-Titel..."
    SETTINGS_PAYLOAD=$(printf '{"settings":[{"key":"title","value":"%s"}]}' "$GHOST_SETUP_BLOG_TITLE")
    curl -s -X PUT "${API_URL}/settings/" -H "Authorization: Ghost ${STAFF_ACCESS_TOKEN}" -H "Content-Type: application/json" -d "$SETTINGS_PAYLOAD" > /dev/null

    # === SCHRITT 3: Admin-User über SQLite aktualisieren ===
    echo "==> [INIT] Aktualisiere Admin-Benutzer..."
    
    echo "==> [INIT] Hashe das neue Passwort..."
    NEW_PASSWORD_HASH=$(npx bcryptjs-cli '$GHOST_SETUP_PASSWORD' 10)
    
    echo "==> [INIT] Führe SQL-Update aus..."
    sqlite3 "$DB_PATH" "UPDATE users SET name='$GHOST_SETUP_NAME', email='$GHOST_SETUP_EMAIL', password='$NEW_PASSWORD_HASH' WHERE id='1';"

    # === SCHRITT 4: AUFRÄUMEN ===
    rm "$BOOTSTRAP_TOKEN_FILE"
    rm -f /tmp/spectre.zip
    
    echo; echo "==> Beende temporären Ghost-Prozess..."
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
