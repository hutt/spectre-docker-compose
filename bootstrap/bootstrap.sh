#!/usr/bin/env bash
set -euo pipefail

# Erwartet über env_file (.env):
# DOMAIN, SPECTRE_ZIP_URL
# GHOST_SETUP_NAME, GHOST_SETUP_EMAIL, GHOST_SETUP_PASSWORD, GHOST_SETUP_BLOG_TITLE
# Optional: GHOST_ADMIN_API_KEY (id:secret), GHOST_ACCEPT_VERSION, CODEINJECTION_HEAD, INTEGRATION_NAME, GHOST_UPLOAD_BASE

# Basis-ENV
DOMAIN="${DOMAIN:?missing DOMAIN}"
ORIGIN="https://${DOMAIN}"
ACCEPT_VERSION="${GHOST_ACCEPT_VERSION:-v6.3}"
SPECTRE_ZIP_URL="${SPECTRE_ZIP_URL:?missing SPECTRE_ZIP_URL}"

# Automatische Registrierung: ausschließlich diese 4 Variablen
SETUP_NAME="${GHOST_SETUP_NAME:?missing GHOST_SETUP_NAME}"
SETUP_EMAIL="${GHOST_SETUP_EMAIL:?missing GHOST_SETUP_EMAIL}"
SETUP_PASSWORD="${GHOST_SETUP_PASSWORD:?missing GHOST_SETUP_PASSWORD}"
SETUP_BLOG_TITLE="${GHOST_SETUP_BLOG_TITLE:?missing GHOST_SETUP_BLOG_TITLE}"

# Admin API Key optional (id:secret). Falls fehlt, wird er per Session erstellt.
GHOST_ADMIN_API_KEY="${GHOST_ADMIN_API_KEY:-}"

COOKIE_JAR="/tmp/ghost_cookie.txt"
MARKER_DIR="/tmp/ghost-bootstrap"
JWT_FILE="/tmp/ghost_admin_jwt.txt"
INTEGRATION_KEY_FILE="/tmp/ghost_admin_api_key.txt"

mkdir -p "${MARKER_DIR}"

api() {
  local method="$1"; shift
  local path="$1"; shift
  local extra_args=("$@")
  curl -sSf -X "${method}" "${ORIGIN}${path}" \
    -H "Accept-Version: ${ACCEPT_VERSION}" \
    "${extra_args[@]}"
}

api_auth() {
  local method="$1"; shift
  local path="$1"; shift
  local token
  token="$(cat "${JWT_FILE}")"
  local extra_args=("$@")
  curl -sSf -X "${method}" "${ORIGIN}${path}" \
    -H "Accept-Version: ${ACCEPT_VERSION}" \
    -H "Authorization: Ghost ${token}" \
    "${extra_args[@]}"
}

echo "[0] Warte auf Ghost Admin API ..."
for i in {1..60}; do
  if api GET "/ghost/api/admin/site/" >/dev/null 2>&1; then
    echo "Ghost Admin API erreichbar."
    break
  fi
  sleep 2
done

# 1) Owner-Erst-Setup
if [ ! -f "${MARKER_DIR}/setup.done" ]; then
  echo "[1] Führe Owner-Setup aus (idempotent) ..."
  set +e
  api POST "/ghost/api/admin/setup/" \
    -H "Origin: ${ORIGIN}" \
    -H "Content-Type: application/json" \
    --data "$(jq -n \
      --arg name  "$SETUP_NAME" \
      --arg email "$SETUP_EMAIL" \
      --arg pass  "$SETUP_PASSWORD" \
      --arg title "$SETUP_BLOG_TITLE" \
      '{setup:[{name:$name,email:$email,password:$pass,blogTitle:$title}]}')" >/dev/null 2>&1
  set -e
  touch "${MARKER_DIR}/setup.done"
  echo "Owner-Setup abgeschlossen (oder bereits vorhanden)."
fi

# 2) Falls kein Admin API Key vorhanden, Integration per Session-Login anlegen
if [ -z "${GHOST_ADMIN_API_KEY}" ] && [ ! -f "${MARKER_DIR}/integration.done" ]; then
  echo "[2] Erzeuge Admin API Key per Session-Login ..."
  rm -f "${COOKIE_JAR}"
  curl -sSf -c "${COOKIE_JAR}" -X POST "${ORIGIN}/ghost/api/admin/session/" \
    -H "Origin: ${ORIGIN}" \
    -H "Accept-Version: ${ACCEPT_VERSION}" \
    -H "Content-Type: application/json" \
    --data "{\"username\":\"${GHOST_SETUP_EMAIL}\",\"password\":\"${GHOST_SETUP_PASSWORD}\"}" >/dev/null

  INTEGRATION_NAME="${INTEGRATION_NAME:-CI Bootstrap}"
  create_resp=$(curl -sSf -b "${COOKIE_JAR}" -X POST "${ORIGIN}/ghost/api/admin/integrations/" \
    -H "Origin: ${ORIGIN}" \
    -H "Accept-Version: ${ACCEPT_VERSION}" \
    -H "Content-Type: application/json" \
    --data "$(jq -n --arg name "$INTEGRATION_NAME" '{integrations:[{name:$name,description:"Automated bootstrap key"}]}')")

  integration_id=$(echo "$create_resp" | jq -r '.integrations[0].id')

  keys_resp=$(curl -sSf -b "${COOKIE_JAR}" -X GET "${ORIGIN}/ghost/api/admin/integrations/${integration_id}/api_keys/" \
    -H "Origin: ${ORIGIN}" \
    -H "Accept-Version: ${ACCEPT_VERSION}")

  admin_key_id=$(echo "$keys_resp" | jq -r '.api_keys[] | select(.type=="admin") | .id')
  admin_key_secret=$(echo "$keys_resp" | jq -r '.api_keys[] | select(.type=="admin") | .secret')

  if [ -z "$admin_key_id" ] || [ -z "$admin_key_secret" ] || [ "$admin_key_id" = "null" ] || [ "$admin_key_secret" = "null" ]; then
    echo "Fehler: Konnte Admin API Key nicht ermitteln."
    exit 1
  fi

  GHOST_ADMIN_API_KEY="${admin_key_id}:${admin_key_secret}"
  printf "%s" "${GHOST_ADMIN_API_KEY}" > "${INTEGRATION_KEY_FILE}"
  touch "${MARKER_DIR}/integration.done"
  echo "Admin API Key erstellt."
else
  printf "%s" "${GHOST_ADMIN_API_KEY}" > "${INTEGRATION_KEY_FILE}"
fi

# 3) Admin JWT erzeugen
if [ ! -f "${MARKER_DIR}/jwt.done" ]; then
  echo "[3] Erzeuge Admin JWT ..."
  node /bootstrap/node-bootstrap.mjs < "${INTEGRATION_KEY_FILE}" > "${JWT_FILE}"
  touch "${MARKER_DIR}/jwt.done"
  echo "Admin JWT erstellt."
fi

# 4) Theme spectre hochladen & aktivieren
if [ ! -f "${MARKER_DIR}/theme.done" ]; then
  echo "[4] Lade Spectre-Theme ..."
  curl -sSfL -o /tmp/spectre.zip "${SPECTRE_ZIP_URL}"
  # Optional interne Base-URL, um Proxy-Einflüsse zu vermeiden (z.B. http://test-ghost-ghost:2368)
  GHOST_UPLOAD_BASE="${GHOST_UPLOAD_BASE:-${ORIGIN}}"
  # Wenn GHOST_UPLOAD_BASE == ORIGIN, api_auth POST "/ghost/api/..." nutzen
  if [ "${GHOST_UPLOAD_BASE}" = "${ORIGIN}" ]; then
    api_auth POST "/ghost/api/admin/themes/upload/" -F "file=@/tmp/spectre.zip" >/dev/null
  else
    # Direkt an interne URL senden, aber dennoch Authorization/Accept-Version mitsenden
    curl -sSf -X POST "${GHOST_UPLOAD_BASE}/ghost/api/admin/themes/upload/" \
      -H "Accept-Version: ${ACCEPT_VERSION}" \
      -H "Authorization: Ghost $(cat "${JWT_FILE}")" \
      -F "file=@/tmp/spectre.zip" >/dev/null
  fi
  set +e
  api_auth PUT "/ghost/api/admin/themes/spectre/activate/" >/dev/null 2>&1
  set -e
  touch "${MARKER_DIR}/theme.done"
  echo "Theme aktiviert."
fi

# Hilfsfunktionen
json_escape() {
  python3 - <<'PY'
import sys, json
data = sys.stdin.read()
print(json.dumps(data))
PY
}

render_html() {
  local f="$1"
  local today
  today="$(date +%F)"
  sed \
    -e "s/\[DATUM\]/${today//\//\\/}/g" \
    -e "s/\[EMAIL\]/${GHOST_SETUP_EMAIL//\//\\/}/g" \
    -e 's/\r$//' \
    "$f"
}

# 5) Inhalte anlegen
if [ ! -f "${MARKER_DIR}/content.done" ]; then
  echo "[5] Erzeuge Demo-Inhalte ..."
  create_page() {
    local title="$1"
    local slug="$2"
    local file="$3"
    local html payload
    html="$(render_html "$file")"
    payload="$(jq -n --arg title "$title" --arg slug "$slug" '{pages:[{title:$title,slug:$slug,status:"published"}]}')"
    payload="$(echo "$payload" | jq --arg html "$html" '.pages[0].html = $html')"
    api_auth POST "/ghost/api/admin/pages/" \
      -H "Content-Type: application/json" \
      --data "$payload" >/dev/null
  }
  create_post() {
    local title="$1"
    local slug="$2"
    local file="$3"
    local tag="$4"
    local html payload
    html="$(render_html "$file")"
    if [ -n "$tag" ]; then
      payload="$(jq -n --arg title "$title" --arg slug "$slug" '{posts:[{title:$title,slug:$slug,status:"published",tags:[{name:"'"$tag"'"}]}]}')"
    else
      payload="$(jq -n --arg title "$title" --arg slug "$slug" '{posts:[{title:$title,slug:$slug,status:"published"}]}')"
    fi
    payload="$(echo "$payload" | jq --arg html "$html" '.posts[0].html = $html')"
    api_auth POST "/ghost/api/admin/posts/" \
      -H "Content-Type: application/json" \
      --data "$payload" >/dev/null
  }
  create_page "Start" "start" "/bootstrap/pages/start.html"
  create_page "Beispielseite" "beispielseite" "/bootstrap/pages/beispielseite.html"
  create_page "Presse" "presse" "/bootstrap/pages/presse.html"
  create_page "Impressum" "impressum" "/bootstrap/pages/impressum.html"
  create_page "Datenschutz" "datenschutz" "/bootstrap/pages/datenschutz.html"
  create_post "Beispiel‑Post" "beispiel-post" "/bootstrap/posts/beispiel-post.html" ""
  create_post "Beispiel‑Pressemitteilung" "beispiel-pressemitteilung" "/bootstrap/posts/beispiel-pressemitteilung.html" "#pressemitteilung"
  touch "${MARKER_DIR}/content.done"
  echo "Inhalte angelegt."
fi

# 6) Session-Login für routes & Code-Injection
if [ ! -f "${MARKER_DIR}/session.done" ]; then
  echo "[6] Session-Login (für routes/Code-Injection) ..."
  rm -f "${COOKIE_JAR}"
  curl -sSf -c "${COOKIE_JAR}" -X POST "${ORIGIN}/ghost/api/admin/session/" \
    -H "Origin: ${ORIGIN}" \
    -H "Accept-Version: ${ACCEPT_VERSION}" \
    -H "Content-Type: application/json" \
    --data "{\"username\":\"${GHOST_SETUP_EMAIL}\",\"password\":\"${GHOST_SETUP_PASSWORD}\"}" >/dev/null
  touch "${MARKER_DIR}/session.done"
  echo "Session aufgebaut."
fi

# 7) routes.yaml hochladen
if [ ! -f "${MARKER_DIR}/routes.done" ]; then
  echo "[7] Lade routes.yaml hoch ..."
  curl -sSf -b "${COOKIE_JAR}" -X POST "${ORIGIN}/ghost/api/admin/settings/routes/yaml/" \
    -H "Origin: ${ORIGIN}" \
    -H "Accept-Version: ${ACCEPT_VERSION}" \
    -F "routes=@/bootstrap/routes.yaml" >/dev/null
  touch "${MARKER_DIR}/routes.done"
  echo "routes.yaml aktualisiert."
fi

# 8) Code Injection (Header)
if [ ! -f "${MARKER_DIR}/codeinj.done" ]; then
  echo "[8] Setze Code Injection (Header) ..."
  HEADER_CODE="${CODEINJECTION_HEAD:-<script>window.YT_DATA_URL_PREFIX='/proxy/youtube/data';window.YT_THUMBNAIL_URL_PREFIX='/proxy/youtube/thumbnail';</script>}"
  curl -sSf -b "${COOKIE_JAR}" -X PUT "${ORIGIN}/ghost/api/admin/settings/" \
    -H "Origin: ${ORIGIN}" \
    -H "Accept-Version: ${ACCEPT_VERSION}" \
    -H "Content-Type: application/json" \
    --data "$(jq -n --arg code "$HEADER_CODE" '{settings:[{key:"codeinjection_head", value:$code}]}')" >/dev/null
  touch "${MARKER_DIR}/codeinj.done"
  echo "Header-Injection gesetzt."
fi

echo "Bootstrap abgeschlossen."
