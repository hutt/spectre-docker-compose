#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Ghost Bootstrap – Auto-Install, idempotent
# ============================================

# Required ENV:
# - DOMAIN
# - SPECTRE_ZIP_URL
# - GHOST_SETUP_EMAIL
# - GHOST_SETUP_NAME
# - GHOST_SETUP_BLOG_TITLE
# - Optional: BOOTSTRAP_CLEANUP_INTEGRATION=true|false

BASE_URL="https://${DOMAIN}"
UA="Ghost-Bootstrap/1.0"
DB_PATH="/var/lib/ghost/content/data/ghost.db"
ROUTES_SRC="/bootstrap/routes.yaml"
ROUTES_DST="/var/lib/ghost/content/settings/routes.yaml"
TMP_DIR="/tmp/ghost-bootstrap"
SPECTRE_ZIP="${TMP_DIR}/spectre.zip"

mkdir -p "${TMP_DIR}"

log() {
  printf '%s %s\n' "$(date +'%F %T')" "$*" >&2
}

# ---------------------------
# Retry helper (exponential backoff)
# ---------------------------
retry() {
  # retry <max_attempts> <initial_delay_seconds> <cmd...>
  local max=$1; shift
  local delay=$1; shift
  local attempt=1
  local rc=0

  while true; do
    if "$@"; then
      return 0
    fi
    rc=$?
    if [ $attempt -ge $max ]; then
      return $rc
    fi
    log "Retry $attempt/$max failed (rc=$rc). Sleeping ${delay}s..."
    sleep "$delay"
    delay=$((delay*2))
    attempt=$((attempt+1))
  done
}

# ---------------------------
# DB exist check
# ---------------------------
db_exists() {
  [ -s "$DB_PATH" ]
}

# ---------------------------
# Detect Ghost API Version
# ---------------------------
detect_api_version() {
  local hdr ver
  hdr=$(curl -sS -I -H "X-Forwarded-Proto: https" "${BASE_URL}/ghost/api/admin/site/" || true)
  ver=$(printf "%s\n" "$hdr" | awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="content-version"{gsub(/\r/,"",$2);print $2}' | head -n1)
  GHOST_API_VERSION="${ver:-v6.3}"
  log "Accept-Version: ${GHOST_API_VERSION}"
}

# ---------------------------
# Read Admin API Key from SQLite
# ---------------------------
read_admin_key_from_db() {
  if ! db_exists; then
    echo ""
    return 1
  fi
  local row
  row=$(sqlite3 "$DB_PATH" "
    SELECT ak.id||':'||ak.secret
    FROM api_keys ak
    JOIN integrations i ON i.id = ak.integration_id
    WHERE ak.type='admin' AND i.name='api'
    ORDER BY ak.created_at DESC LIMIT 1;")
  if [ -z "$row" ]; then
    row=$(sqlite3 "$DB_PATH" "
      SELECT ak.id||':'||ak.secret
      FROM api_keys ak
      WHERE ak.type='admin'
      ORDER BY ak.created_at DESC LIMIT 1;")
  fi
  [ -z "$row" ] && return 1
  printf "%s" "$row"
}

# ---------------------------
# Generate JWT for Admin API
# ---------------------------
generate_jwt() {
  local key=$1 id secret now exp header payload signature
  IFS=':' read -r id secret <<< "$key"
  now=$(date +%s); exp=$((now+300))
  header=$(printf '{"alg":"HS256","typ":"JWT","kid":"%s"}' "$id" | openssl base64 -A | tr '/+' '_-' | tr -d '=')
  payload=$(printf '{"iat":%s,"exp":%s,"aud":"/admin/"}' "$now" "$exp" | openssl base64 -A | tr '/+' '_-' | tr -d '=')
  signature=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -binary -mac HMAC -macopt hexkey:"$secret" \
    | openssl base64 -A | tr '/+' '_-' | tr -d '=')
  JWT_TOKEN="${header}.${payload}.${signature}"
}

api_jwt() {
  local method=$1 path=$2 body=${3:-}
  curl -sSf \
    -H "Authorization: Ghost ${JWT_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept-Version: ${GHOST_API_VERSION}" \
    -H "User-Agent: ${UA}" \
    -X "$method" \
    ${body:+-d "$body"} \
    "${BASE_URL}/ghost/api/admin${path}"
}

# ---------------------------
# Theme: download, upload, activate
# ---------------------------
download_theme() {
  curl -fsSL "$SPECTRE_ZIP_URL" -o "$SPECTRE_ZIP"
}

upload_theme() {
  curl -sS \
    -H "Authorization: Ghost ${JWT_TOKEN}" \
    -H "Accept-Version: ${GHOST_API_VERSION}" \
    -H "User-Agent: ${UA}" \
    -F "file=@${SPECTRE_ZIP}" \
    "${BASE_URL}/ghost/api/admin/themes/upload/"
}

activate_theme() {
  local theme_name="$1"
  api_jwt PUT "/themes/${theme_name}/activate/" '{}'
}

# ---------------------------
# Navigation
# ---------------------------
set_navigation() {
  api_jwt PUT /settings/ '{
    "settings":[
      {"key":"navigation","value":[
        {"label":"Start","url":"/"},
        {"label":"Blog","url":"/blog/"},
        {"label":"Presse","url":"/presse/"},
        {"label":"Beispielseite","url":"/beispielseite/"}
      ]},
      {"key":"secondary_navigation","value":[
        {"label":"Datenschutz","url":"/datenschutz/"},
        {"label":"Impressum","url":"/impressum/"}
      ]}
    ]
  }' >/dev/null
}

# ---------------------------
# Helpers for content import
# ---------------------------
escape_html_file() {
  sed ':a;N;$!ba;s/\n/\\n/g; s/"/\\"/g' "$1"
}

# Platzhalter-Ersetzungen in temporäre Dateien anwenden
prepare_pages_with_substitutions() {
  local year_now date_now
  year_now=$(date '+%Y')
  date_now=$(date '+%d.%m.%Y')

  # Start
  sed -e "s|\\[BLOGTITLE\\]|${GHOST_SETUP_BLOG_TITLE}|g" \
    /bootstrap/pages/start.html > /tmp/start.html

  # Impressum
  sed -e "s|\\[Vorname Nachname\\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\\[EMAIL\\]|${GHOST_SETUP_EMAIL}|g" \
      -e "s|\\[DOMAIN\\]|${DOMAIN}|g" \
      -e "s|\\[JAHR\\]|${year_now}|g" \
    /bootstrap/pages/impressum.html > /tmp/impressum.html

  # Datenschutz
  sed -e "s|\\[Vorname Nachname\\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\\[DATUM\\]|${date_now}|g" \
    /bootstrap/pages/datenschutz.html > /tmp/datenschutz.html

  # Presse
  sed -e "s|\\[EMAIL\\]|${GHOST_SETUP_EMAIL}|g" \
    /bootstrap/pages/presse.html > /tmp/presse.html

  # Beispielseite
  sed -e "s|\\[Vorname Nachname\\]|${GHOST_SETUP_NAME}|g" \
    /bootstrap/pages/beispielseite.html > /tmp/beispielseite.html

  # Pressemitteilung Post
  sed -e "s|\\[EMAIL\\]|${GHOST_SETUP_EMAIL}|g" \
    /bootstrap/posts/beispiel-pressemitteilung.html > /tmp/beispiel-pressemitteilung.html
}

create_page_if_missing() {
  local slug="$1" title="$2" file="$3"
  local body
  body=$(jq -nr \
    --arg t "$title" \
    --arg s "$slug" \
    --arg h "$(escape_html_file "$file")" \
    --arg e "$GHOST_SETUP_EMAIL" \
    '{pages:[{title:$t,slug:$s,status:"published",html:$h,authors:[{email:$e}]}]}')
  api_jwt POST /pages/ "$body" >/dev/null || true
}

create_post_if_missing() {
  local slug="$1" title="$2" file="$3" tags_json="$4"
  local body
  body=$(jq -nr \
    --arg t "$title" \
    --arg s "$slug" \
    --arg h "$(escape_html_file "$file")" \
    --arg e "$GHOST_SETUP_EMAIL" \
    --argjson tg "$tags_json" \
    '{posts:[{title:$t,slug:$s,status:"published",html:$h,authors:[{email:$e}],tags:$tg}]}')
  api_jwt POST /posts/ "$body" >/dev/null || true
}

# ---------------------------
# Routes deploy
# ---------------------------
deploy_routes() {
  mkdir -p "$(dirname "$ROUTES_DST")"
  cp "$ROUTES_SRC" "$ROUTES_DST"
}

# ---------------------------
# Integration cleanup
# ---------------------------
delete_bootstrap_integration() {
  local iid
  iid=$(sqlite3 "$DB_PATH" "
    SELECT i.id
    FROM integrations i
    JOIN api_keys ak ON ak.integration_id = i.id
    WHERE i.name='Bootstrap Integration'
    ORDER BY i.created_at DESC LIMIT 1;")
  [ -z "$iid" ] && { log "CLEANUP: Keine Bootstrap Integration gefunden."; return 0; }
  api_jwt DELETE "/integrations/${iid}/" >/dev/null || {
    log "CLEANUP: DELETE /integrations/${iid} fehlgeschlagen (ggf. bereits entfernt)."
    return 0
  }
  log "CLEANUP: Bootstrap Integration gelöscht (id=${iid})."
}

# ---------------------------
# MAIN
# ---------------------------
main() {
  log "=== Ghost Bootstrap START ==="

  if ! db_exists; then
    log "Keine DB gefunden (${DB_PATH}). Installation noch nicht bereit. Beende ohne Fehler."
    exit 0
  fi

  # Standard Retry-Limit (nicht erhöht)
  log "Warte auf Ghost Admin Endpoint..."
  retry 10 1 curl -fsS -H "X-Forwarded-Proto: https" "${BASE_URL}/ghost/api/admin/site/" >/dev/null

  detect_api_version

  local admin_key
  admin_key=$(read_admin_key_from_db) || { log "ERROR: Kein Admin API Key in DB gefunden."; exit 1; }
  generate_jwt "$admin_key"

  # THEME
  log "[THEME] Lade Theme ZIP..."
  retry 3 1 download_theme

  log "[THEME] Lade Theme in Ghost hoch..."
  local theme_resp raw_name
  theme_resp=$(retry 3 1 upload_theme || echo "")
  if echo "${theme_resp}" | jq empty >/dev/null 2>&1; then
    raw_name=$(echo "${theme_resp}" | jq -r '.themes[0].name // empty')
  else
    raw_name=""
    log "[THEME] Upload-Antwort ist kein gültiges JSON (evtl. Proxy-/Fehlerseite)."
  fi

  if [ -n "${raw_name}" ]; then
    log "[THEME] Aktiviere Theme: ${raw_name}"
    retry 3 1 activate_theme "$raw_name"
  else
    log "[THEME] Kein Theme-Name aus der Upload-Antwort ermittelt (ggf. bereits vorhanden oder anderer Fehler)."
  fi

  # NAV
  log "[NAV] Setze Navigation..."
  retry 3 1 set_navigation

  # PAGES/POSTS mit Ersetzungen
  prepare_pages_with_substitutions

  log "[PAGES] Erstelle statische Seiten..."
  create_page_if_missing "start" "Start" "/tmp/start.html"
  create_page_if_missing "impressum" "Impressum" "/tmp/impressum.html"
  create_page_if_missing "datenschutz" "Datenschutzerklärung" "/tmp/datenschutz.html"
  create_page_if_missing "presse" "Presse" "/tmp/presse.html"
  create_page_if_missing "beispielseite" "Beispielseite" "/tmp/beispielseite.html"

  log "[POSTS] Erstelle Beispiel-Posts..."
  create_post_if_missing "beispiel-post" "Beispiel-Blogpost" "/bootstrap/posts/beispiel-post.html" "[]"
  create_post_if_missing "beispiel-pressemitteilung" "Beispiel-Pressemitteilung" "/tmp/beispiel-pressemitteilung.html" '[{"name":"#pressemitteilung"}]'

  # ROUTES
  log "[ROUTES] Kopiere routes.yaml..."
  deploy_routes

  # CLEANUP INTEGRATION (optional, default true)
  if [ "${BOOTSTRAP_CLEANUP_INTEGRATION:-true}" = "true" ]; then
    log "[CLEANUP] Entferne Bootstrap Integration..."
    delete_bootstrap_integration
  fi

  # TEMP CLEANUP
  log "[CLEANUP] Entferne temporäre Dateien..."
  rm -f "$SPECTRE_ZIP" || true
  rm -f /tmp/start.html /tmp/impressum.html /tmp/datenschutz.html /tmp/presse.html /tmp/beispielseite.html /tmp/beispiel-pressemitteilung.html || true
  rmdir "$TMP_DIR" 2>/dev/null || true

  log "=== Ghost Bootstrap FINISHED ==="
}

main
