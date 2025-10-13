#!/bin/bash
# Kopiert die vorbereitete Datenbank und Routen-Datei ins Ghost-Content-Verzeichnis.

set -e

echo "==> [INIT] Kopiere Datenbank und Routen-Datei..."

CONTENT_DIR="/var/lib/ghost/content"
BOOTSTRAP_DIR="$CONTENT_DIR/bootstrap"

# Sicherstellen, dass die Zielverzeichnisse existieren
mkdir -p "$CONTENT_DIR/data"
mkdir -p "$CONTENT_DIR/settings"

# Dateien kopieren
cp "$BOOTSTRAP_DIR/ghost.db" "$CONTENT_DIR/data/ghost.db"
cp "$BOOTSTRAP_DIR/routes.yaml" "$CONTENT_DIR/settings/routes.yaml"

# Korrekte Berechtigungen setzen (obwohl der übergeordnete Entrypoint
# dies für das ganze Verzeichnis tun sollte, ist es eine gute Praxis, es hier zu wiederholen)
chown -R node:node "$CONTENT_DIR/data"
chown -R node:node "$CONTENT_DIR/settings"
