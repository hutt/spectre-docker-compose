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
# ==                        ERSTEINRICHTUNG (BOOTSTRAP)                       ==
# ==============================================================================
BOOTSTRAP_TOKEN_FILE="/var/lib/ghost/content/bootstrap/staff_access_token"

# Führe die Initialisierung nur aus, wenn die Bootstrap-Datei existiert
if [ -f "$BOOTSTRAP_TOKEN_FILE" ]; then
    echo "=================================================="
    echo "==> ERSTEINRICHTUNG WIRD DURCHGEFÜHRT..."
    echo "=================================================="

    # === SCHRITT 1: DATEI-SYSTEM VORBEREITEN (VOR GHOST-START!) ===
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
    # Dieser Befehl überschreibt die leere DB aus dem vorherigen Schritt
    cp /var/lib/ghost/content/bootstrap/ghost.db /var/lib/ghost/content/data/ghost.db
    cp /var/lib/ghost/content/bootstrap/routes.yaml /var/lib/ghost/content/settings/routes.yaml
    # Berechtigungen sicherstellen
    chown node:node /var/lib/ghost/content/data/ghost.db
    chown node:node /var/lib/ghost/content/settings/routes.yaml

    # === SCHRITT 2: GHOST TEMPORÄR STARTEN & KONFIGURIEREN ===
    echo "==> [INIT] Starte Ghost temporär für API-Konfiguration..."
    node current/index.js &
    GHOST_PID=$!
    
    # Robuste Warteschleife
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

    # Führe die einzelnen Init-Skripte aus
    if [ -d "/docker-init.d" ]; then
        for f in /docker-init.d/*; do
            case "$f" in
                *.sh)  echo; echo "==> Führe Init-Skript aus: $f"; . "$f" ;;
                *)     echo "==> Ignoriere $f" ;;
            esac
        done
    fi

    # Aufräumen
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
