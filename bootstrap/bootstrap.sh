#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Ghost Bootstrap Script
# ============================================================================
# Automatisiert das Setup einer frischen Ghost-Installation:
# - Initialer Setup (Owner-Account erstellen)
# - Custom Integration mit Admin API Key erstellen
# - Theme hochladen und aktivieren
# - Routes-Konfiguration hochladen
# - Navigation konfigurieren
# - Standard-Seiten und Beispiel-Posts erstellen
# ============================================================================

# Konfiguration
BASE_URL="${GHOST_ADMIN_URL:-http://ghost:2368}"
COOKIE="$(mktemp)"
ROUTES_FILE="/bootstrap/routes.yaml"
GENERATED_KEYS_FILE="/bootstrap/generated.keys.env"
UA="Mozilla/5.0 (compatible; Ghost-Bootstrap/1.0)"

# Log-Funktion
log() { printf '%s %s\n' "$(date +'%F %T')" "$*" >&2; }

# ============================================================================
# Hilfsfunktionen
# ============================================================================

# Wartet bis Ghost erreichbar ist (max 4 Minuten)
wait_for_ghost() {
  log "Warte auf Ghost unter ${BASE_URL} ..."
  for i in $(seq 1 120); do
    if curl -sf -c "$COOKIE" -b "$COOKIE" \
         -H "Accept: application/json" -H "User-Agent: $UA" \
         "${BASE_URL}/ghost/api/admin/site/" >/dev/null 2>&1; then
      log "Ghost erreichbar."
      return 0
    fi
    sleep 2
  done
  log "FEHLER: Ghost wurde nicht rechtzeitig erreichbar."
  exit 1
}

# Prüft ob das initiale Setup noch aussteht
# Gibt "yes" oder "no" zurück
setup_needed() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIE" -b "$COOKIE" \
    -H "Accept: application/json" -H "User-Agent: $UA" \
    "${BASE_URL}/ghost/api/admin/authentication/setup/")
  
  if [ "$code" = "404" ]; then
    echo "no"
  else
    echo "yes"
  fi
}

# Führt das initiale Ghost-Setup durch
# Erstellt den Owner-Account und setzt den Blog-Titel
# WICHTIG: Benötigt KEINEN CSRF-Token!
do_setup() {
  log "Führe Initial-Setup durch ..."
  
  local response
  response=$(curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Content-Type: application/json" \
    -H "Origin: ${BASE_URL}" \
    -H "User-Agent: $UA" \
    -w "\n%{http_code}" \
    -X POST \
    -d "$(jq -n --arg n "$GHOST_SETUP_NAME" \
                 --arg e "$GHOST_SETUP_EMAIL" \
                 --arg p "$GHOST_SETUP_PASSWORD" \
                 --arg t "$GHOST_SETUP_BLOG_TITLE" \
          '{setup:[{name:$n,email:$e,password:$p,blogTitle:$t}]}')" \
    "${BASE_URL}/ghost/api/admin/authentication/setup/")
  
  local http_code=$(echo "$response" | tail -n1)
  
  if [ "$http_code" != "201" ]; then
    log "FEHLER: Setup fehlgeschlagen (HTTP $http_code)"
    echo "$response" | head -n-1 >&2
    exit 1
  fi
  
  log "Setup erfolgreich abgeschlossen."
}

# Holt den CSRF-Token aus dem Response-Header
# Funktioniert nur nach erfolgreicher Authentifizierung!
get_csrf() {
  log "Hole CSRF-Token ..."
  local headers token
  headers="$(mktemp)"
  
  # Mehrere Versuche mit verschiedenen Endpoints
  # 1. Versuch: /site/
  curl -s -L -D "$headers" -o /dev/null \
       -c "$COOKIE" -b "$COOKIE" \
       -H "Accept: application/json" \
       -H "User-Agent: $UA" \
       -L \
       "${BASE_URL}/ghost/api/admin/site/" 2>/dev/null || true
  
  token="$(awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2);print $2}' "$headers" | head -n1 || true)"
  
  # 2. Versuch: /users/me/ (falls noch kein Token)
  if [ -z "${token:-}" ]; then
    curl -s -D "$headers" -o /dev/null \
         -c "$COOKIE" -b "$COOKIE" \
         -H "Accept: application/json" \
         -H "User-Agent: $UA" \
         -L \
         "${BASE_URL}/ghost/api/admin/users/me/" 2>/dev/null || true
    
    token="$(awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2);print $2}' "$headers" | head -n1 || true)"
  fi
  
  if [ -z "${token:-}" ]; then
    log "FEHLER: Kein CSRF-Token im Header gefunden."
    exit 1
  fi
  
  log "CSRF-Token erfolgreich abgerufen."
  echo "$token"
}

# Erstellt oder holt eine Custom Integration
# Parameter: $1 = CSRF-Token, $2 = Name der Integration (optional)
# Gibt JSON mit admin_api_key und content_api_key zurück
create_or_get_integration() {
  local csrf="$1"
  local name="${2:-Bootstrap Integration}"
  
  log "Prüfe Integration '$name' ..."
  
  # Bestehende Integrationen lesen
  local existing id
  existing=$(curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Accept: application/json" \
    -H "X-CSRF-Token: ${csrf}" \
    -H "Origin: ${BASE_URL}" \
    -H "User-Agent: $UA" \
    "${BASE_URL}/ghost/api/admin/integrations/?limit=all")
  
  id=$(echo "$existing" | jq -r --arg n "$name" '.integrations[]? | select(.name==$n) | .id' 2>/dev/null || true)
  
  if [ -n "${id:-}" ] && [ "$id" != "null" ]; then
    log "Integration '$name' existiert bereits (ID: $id)."
    echo "$existing" | jq -r --arg n "$name" '
      .integrations[] | select(.name==$n) |
      {
        name,
        id,
        admin_api_key: (.api_keys[]? | select(.type=="admin") | .secret),
        content_api_key: (.api_keys[]? | select(.type=="content") | .secret)
      }'
    return 0
  fi
  
  log "Erstelle Integration '$name' ..."
  local resp
  resp=$(curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Content-Type: application/json" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -H "User-Agent: $UA" \
    -X POST \
    -d "$(jq -n --arg n "$name" '{integrations:[{name:$n}]}')" \
    "${BASE_URL}/ghost/api/admin/integrations/")
  
  echo "$resp" | jq -r '
    .integrations[0] |
    {
      name,
      id,
      admin_api_key: (.api_keys[]? | select(.type=="admin") | .secret),
      content_api_key: (.api_keys[]? | select(.type=="content") | .secret)
    }'
}

# Generiert einen JWT-Token aus einem Admin API Key
# Parameter: $1 = Admin API Key im Format "id:secret"
generate_jwt_token() {
  local api_key="$1"
  local id secret
  IFS=':' read -r id secret <<< "$api_key"
  
  local now exp header payload signature
  now=$(date +%s)
  exp=$((now + 300))  # Token gültig für 5 Minuten
  
  # Header erstellen
  header=$(echo -n '{"alg":"HS256","typ":"JWT","kid":"'$id'"}' | base64 | tr -d '=' | tr '+' '-' | tr '/' '_')
  
  # Payload erstellen
  payload=$(echo -n '{"iat":'$now',"exp":'$exp',"aud":"/admin/"}' | base64 | tr -d '=' | tr '+' '-' | tr '/' '_')
  
  # Signatur erstellen
  signature=$(echo -n "${header}.${payload}" | openssl dgst -binary -sha256 -mac HMAC -macopt hexkey:"$secret" | base64 | tr -d '=' | tr '+' '-' | tr '/' '_')
  
  echo "${header}.${payload}.${signature}"
}

# Speichert die API-Keys in einer Datei
persist_keys() {
  local json="$1"
  local out="${2:-$GENERATED_KEYS_FILE}"
  local ADMIN_KEY CONTENT_KEY
  
  ADMIN_KEY=$(echo "$json" | jq -r '.admin_api_key // empty')
  CONTENT_KEY=$(echo "$json" | jq -r '.content_api_key // empty')
  
  if [ -z "$ADMIN_KEY" ]; then
    log "WARNUNG: Kein Admin API Key in Antwort gefunden."
    return 1
  fi
  
  mkdir -p "$(dirname "$out")"
  {
    echo "# Generated by bootstrap script on $(date -Iseconds)"
    echo "GHOST_ADMIN_API_KEY=$ADMIN_KEY"
    echo "GHOST_CONTENT_API_KEY=$CONTENT_KEY"
  } > "$out"
  
  log "API-Keys gespeichert unter $out"
}

# Lädt gespeicherte API-Keys aus Datei
load_generated_keys() {
  if [ -f "$GENERATED_KEYS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$GENERATED_KEYS_FILE"
    export GHOST_ADMIN_API_KEY="${GHOST_ADMIN_API_KEY:-}"
    export GHOST_CONTENT_API_KEY="${GHOST_CONTENT_API_KEY:-}"
    
    if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
      log "API-Keys aus $GENERATED_KEYS_FILE geladen."
    fi
  fi
}

# Lädt das Theme herunter
download_theme() {
  local url="${SPECTRE_ZIP_URL:-}"
  
  if [ -z "$url" ]; then
    log "FEHLER: SPECTRE_ZIP_URL ist leer."
    exit 1
  fi
  
  log "Lade Theme von: ${url}"
  curl -fsSL "$url" -o /tmp/spectre.zip
}

# Lädt ein Theme zu Ghost hoch
# Parameter: $1 = JWT Token
upload_theme() {
  local jwt="$1"
  log "Lade Theme zu Ghost hoch ..."
  
  local resp
  resp=$(curl -s \
    -H "Authorization: Ghost ${jwt}" \
    -H "User-Agent: $UA" \
    -F "file=@/tmp/spectre.zip" \
    "${BASE_URL}/ghost/api/admin/themes/upload/")
  
  echo "$resp" | tee /tmp/theme-upload.json >/dev/null
  
  if ! jq -e '.themes and .themes[0].name' /tmp/theme-upload.json >/dev/null 2>&1; then
    log "FEHLER: Theme-Upload fehlgeschlagen."
    cat /tmp/theme-upload.json >&2
    exit 1
  fi
  
  jq -r '.themes[0].name' /tmp/theme-upload.json
}

# Aktiviert ein Theme
# Parameter: $1 = JWT Token, $2 = Theme-Name
activate_theme() {
  local jwt="$1"
  local name="$2"
  
  log "Aktiviere Theme: ${name}"
  curl -s \
    -H "Authorization: Ghost ${jwt}" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $UA" \
    -X PUT \
    "${BASE_URL}/ghost/api/admin/themes/${name}/activate/" >/dev/null
}

# Lädt routes.yaml hoch
# Parameter: $1 = JWT Token
upload_routes() {
  local jwt="$1"
  
  if [ ! -f "$ROUTES_FILE" ]; then
    log "WARNUNG: routes.yaml nicht gefunden unter ${ROUTES_FILE}"
    return 0
  fi
  
  log "Importiere routes.yaml ..."
  curl -s \
    -H "Authorization: Ghost ${jwt}" \
    -H "User-Agent: $UA" \
    -F "file=@${ROUTES_FILE};type=text/yaml" \
    -X PUT \
    "${BASE_URL}/ghost/api/admin/settings/routes/yaml" >/dev/null
}

# Aktualisiert die Navigation (Haupt- und Sekundär-Navigation)
# Parameter: $1 = JWT Token
update_navigation() {
  local jwt="$1"
  log "Aktualisiere Navigation ..."
  
  local body='{
    "settings": [
      {
        "key": "navigation",
        "value": [
          { "label": "Start", "url": "/" },
          { "label": "Blog", "url": "/blog/" },
          { "label": "Presse", "url": "/presse/" },
          { "label": "Beispielseite", "url": "/beispielseite/" }
        ]
      },
      {
        "key": "secondary_navigation",
        "value": [
          { "label": "Datenschutz", "url": "/datenschutz/" },
          { "label": "Impressum", "url": "/impressum/" }
        ]
      }
    ]
  }'
  
  curl -s \
    -H "Authorization: Ghost ${jwt}" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $UA" \
    -X PUT \
    -d "$body" \
    "${BASE_URL}/ghost/api/admin/settings/" >/dev/null
}

# Prüft ob eine Ressource existiert
# Parameter: $1 = Typ (posts|pages), $2 = Slug, $3 = JWT Token
resource_exists() {
  local type="$1"
  local slug="$2"
  local jwt="$3"
  
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Ghost ${jwt}" \
    -H "Accept: application/json" \
    -H "User-Agent: $UA" \
    "${BASE_URL}/ghost/api/admin/${type}/slug/${slug}/?formats=html")
  
  [ "$code" = "200" ]
}

# Erstellt eine Seite
# Parameter: $1 = JWT Token, $2 = Slug, $3 = Title, $4 = HTML-Datei, $5 = show_title_and_feature_image (true/false)
create_page() {
  local jwt="$1"
  local slug="$2"
  local title="$3"
  local file="$4"
  local show_title="${5:-true}"
  
  if resource_exists "pages" "$slug" "$jwt"; then
    log "Seite '$slug' existiert bereits, überspringe."
    return
  fi
  
  local html jq_data
  html="$(< "$file")"
  log "Erstelle Seite '$slug' ..."
  
  if [ "$show_title" = "false" ]; then
    jq_data=$(jq -n \
      --arg title "$title" \
      --arg slug "$slug" \
      --arg html "$html" \
      --arg author "$GHOST_SETUP_EMAIL" \
      --argjson show_image false \
      '{pages:[{title:$title,slug:$slug,status:"published",html:$html,authors:[{email:$author}],show_title_and_feature_image:$show_image}]}')
  else
    jq_data=$(jq -n \
      --arg title "$title" \
      --arg slug "$slug" \
      --arg html "$html" \
      --arg author "$GHOST_SETUP_EMAIL" \
      '{pages:[{title:$title,slug:$slug,status:"published",html:$html,authors:[{email:$author}]}]}')
  fi
  
  curl -s \
    -H "Authorization: Ghost ${jwt}" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $UA" \
    -X POST \
    -d "$jq_data" \
    "${BASE_URL}/ghost/api/admin/pages/" >/dev/null
}

# Erstellt einen Post
# Parameter: $1 = JWT Token, $2 = Slug, $3 = Title, $4 = HTML-Datei, $5 = Tags (JSON), $6 = Feature Image URL (optional)
create_post() {
  local jwt="$1"
  local slug="$2"
  local title="$3"
  local file="$4"
  local tags_json="$5"
  local feature_image="${6:-}"
  
  if resource_exists "posts" "$slug" "$jwt"; then
    log "Post '$slug' existiert bereits, überspringe."
    return
  fi
  
  local html jq_data
  html="$(< "$file")"
  log "Erstelle Post '$slug' ..."
  
  if [ -n "$feature_image" ]; then
    jq_data=$(jq -n \
      --arg title "$title" \
      --arg slug "$slug" \
      --arg html "$html" \
      --arg author "$GHOST_SETUP_EMAIL" \
      --arg json_tags "$tags_json" \
      --arg feature_image "$feature_image" \
      '{posts:[{title:$title,slug:$slug,status:"published",html:$html,feature_image:$feature_image,authors:[{email:$author}],tags:($json_tags|fromjson)}]}')
  else
    jq_data=$(jq -n \
      --arg title "$title" \
      --arg slug "$slug" \
      --arg html "$html" \
      --arg author "$GHOST_SETUP_EMAIL" \
      --arg json_tags "$tags_json" \
      '{posts:[{title:$title,slug:$slug,status:"published",html:$html,authors:[{email:$author}],tags:($json_tags|fromjson)}]}')
  fi
  
  curl -s \
    -H "Authorization: Ghost ${jwt}" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $UA" \
    -X POST \
    -d "$jq_data" \
    "${BASE_URL}/ghost/api/admin/posts/" >/dev/null
}

# ============================================================================
# Hauptablauf
# ============================================================================

main() {
  log "=== Ghost Bootstrap Script gestartet ==="
  
  # 1. Warte auf Ghost
  wait_for_ghost
  
  # 2. Initiales Setup (falls nötig)
  if [ "$(setup_needed)" = "yes" ]; then
    log "Setup wird durchgeführt ..."
    do_setup
    
    # Nach Setup: CSRF-Token holen und Integration erstellen
    csrf="$(get_csrf)"
    
    # Integration erstellen und API-Keys erhalten
    keys_json="$(create_or_get_integration "$csrf" "Bootstrap Integration")"
    persist_keys "$keys_json"
    
    # Admin-Key extrahieren
    ADMIN_KEY=$(echo "$keys_json" | jq -r '.admin_api_key')
    export GHOST_ADMIN_API_KEY="$ADMIN_KEY"
  else
    log "Setup bereits durchgeführt."
    
    # Versuche gespeicherte Keys zu laden
    load_generated_keys
    
    if [ -z "${GHOST_ADMIN_API_KEY:-}" ]; then
      log "FEHLER: Kein Admin API Key verfügbar."
      exit 1
    fi
  fi
  
  # 3. JWT-Token für alle weiteren API-Calls generieren
  JWT_TOKEN="$(generate_jwt_token "$GHOST_ADMIN_API_KEY")"
  log "JWT-Token generiert."
  
  # 4. Theme hochladen und aktivieren
  download_theme
  theme_name="$(upload_theme "$JWT_TOKEN")"
  [ -n "$theme_name" ] && activate_theme "$JWT_TOKEN" "$theme_name"
  
  # 5. Routes und Navigation konfigurieren
  upload_routes "$JWT_TOKEN"
  update_navigation "$JWT_TOKEN"
  
  # 6. Seiten erstellen
  log "=== Erstelle Seiten ==="
  
  # Startseite
  sed -e "s|\[BLOGTITLE\]|${GHOST_SETUP_BLOG_TITLE}|g" \
      /bootstrap/pages/start.html > /tmp/start.html
  create_page "$JWT_TOKEN" "start" "Start" "/tmp/start.html" "false"
  
  # Impressum
  YEAR_NOW=$(date '+%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      -e "s|\[DOMAIN\]|${DOMAIN}|g" \
      -e "s|\[JAHR\]|${YEAR_NOW}|g" \
      /bootstrap/pages/impressum.html > /tmp/impressum.html
  create_page "$JWT_TOKEN" "impressum" "Impressum" "/tmp/impressum.html" "true"
  
  # Datenschutz
  DATE_NOW=$(date '+%d.%m.%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[DATUM\]|${DATE_NOW}|g" \
      /bootstrap/pages/datenschutz.html > /tmp/datenschutz.html
  create_page "$JWT_TOKEN" "datenschutz" "Datenschutzerklärung" "/tmp/datenschutz.html" "true"
  
  # Presse
  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/pages/presse.html > /tmp/presse.html
  create_page "$JWT_TOKEN" "presse" "Presse" "/tmp/presse.html" "true"
  
  # Beispielseite
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      /bootstrap/pages/beispielseite.html > /tmp/beispielseite.html
  create_page "$JWT_TOKEN" "beispielseite" "Beispielseite" "/tmp/beispielseite.html" "true"
  
  # 7. Posts erstellen
  log "=== Erstelle Posts ==="
  
  # Beispiel-Post
  create_post "$JWT_TOKEN" "beispiel-post" "Beispiel-Blogpost" \
    "/bootstrap/posts/beispiel-post.html" \
    '[]' \
    "https://images.unsplash.com/photo-1599045118108-bf9954418b76?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3wxMTc3M3wwfDF8c2VhcmNofDE3fHxob3NwaXRhbHxlbnwwfHx8fDE3NjAxMDM0MzV8MA&ixlib=rb-4.1.0&q=80&w=2000"
  
  # Beispiel-Pressemitteilung
  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/posts/beispiel-pressemitteilung.html > /tmp/beispiel-pressemitteilung.html
  create_post "$JWT_TOKEN" "beispiel-pressemitteilung" "Beispiel-Pressemitteilung" \
    "/tmp/beispiel-pressemitteilung.html" \
    '[{"name":"#pressemitteilung"}]' \
    "null"
  
  log "=== Bootstrap erfolgreich abgeschlossen ==="
}

# Skript starten
main
