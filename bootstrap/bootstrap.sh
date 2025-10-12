#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# Ghost Bootstrap Script mit erweitertem Fehler-Logging
# =====================================================================
# Schaltet erweitertes Logging via Umgebungsvariablen:
#   DEBUG=1   -> curl -v (Header auf STDERR), ausführliche Schritt-Logs
#   TRACE=1   -> curl --trace-ascii /tmp/bootstrap-trace.log
#   DUMP_BODY=1 -> größere Body-Snippets in Logs zeigen
# =====================================================================

# Basis-URL: idealerweise HTTPS-Admin-Domain, z.B. https://${DOMAIN}
BASE_URL="https://${DOMAIN}"

# Optionale Public-Domain (für Host-Header in internen HTTP-Calls)
HOST_HEADER="${DOMAIN:-}"

# Dateien für Cookies und Artefakte
COOKIE="$(mktemp -t ghost-cookie.XXXXXX)"
ARTIFACT_DIR="/tmp"
ROUTES_FILE="/bootstrap/routes.yaml"
GENERATED_KEYS_FILE="/bootstrap/generated.keys.env"

UA="Mozilla/5.0 (compatible; Ghost-Bootstrap/1.0)"

log() { printf '%s %s\n' "$(date +'%F %T')" "$*" >&2; }

mask() {
  # Sensible Werte zensieren
  sed -E \
    -e 's/("password":")([^"]+)"/\1********"/g' \
    -e "s/${GHOST_SETUP_PASSWORD:-__nil__}/********/g" \
    -e 's/(GHOST_ADMIN_API_KEY=).+/\1********/g'
}

# -----------------------------------------------------------------------------
# Curl-Wrapper mit Header-/Body-Capture, Metriken und optional verbose/trace
# -----------------------------------------------------------------------------
curl_capture() {
  # Args:
  #   $1 method, $2 url, $3 headers_file_out, $4 body_file_out, $5 extra_args (array)
  local method="$1"; shift
  local url="$1"; shift
  local headers_out="$1"; shift
  local body_out="$1"; shift
  local -a extra=("$@")

  local metrics="${ARTIFACT_DIR}/bootstrap-metrics.$(date +%s%3N).json"

  # Optionales Verbose/Trace
  local -a dbg
  if [ "${DEBUG:-0}" = "1" ]; then
    dbg+=(-v)
  fi
  if [ "${TRACE:-0}" = "1" ]; then
    dbg+=(--trace-ascii "${ARTIFACT_DIR}/bootstrap-trace.log")
  fi

  # Host-Header setzen, wenn sinnvoll (verhindert 301 auf https, wenn BASE_URL intern ist)
  local -a hosthdr
  if [ -n "${HOST_HEADER}" ]; then
    hosthdr=(-H "Host: ${HOST_HEADER}")
  fi

  # Request ausführen
  curl -sS -L \
    -X "${method}" \
    -D "${headers_out}" \
    -o "${body_out}" \
    -w '{"http_code":"%{http_code}","url_effective":"%{url_effective}","redirect_url":"%{redirect_url}","content_type":"%{content_type}","time_total":"%{time_total}","remote_ip":"%{remote_ip}","ssl_verify_result":"%{ssl_verify_result}"}' \
    -c "${COOKIE}" -b "${COOKIE}" \
    -H "User-Agent: ${UA}" \
    "${hosthdr[@]}" \
    "${extra[@]}" \
    "${dbg[@]}" \
    "${url}" \
    > "${metrics}"

  # Metriken lesen
  local http_code url_effective content_type time_total redirect_url
  http_code="$(jq -r '.http_code' < "${metrics}")"
  url_effective="$(jq -r '.url_effective' < "${metrics}")"
  redirect_url="$(jq -r '.redirect_url' < "${metrics}")"
  content_type="$(jq -r '.content_type' < "${metrics}")"
  time_total="$(jq -r '.time_total' < "${metrics}")"

  log "HTTP ${method} ${url} -> ${http_code} (${content_type}, ${time_total}s)"
  log "Effektive URL: ${url_effective} Redirect: ${redirect_url:-none}"

  # Header-/Body-Snippet ausgeben (gekürzt)
  log "Response-Header:"
  head -n 50 "${headers_out}" | mask >&2

  if [ "${DUMP_BODY:-0}" = "1" ]; then
    log "Response-Body (erste 80 Zeilen):"
    head -n 80 "${body_out}" | mask >&2
  else
    log "Response-Body (erste 5 Zeilen, setze DUMP_BODY=1 für mehr):"
    head -n 5 "${body_out}" | mask >&2
  fi

  # Cookies zeigen (gekürzt)
  log "Cookie-Jar (${COOKIE}):"
  tail -n +1 "${COOKIE}" | mask | head -n 20 >&2

  echo "${http_code}"
}

# Hilfsfunktion: JSON-POST/PUT mit Body-Datei
curl_json() {
  local method="$1"; shift
  local url="$1"; shift
  local json_body="$1"; shift
  local hdr="${ARTIFACT_DIR}/bootstrap-${method}-headers.$(date +%s%3N).txt"
  local body="${ARTIFACT_DIR}/bootstrap-${method}-body.$(date +%s%3N).json"

  local -a args=(-H "Content-Type: application/json" -d "${json_body}")
  curl_capture "${method}" "${url}" "${hdr}" "${body}" "${args[@]}"
}

# Datei-Upload (multipart/form-data)
curl_upload() {
  local method="$1"; shift
  local url="$1"; shift
  local form_spec="$1"; shift
  local hdr="${ARTIFACT_DIR}/bootstrap-upload-headers.$(date +%s%3N).txt"
  local body="${ARTIFACT_DIR}/bootstrap-upload-body.$(date +%s%3N).json"

  local -a args=(-F "${form_spec}")
  curl_capture "${method}" "${url}" "${hdr}" "${body}" "${args[@]}"
}

wait_for_ghost() {
  log "Warte auf Ghost unter ${BASE_URL} ..."
  for i in $(seq 1 120); do
    local hdr="${ARTIFACT_DIR}/bootstrap-site-headers.$(date +%s%3N).txt"
    local body="${ARTIFACT_DIR}/bootstrap-site-body.$(date +%s%3N).json"
    local code
    code=$(curl_capture "GET" "${BASE_URL}/ghost/api/admin/site/" "${hdr}" "${body}")
    if [ "${code}" = "200" ]; then
      log "Ghost erreichbar."
      return 0
    fi
    sleep 2
  done
  log "Ghost wurde nicht rechtzeitig erreichbar."
  exit 1
}

setup_needed() {
  local hdr="${ARTIFACT_DIR}/bootstrap-setupchk-headers.$(date +%s%3N).txt"
  local body="${ARTIFACT_DIR}/bootstrap-setupchk-body.$(date +%s%3N).json"
  local code
  code=$(curl_capture "GET" "${BASE_URL}/ghost/api/admin/authentication/setup/" "${hdr}" "${body}")
  if [ "${code}" = "404" ]; then
    echo "no"
  else
    echo "yes"
  fi
}

do_setup() {
  log "Führe Initial-Setup durch ..."
  local payload
  payload=$(jq -n --arg n "${GHOST_SETUP_NAME}" \
                 --arg e "${GHOST_SETUP_EMAIL}" \
                 --arg p "${GHOST_SETUP_PASSWORD}" \
                 --arg t "${GHOST_SETUP_BLOG_TITLE}" \
                 '{setup:[{name:$n,email:$e,password:$p,blogTitle:$t}]}')
  local code
  code=$(curl_json "POST" "${BASE_URL}/ghost/api/admin/authentication/setup/" "$(echo "${payload}" | mask)")
  # 201 = Setup ok, 403 = bereits durchgeführt
  if [ "${code}" = "201" ]; then
    log "Setup abgeschlossen."
  elif [ "${code}" = "403" ]; then
    log "Setup bereits durchgeführt (403). Fahre fort."
  else
    log "Setup fehlgeschlagen (HTTP ${code}). Abbruch."
    exit 1
  fi
}

# CSRF-Token holen (nach Setup/Session)
get_csrf() {
  log "Hole CSRF-Token ..."
  local hdr="${ARTIFACT_DIR}/bootstrap-csrf-headers.$(date +%s%3N).txt"
  local body="${ARTIFACT_DIR}/bootstrap-csrf-body.$(date +%s%3N).json"
  local code
  code=$(curl_capture "GET" "${BASE_URL}/ghost/api/admin/site/" "${hdr}" "${body}")
  # Token aus Header extrahieren
  local token
  token="$(awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2);print $2}' "${hdr}" | head -n1 || true)"
  if [ -z "${token:-}" ]; then
    log "Kein X-CSRF-Token in Header gefunden. Versuche /users/me/ …"
    local hdr2="${ARTIFACT_DIR}/bootstrap-csrf2-headers.$(date +%s%3N).txt"
    local body2="${ARTIFACT_DIR}/bootstrap-csrf2-body.$(date +%s%3N).json"
    code=$(curl_capture "GET" "${BASE_URL}/ghost/api/admin/users/me/" "${hdr2}" "${body2}")
    token="$(awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2);print $2}' "${hdr2}" | head -n1 || true)"
  fi
  if [ -z "${token:-}" ]; then
    log "FEHLER: Kein CSRF-Token abrufbar."
    return 1
  fi
  printf '%s' "${token}"
}

# Integration anlegen oder holen; erfordert Session+CSRF
create_or_get_integration() {
  local csrf="$1"
  local name="${2:-Bootstrap Integration}"

  log "Prüfe/Erzeuge Integration: ${name}"

  local hdr="${ARTIFACT_DIR}/bootstrap-int-list-headers.$(date +%s%3N).txt"
  local body="${ARTIFACT_DIR}/bootstrap-int-list-body.$(date +%s%3N).json"
  local code
  code=$(curl_capture "GET" "${BASE_URL}/ghost/api/admin/integrations/?limit=all" "${hdr}" "${body}" -H "X-CSRF-Token: ${csrf}" -H "Origin: ${BASE_URL}")
  if [ "${code}" != "200" ]; then
    log "FEHLER: Integrationsliste HTTP ${code}"
    return 1
  fi
  local exists
  exists="$(jq -r --arg n "${name}" '.integrations[]? | select(.name==$n) | .id' < "${body}" || true)"
  if [ -n "${exists}" ]; then
    jq -r --arg n "${name}" '
      .integrations[] | select(.name==$n) | {
        name, id,
        admin_api_key: (.api_keys[]? | select(.type=="admin") | .secret),
        content_api_key: (.api_keys[]? | select(.type=="content") | .secret)
      }' < "${body}"
    return 0
  fi

  local payload
  payload=$(jq -n --arg n "${name}" '{integrations:[{name:$n}]}')
  hdr="${ARTIFACT_DIR}/bootstrap-int-add-headers.$(date +%s%3N).txt"
  body="${ARTIFACT_DIR}/bootstrap-int-add-body.$(date +%s%3N).json"
  code=$(curl_capture "POST" "${BASE_URL}/ghost/api/admin/integrations/" "${hdr}" "${body}" -H "Content-Type: application/json" -H "X-CSRF-Token: ${csrf}" -H "Origin: ${BASE_URL}" -d "${payload}")
  if [ "${code}" != "201" ]; then
    log "FEHLER: Integration anlegen HTTP ${code}"
    return 1
  fi
  jq -r '
    .integrations[0] | {
      name, id,
      admin_api_key: (.api_keys[]? | select(.type=="admin") | .secret),
      content_api_key: (.api_keys[]? | select(.type=="content") | .secret)
    }' < "${body}"
}

persist_keys() {
  local json="$1" out="${2:-$GENERATED_KEYS_FILE}"
  local ADMIN_KEY CONTENT_KEY
  ADMIN_KEY="$(echo "${json}" | jq -r '.admin_api_key // empty')"
  CONTENT_KEY="$(echo "${json}" | jq -r '.content_api_key // empty')"
  if [ -z "${ADMIN_KEY}" ]; then
    log "WARNUNG: Kein Admin API Key in Antwort."
    return 1
  fi
  mkdir -p "$(dirname "${out}")"
  {
    echo "# Generated $(date -Iseconds)"
    echo "GHOST_ADMIN_API_KEY=${ADMIN_KEY}"
    echo "GHOST_CONTENT_API_KEY=${CONTENT_KEY}"
  } > "${out}"
  log "API-Keys gespeichert: ${out}"
}

generate_jwt_token() {
  local api_key="$1"
  local id secret
  IFS=':' read -r id secret <<< "${api_key}"
  local now exp header payload signature
  now=$(date +%s)
  exp=$((now + 300))
  header=$(printf '{"alg":"HS256","typ":"JWT","kid":"%s"}' "${id}" | base64 | tr -d '=' | tr '+/' '-_')
  payload=$(printf '{"iat":%s,"exp":%s,"aud":"/admin/"}' "${now}" "${exp}" | base64 | tr -d '=' | tr '+/' '-_')
  signature=$(printf '%s.%s' "${header}" "${payload}" | openssl dgst -binary -sha256 -mac HMAC -macopt "hexkey:${secret}" | base64 | tr -d '=' | tr '+/' '-_')
  printf '%s.%s.%s' "${header}" "${payload}" "${signature}"
}

# Admin-API mit JWT (keine CSRF nötig)
api_jwt_json() {
  local method="$1" url="$2" json="$3"
  curl_json "${method}" "${url}" "${json}" > /dev/null
}

api_jwt_upload() {
  local method="$1" url="$2" form="$3"
  curl_upload "${method}" "${url}" "${form}" > /dev/null
}

download_theme() {
  local url="${SPECTRE_ZIP_URL:-}"
  [ -z "${url}" ] && { log "SPECTRE_ZIP_URL ist leer."; exit 1; }
  log "Lade Theme: ${url}"
  curl -fsSL "${url}" -o /tmp/spectre.zip
}

upload_theme() {
  local jwt="$1"
  log "Theme-Upload …"
  local hdr="${ARTIFACT_DIR}/bootstrap-theme-upload-headers.$(date +%s%3N).txt"
  local body="${ARTIFACT_DIR}/bootstrap-theme-upload-body.$(date +%s%3N).json"
  local code
  code=$(curl_capture "POST" "${BASE_URL}/ghost/api/admin/themes/upload/" "${hdr}" "${body}" -H "Authorization: Ghost ${jwt}" -F "file=@/tmp/spectre.zip")
  if ! jq -e '.themes and .themes[0].name' < "${body}" >/dev/null 2>&1; then
    log "FEHLER: Theme-Upload fehlgeschlagen (HTTP ${code})."
    return 1
  fi
  jq -r '.themes[0].name' < "${body}"
}

activate_theme() {
  local jwt="$1" name="$2"
  log "Aktiviere Theme: ${name}"
  api_jwt_json "PUT" "${BASE_URL}/ghost/api/admin/themes/${name}/activate/" "{}"
}

upload_routes() {
  local jwt="$1"
  [ -f "${ROUTES_FILE}" ] || { log "routes.yaml nicht gefunden: ${ROUTES_FILE}"; return 0; }
  log "Importiere routes.yaml …"
  local hdr="${ARTIFACT_DIR}/bootstrap-routes-headers.$(date +%s%3N).txt"
  local body="${ARTIFACT_DIR}/bootstrap-routes-body.$(date +%s%3N).json"
  curl_capture "PUT" "${BASE_URL}/ghost/api/admin/settings/routes/yaml" "${hdr}" "${body}" -H "Authorization: Ghost ${jwt}" -F "file=@${ROUTES_FILE};type=text/yaml" > /dev/null
}

update_navigation() {
  local jwt="$1"
  log "Aktualisiere Navigation …"
  local payload='{
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
  api_jwt_json "PUT" "${BASE_URL}/ghost/api/admin/settings/" "${payload}"
}

resource_exists() {
  local jwt="$1" type="$2" slug="$3"
  local hdr="${ARTIFACT_DIR}/bootstrap-exists-headers.$(date +%s%3N).txt"
  local body="${ARTIFACT_DIR}/bootstrap-exists-body.$(date +%s%3N).json"
  local code
  code=$(curl_capture "GET" "${BASE_URL}/ghost/api/admin/${type}/slug/${slug}/?formats=html" "${hdr}" "${body}" -H "Authorization: Ghost ${jwt}" -H "Accept: application/json")
  [ "${code}" = "200" ]
}

create_page() {
  local jwt="$1" slug="$2" title="$3" file="$4" show_title="${5:-true}"
  if resource_exists "${jwt}" "pages" "${slug}"; then
    log "Seite '${slug}' existiert bereits, überspringe."
    return
  fi
  local html jq_data
  html="$(< "${file}")"
  if [ "${show_title}" = "false" ]; then
    jq_data=$(jq -n --arg title "${title}" --arg slug "${slug}" --arg html "${html}" --arg author "${GHOST_SETUP_EMAIL}" --argjson show_image false \
      '{pages:[{title:$title,slug:$slug,status:"published",html:$html,authors:[{email:$author}],show_title_and_feature_image:$show_image}]}')
  else
    jq_data=$(jq -n --arg title "${title}" --arg slug "${slug}" --arg html "${html}" --arg author "${GHOST_SETUP_EMAIL}" \
      '{pages:[{title:$title,slug:$slug,status:"published",html:$html,authors:[{email:$author}]}]}')
  fi
  api_jwt_json "POST" "${BASE_URL}/ghost/api/admin/pages/" "${jq_data}"
}

create_post() {
  local jwt="$1" slug="$2" title="$3" file="$4" tags_json="$5" feature_image="${6:-}"
  if resource_exists "${jwt}" "posts" "${slug}"; then
    log "Post '${slug}' existiert bereits, überspringe."
    return
  fi
  local html jq_data
  html="$(< "${file}")"
  if [ -n "${feature_image}" ]; then
    jq_data=$(jq -n --arg title "${title}" --arg slug "${slug}" --arg html "${html}" --arg author "${GHOST_SETUP_EMAIL}" --arg json_tags "${tags_json}" --arg feature_image "${feature_image}" \
      '{posts:[{title:$title,slug:$slug,status:"published",html:$html,feature_image:$feature_image,authors:[{email:$author}],tags:($json_tags|fromjson)}]}')
  else
    jq_data=$(jq -n --arg title "${title}" --arg slug "${slug}" --arg html "${html}" --arg author "${GHOST_SETUP_EMAIL}" --arg json_tags "${tags_json}" \
      '{posts:[{title:$title,slug:$slug,status:"published",html:$html,authors:[{email:$author}],tags:($json_tags|fromjson)}]}')
  fi
  api_jwt_json "POST" "${BASE_URL}/ghost/api/admin/posts/" "${jq_data}"
}

# =====================================================================
# Hauptablauf
# =====================================================================
main() {
  log "=== Ghost Bootstrap Script gestartet ==="
  log "BASE_URL=${BASE_URL} HOST_HEADER=${HOST_HEADER:-<leer>} (DEBUG=${DEBUG:-0} TRACE=${TRACE:-0} DUMP_BODY=${DUMP_BODY:-0})" | mask

  wait_for_ghost

  # 1) Setup (idempotent behandeln)
  if [ "$(setup_needed)" = "yes" ]; then
    log "Setup wird durchgeführt ..."
    do_setup
  else
    log "Setup bereits erledigt (setup_needed=no)."
  fi

  # 2) CSRF holen (nur für Integration, danach JWT-only)
  local csrf=""
  if ! csrf="$(get_csrf)"; then
    log "WARNUNG: CSRF nicht verfügbar. Versuche Integration mit bestehender Session könnte scheitern."
  fi

  # 3) Integration anlegen/holen und Keys persistieren
  local keys_json=""
  if keys_json="$(create_or_get_integration "${csrf}")"; then
    persist_keys "${keys_json}" || true
  else
    log "FEHLER: Integration konnte nicht erstellt/gelesen werden."
    exit 1
  fi

  local ADMIN_KEY
  ADMIN_KEY="$(echo "${keys_json}" | jq -r '.admin_api_key')"
  if [ -z "${ADMIN_KEY}" ] || [ "${ADMIN_KEY}" = "null" ]; then
    log "FEHLER: Kein Admin API Key erhalten."
    exit 1
  fi
  local JWT_TOKEN
  JWT_TOKEN="$(generate_jwt_token "${ADMIN_KEY}")"
  log "JWT-Token generiert."

  # 4) Theme
  download_theme
  local theme_name
  if ! theme_name="$(upload_theme "${JWT_TOKEN}")"; then
    log "FEHLER: Theme-Upload fehlgeschlagen."
    exit 1
  fi
  activate_theme "${JWT_TOKEN}" "${theme_name}"

  # 5) Routes / Navigation
  upload_routes "${JWT_TOKEN}"
  update_navigation "${JWT_TOKEN}"

  # 6) Seiten
  sed -e "s|\[BLOGTITLE\]|${GHOST_SETUP_BLOG_TITLE}|g" \
      /bootstrap/pages/start.html > /tmp/start.html
  create_page "${JWT_TOKEN}" "start" "Start" "/tmp/start.html" "false"

  YEAR_NOW=$(date '+%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      -e "s|\[DOMAIN\]|${DOMAIN}|g" \
      -e "s|\[JAHR\]|${YEAR_NOW}|g" \
      /bootstrap/pages/impressum.html > /tmp/impressum.html
  create_page "${JWT_TOKEN}" "impressum" "Impressum" "/tmp/impressum.html" "true"

  DATE_NOW=$(date '+%d.%m.%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[DATUM\]|${DATE_NOW}|g" \
      /bootstrap/pages/datenschutz.html > /tmp/datenschutz.html
  create_page "${JWT_TOKEN}" "datenschutz" "Datenschutzerklärung" "/tmp/datenschutz.html" "true"

  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/pages/presse.html > /tmp/presse.html
  create_page "${JWT_TOKEN}" "presse" "Presse" "/tmp/presse.html" "true"

  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      /bootstrap/pages/beispielseite.html > /tmp/beispielseite.html
  create_page "${JWT_TOKEN}" "beispielseite" "Beispielseite" "/tmp/beispielseite.html" "true"

  # 7) Posts
  create_post "${JWT_TOKEN}" "beispiel-post" "Beispiel-Blogpost" \
    "/bootstrap/posts/beispiel-post.html" \
    '[]' \
    "https://images.unsplash.com/photo-1599045118108-bf9954418b76?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=2000"

  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/posts/beispiel-pressemitteilung.html > /tmp/beispiel-pressemitteilung.html
  create_post "${JWT_TOKEN}" "beispiel-pressemitteilung" "Beispiel-Pressemitteilung" \
    "/tmp/beispiel-pressemitteilung.html" \
    '[{"name":"#pressemitteilung"}]'

  log "=== Bootstrap erfolgreich abgeschlossen ==="
}

main
