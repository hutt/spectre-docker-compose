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
# ==                    GHOST JWT TOKEN GENERATION                           ==
# ==============================================================================
generate_ghost_jwt() {
    local ADMIN_API_KEY="$1"
    
    # Split the key into ID and SECRET
    IFS=':' read -r KEY_ID SECRET <<< "$ADMIN_API_KEY"
    
    # Prepare header and payload
    NOW=$(date +%s)
    FIVE_MINS=$((NOW + 300))
    
    HEADER="{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"$KEY_ID\"}"
    PAYLOAD="{\"iat\":$NOW,\"exp\":$FIVE_MINS,\"aud\":\"/admin/\"}"
    
    # Helper function for base64 URL encoding
    base64_url_encode() {
        openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
    }
    
    # Encode header and payload
    HEADER_B64=$(echo -n "$HEADER" | base64_url_encode)
    PAYLOAD_B64=$(echo -n "$PAYLOAD" | base64_url_encode)
    
    # Create signature using the hex-decoded secret
    SIGNATURE=$(echo -n "${HEADER_B64}.${PAYLOAD_B64}" | openssl dgst -binary -sha256 -mac HMAC -macopt hexkey:$SECRET | base64_url_encode)
    
    # Output the complete JWT token
    echo "${HEADER_B64}.${PAYLOAD_B64}.${SIGNATURE}"
}

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

    STAFF_ACCESS_TOKEN=$(tr -d '[:space:]' < "$BOOTSTRAP_TOKEN_FILE")
    JWT_TOKEN=$(generate_ghost_jwt "$STAFF_ACCESS_TOKEN")

    API_URL="https://${DOMAIN}/ghost/api/admin"

    echo "==> [API] Installiere und aktiviere Spectre..."
    curl -s -L -o /tmp/spectre.zip "${SPECTRE_ZIP_URL}"
    
    # === KORREKTUR: X-Forwarded-* Header hinzufügen, um Redirects zu vermeiden ===
    curl -s -L -X POST "${API_URL}/themes/upload/" \
        -H "Authorization: Ghost ${JWT_TOKEN}" \
        -H "Accept-Version: ${GHOST_API_VERSION_ACCEPT}" \
        -H "X-Forwarded-Proto: https" \
        -H "X-Forwarded-Host: ${DOMAIN}" \
        -F "file=@/tmp/spectre.zip" > /dev/null
    
    curl -s -L -X PUT "${API_URL}/themes/spectre/activate/" \
        -H "Authorization: Ghost ${JWT_TOKEN}" \
        -H "Accept-Version: ${GHOST_API_VERSION_ACCEPT}" \
        -H "X-Forwarded-Proto: https" \
        -H "X-Forwarded-Host: ${DOMAIN}" > /dev/null

    echo "==> [API] Setze Blog-Titel..."
    SETTINGS_PAYLOAD=$(printf '{"settings":[{"key":"title","value":"%s"}]}' "$GHOST_SETUP_BLOG_TITLE")
    curl -s -L -X PUT "${API_URL}/settings/" \
        -H "Authorization: Ghost ${JWT_TOKEN}" \
        -H "Accept-Version: ${GHOST_API_VERSION_ACCEPT}" \
        -H "Content-Type: application/json" \
        -H "X-Forwarded-Proto: https" \
        -H "X-Forwarded-Host: ${DOMAIN}" \
        -d "$SETTINGS_PAYLOAD" > /dev/null

    # === SCHRITT 3: Admin-User über SQLite aktualisieren ===
    echo "==> [INIT] Aktualisiere Admin-Benutzer..."

    # Helfer zum einfachen Escapen von SQL
    sql_escape() { printf "%s" "$1" | sed "s/'/''/g"; }
    
    echo "==> [INIT] Hashe das neue Passwort..."
    NEW_PASSWORD_HASH=$(npx bcryptjs-cli "$GHOST_SETUP_PASSWORD" 10)
    NAME_ESC=$(sql_escape "$GHOST_SETUP_NAME")
    EMAIL_ESC=$(sql_escape "$GHOST_SETUP_EMAIL")
    PASS_ESC=$(sql_escape "$NEW_PASSWORD_HASH")

    # Ghost ordentlich beenden
    echo "==> Beende temporären Ghost-Prozess..."
    kill $GHOST_PID
    wait $GHOST_PID
    
    echo "==> [INIT] Führe SQL-Update aus..."
    sqlite3 "$DB_PATH" "UPDATE users SET name='${NAME_ESC}', email='${EMAIL_ESC}', password='${PASS_ESC}', slug='admin' WHERE slug='superuser';"

    # === SCHRITT 4: AUFRÄUMEN ===
    rm "$BOOTSTRAP_TOKEN_FILE"
    rm -f /tmp/spectre.zip
    
    echo "=================================================="
    echo "==> ERSTEINRICHTUNG ABGESCHLOSSEN."
    echo "=================================================="
fi

# ==============================================================================
# ==                      AN HAUPTPROZESS ÜBERGEBEN                           ==
# ==============================================================================
echo "==> Übergebe Kontrolle an den Ghost-Hauptprozess..."
exec node current/index.js "$@"
