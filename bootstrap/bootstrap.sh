#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Ghost Bootstrap – Erst-Setup nur mit first_setup (Staff-Token only)
# ============================================

# Required ENV:
# - DOMAIN
# - SPECTRE_ZIP_URL
# - GHOST_SETUP_EMAIL
# - GHOST_SETUP_NAME
# - GHOST_SETUP_BLOG_TITLE

BASE_URL="https://${DOMAIN}"
UA="Ghost-Bootstrap/2.4"
ROUTES_SRC="/bootstrap/routes.yaml"
ROUTES_DST="/var/lib/ghost/content/settings/routes.yaml"
TMP_DIR="/tmp/ghost-bootstrap"
SPECTRE_ZIP="${TMP_DIR}/spectre.zip"
FIRST_SETUP_FILE="/bootstrap/first_setup"

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
# Admin API caller (Staff Token only)
# ---------------------------
STAFF_ACCESS_TOKEN=""

require_staff_token() {
  if [ -z "${STAFF_ACCESS_TOKEN}" ]; then
    log "ERROR: Kein STAFF_ACCESS_TOKEN verfügbar. Vorgang kann nicht fortgesetzt werden."
    exit 1
  fi
}

api_admin() {
  local method=$1 path=$2 body=${3:-}
  require_staff_token
  curl -sSf \
    -H "Authorization: Bearer ${STAFF_ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept-Version: ${GHOST_API_VERSION}" \
    -H "User-Agent: ${UA}" \
    -X "$method" \
    ${body:+-d "$body"} \
    "${BASE_URL}/ghost/api/admin${path}"
}

# ---------------------------
# User lookup helpers
# ---------------------------
get_user_id_by_email() {
  local email="$1"
  local res uid
  res=$(api_admin GET "/users/?filter=email:${email}&limit=1") || return 1
  uid=$(echo "$res" | jq -r '.users[0].id // empty')
  if [ -z "$uid" ]; then
    log "ERROR: Kein User mit E-Mail ${email} gefunden."
    return 1
  fi
  echo "$uid"
}

get_user_id_by_slug() {
  local slug="$1"
  local res uid
  res=$(api_admin GET "/users/?filter=slug:${slug}&limit=1") || return 1
  uid=$(echo "$res" | jq -r '.users[0].id // empty')
  if [ -z "$uid" ]; then
    log "ERROR: Kein User mit Slug ${slug} gefunden."
    return 1
  fi
  echo "$uid"
}

# ---------------------------
# Theme: download, upload, activate
# ---------------------------
download_theme() {
  curl -fsSL "$SPECTRE_ZIP_URL" -o "$SPECTRE_ZIP"
}

upload_theme() {
  require_staff_token
  curl -sS \
    -H "Authorization: Bearer ${STAFF_ACCESS_TOKEN}" \
    -H "Accept-Version: ${GHOST_API_VERSION}" \
    -H "User-Agent: ${UA}" \
    -F "file=@${SPECTRE_ZIP}" \
    "${BASE_URL}/ghost/api/admin/themes/upload/"
}

activate_theme() {
  local theme_name="$1"
  api_admin PUT "/themes/${theme_name}/activate/" '{}'
}

# ---------------------------
# Navigation (Staff-only)
# ---------------------------
set_navigation() {
  api_admin PUT /settings/ '{
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
  }'
}

# ---------------------------
# HTML → JSON-string Helper
# ---------------------------
file_to_json_string() {
  # gibt einen JSON-String (inkl. Quotes) auf stdout
  jq -Rs . < "$1"
}

# ---------------------------
# Prepare HTML pages/posts (sed replaces)
# ---------------------------
prepare_pages_with_substitutions() {
  local year_now date_now
  year_now=$(date '+%Y')
  date_now=$(date '+%d.%m.%Y')

  sed -e "s|\\[BLOGTITLE\\]|${GHOST_SETUP_BLOG_TITLE}|g" \
    /bootstrap/pages/start.html > /tmp/start.html

  sed -e "s|\\[Vorname Nachname\\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\\[EMAIL\\]|${GHOST_SETUP_EMAIL}|g" \
      -e "s|\\[DOMAIN\\]|${DOMAIN}|g" \
      -e "s|\\[JAHR\\]|${year_now}|g" \
    /bootstrap/pages/impressum.html > /tmp/impressum.html

  sed -e "s|\\[Vorname Nachname\\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\\[DATUM\\]|${date_now}|g" \
    /bootstrap/pages/datenschutz.html > /tmp/datenschutz.html

  sed -e "s|\\[EMAIL\\]|${GHOST_SETUP_EMAIL}|g" \
    /bootstrap/pages/presse.html > /tmp/presse.html

  sed -e "s|\\[Vorname Nachname\\]|${GHOST_SETUP_NAME}|g" \
    /bootstrap/pages/beispielseite.html > /tmp/beispielseite.html

  sed -e "s|\\[EMAIL\\]|${GHOST_SETUP_EMAIL}|g" \
    /bootstrap/posts/beispiel-pressemitteilung.html > /tmp/beispiel-pressemitteilung.html
}

# ---------------------------
# Create pages/posts with actor + escaped HTML
# ---------------------------
create_page_if_missing() {
  local slug="$1" title="$2" file="$3" author_id="$4"
  local html_json body
  html_json=$(file_to_json_string "$file")
  body=$(jq -nr \
    --arg t "$title" \
    --arg s "$slug" \
    --arg a "$author_id" \
    --argjson h "$html_json" \
    '{
      pages:[{
        title:$t,
        slug:$s,
        status:"published",
        html:$h,
        authors:[{id:$a}]
      }]
    }')
  log "create_page_if_missing(): $body"
  api_admin POST /pages/ "$body" >/dev/null || true
}

create_post_if_missing() {
  local slug="$1" title="$2" file="$3" tags_json="$4" author_id="$5"
  local html_json body
  html_json=$(file_to_json_string "$file")
  body=$(jq -nr \
    --arg t "$title" \
    --arg s "$slug" \
    --arg a "$author_id" \
    --argjson tg "$tags_json" \
    --argjson h "$html_json" \
    '{
      posts:[{
        title:$t,
        slug:$s,
        status:"published",
        html:$h,
        authors:[{id:$a}],
        tags:$tg
      }]
    }')
  log "create_post_if_missing(): $body"
  api_admin POST /posts/ "$body" >/dev/null || true
}

# ---------------------------
# Routes deploy
# ---------------------------
deploy_routes() {
  mkdir -p "$(dirname "$ROUTES_DST")"
  cp "$ROUTES_SRC" "$ROUTES_DST"
}

# ---------------------------
# Delete user with slug "superuser" if present
# ---------------------------
delete_superuser() {
  log "CLEANUP: Suche User 'superuser' zum Löschen..."
  local users_json user_id
  users_json=$(api_admin GET "/users/?filter=slug:superuser&limit=1") || users_json=""
  user_id=$(echo "$users_json" | jq -r '.users[0].id // empty' 2>/dev/null || echo "")
  if [ -n "${user_id}" ]; then
    log "CLEANUP: Superuser gefunden (id=${user_id}), lösche..."
    api_admin DELETE "/users/${user_id}/" >/dev/null || {
      log "CLEANUP: Löschen des Superuser fehlgeschlagen."
      return 1
    }
    log "CLEANUP: Superuser gelöscht."
  else
    log "CLEANUP: Kein Superuser zum Löschen gefunden."
  fi
}

# ---------------------------
# Remove first_setup token file
# ---------------------------
delete_first_setup_file() {
  if [ -f "${FIRST_SETUP_FILE}" ]; then
    rm -f "${FIRST_SETUP_FILE}" || {
      log "CLEANUP: Konnte ${FIRST_SETUP_FILE} nicht löschen."
      return 1
    }
    log "CLEANUP: ${FIRST_SETUP_FILE} gelöscht."
  fi
}

# ---------------------------
# MAIN
# ---------------------------
main() {
  log "=== Ghost Bootstrap START ==="

  # Erst-Setup nur, wenn first_setup existiert
  if [ ! -f "${FIRST_SETUP_FILE}" ]; then
    log "first_setup fehlt – kein Erst-Setup erforderlich. Beende ohne Fehler."
    exit 0
  fi

  # STAFF TOKEN laden
  STAFF_ACCESS_TOKEN="$(tr -d ' \n\r' <"${FIRST_SETUP_FILE}" || true)"
  if [ -z "${STAFF_ACCESS_TOKEN}" ]; then
    log "ERROR: ${FIRST_SETUP_FILE} ist leer – kein STAFF_ACCESS_TOKEN verfügbar."
    exit 1
  fi

  # Warte auf Ghost Admin endpoint
  log "Warte auf Ghost Admin Endpoint..."
  retry 10 1 curl -fsS -H "X-Forwarded-Proto: https" "${BASE_URL}/ghost/api/admin/site/" >/dev/null

  detect_api_version
  log "Auth-Modus: STAFF Access Token"

  # Actor-IDs bestimmen
  log "[ACTOR] Ermittle User-ID für slug superuser..."
  SUPERUSER_ID="$(get_user_id_by_slug "superuser")" || { log "ERROR: superuser-ID konnte nicht ermittelt werden."; exit 1; }

  log "[AUTHOR] Ermittle Autor-ID für ${GHOST_SETUP_EMAIL}..."
  AUTHOR_ID="$(get_user_id_by_email "${GHOST_SETUP_EMAIL}")" || { log "ERROR: Autor-ID konnte nicht ermittelt werden."; exit 1; }

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

  # PAGES/POSTS mit Platzhalter-Ersetzungen
  prepare_pages_with_substitutions

  log "[PAGES] Erstelle statische Seiten..."
  create_page_if_missing "start" "Start" "/tmp/start.html" "${AUTHOR_ID}"
  create_page_if_missing "impressum" "Impressum" "/tmp/impressum.html" "${AUTHOR_ID}"
  create_page_if_missing "datenschutz" "Datenschutzerklärung" "/tmp/datenschutz.html" "${AUTHOR_ID}"
  create_page_if_missing "presse" "Presse" "/tmp/presse.html" "${AUTHOR_ID}"
  create_page_if_missing "beispielseite" "Beispielseite" "/tmp/beispielseite.html" "${AUTHOR_ID}"

  log "[POSTS] Erstelle Beispiel-Posts..."
  create_post_if_missing "beispiel-post" "Beispiel-Blogpost" "/bootstrap/posts/beispiel-post.html" "[]" "${AUTHOR_ID}"
  create_post_if_missing "beispiel-pressemitteilung" "Beispiel-Pressemitteilung" "/tmp/beispiel-pressemitteilung.html" '[{"name":"#pressemitteilung"}]' "${AUTHOR_ID}"

  # ROUTES
  log "[ROUTES] Kopiere routes.yaml..."
  deploy_routes

  # CLEANUP: Superuser und first_setup entfernen
  delete_superuser || log "CLEANUP: Superuser-Löschung schlug fehl."
  delete_first_setup_file || log "CLEANUP: first_setup-Datei-Löschung schlug fehl."

  # TEMP CLEANUP
  log "[CLEANUP] Entferne temporäre Dateien..."
  rm -f "$SPECTRE_ZIP" || true
  rm -f /tmp/start.html /tmp/impressum.html /tmp/datenschutz.html /tmp/presse.html /tmp/beispielseite.html /tmp/beispiel-pressemitteilung.html || true
  rmdir "$TMP_DIR" 2>/dev/null || true

  log "=== Ghost Bootstrap FINISHED ==="
}

main
