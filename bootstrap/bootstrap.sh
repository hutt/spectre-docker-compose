#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Ghost Bootstrap Script – robust, idempotent & kompatibel mit v6.x
# ============================================================

BASE_URL="https://${DOMAIN}"
UA="Ghost-Bootstrap/1.0"
KEYS_FILE="/bootstrap/generated.keys.env"
ROUTES_FILE="/bootstrap/routes.yaml"

log() {
  printf '%s %s\n' "$(date +'%F %T')" "$*" >&2
}

# ----------------------------------------------------------------------------
# Schritt 1: Prüfen, ob Initial-Setup nötig ist
# ----------------------------------------------------------------------------
setup_needed() {
  local body
  body=$(curl -sSf \
    -H "Accept-Version: v6" \
    -H "User-Agent: ${UA}" \
    "${BASE_URL}/ghost/api/admin/authentication/setup/")
  if echo "$body" | jq -e '.setup[0].status == true' >/dev/null; then
    echo "yes"
  else
    echo "no"
  fi
}

# ----------------------------------------------------------------------------
# Schritt 2: Initial-Setup (Owner-Account erstellen)
# ----------------------------------------------------------------------------
do_setup() {
  log "Initial-Setup..."
  local payload resp code
  payload=$(jq -nc \
    --arg name "$GHOST_SETUP_NAME" \
    --arg email "$GHOST_SETUP_EMAIL" \
    --arg password "$GHOST_SETUP_PASSWORD" \
    --arg title "$GHOST_SETUP_BLOG_TITLE" \
    '{setup:[{name:$name,email:$email,password:$password,blogTitle:$title}]}')
  resp=$(curl -sS -D - \
    -H "Content-Type: application/json" \
    -H "Accept-Version: v6" \
    -H "User-Agent: ${UA}" \
    -X POST -d "$payload" \
    "${BASE_URL}/ghost/api/admin/authentication/setup/")
  code=$(echo "$resp" | awk 'NR==1{print $2}')
  if [ "$code" != "201" ]; then
    log "Setup fehlgeschlagen (HTTP $code)"; exit 1
  fi
  echo "$resp" | sed -n '/^{/,/^}/p' > /tmp/setup-response.json
  log "Setup erfolgreich."
}

# ----------------------------------------------------------------------------
# JWT-Token erzeugen aus Admin-API-Key
# ----------------------------------------------------------------------------
generate_jwt() {
  local key=$1 id secret now exp header payload signature
  IFS=':' read -r id secret <<< "$key"
  now=$(date +%s); exp=$((now+300))
  header=$(printf '{"alg":"HS256","typ":"JWT","kid":"%s"}' "$id" \
    | openssl base64 -A | tr '/+' '_-' | tr -d '=')
  payload=$(printf '{"iat":%s,"exp":%s,"aud":"/admin/"}' "$now" "$exp" \
    | openssl base64 -A | tr '/+' '_-' | tr -d '=')
  signature=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -binary -mac HMAC -macopt hexkey:"$secret" \
    | openssl base64 -A | tr '/+' '_-' | tr -d '=')
  JWT_TOKEN="${header}.${payload}.${signature}"
}

# ----------------------------------------------------------------------------
# JWT-geschützte Admin-API
# ----------------------------------------------------------------------------
api_jwt() {
  local method=$1 path=$2 body=${3:-}
  curl -sSf \
    -H "Authorization: Ghost ${JWT_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept-Version: v6" \
    -H "User-Agent: ${UA}" \
    -X "$method" \
    ${body:+-d "$body"} \
    "${BASE_URL}/ghost/api/admin${path}"
}

# ----------------------------------------------------------------------------
# Einmalig: Integration per Session+CSRF anlegen, um API-Key zu ziehen
# ----------------------------------------------------------------------------
create_integration_via_session() {
  log "Erzeuge Integration per Admin-Session (einmalig)..."
  local cookie hdr csrf payload resp
  cookie=$(mktemp -t ghost-cookie.XXXXXX)
  hdr=$(mktemp -t ghost-hdr.XXXXXX)

  # Session-Login
  curl -sS -D "$hdr" -c "$cookie" -b "$cookie" \
    -H "Content-Type: application/json" \
    -H "Accept-Version: v6" \
    -H "User-Agent: ${UA}" \
    -X POST -d "$(jq -nc --arg u "$GHOST_SETUP_EMAIL" --arg p "$GHOST_SETUP_PASSWORD" '{username:$u,password:$p}')" \
    "${BASE_URL}/ghost/api/admin/session/" >/dev/null

  # CSRF-Token holen
  curl -sS -D "$hdr" -c "$cookie" -b "$cookie" \
    -H "Accept-Version: v6" \
    -H "User-Agent: ${UA}" \
    "${BASE_URL}/ghost/api/admin/site/" >/dev/null
  csrf=$(awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2);print $2}' "$hdr" | head -n1)

  [ -n "$csrf" ] || { log "CSRF-Token nicht erhalten"; exit 1; }

  payload='{"integrations":[{"name":"Bootstrap Integration"}]}'
  resp=$(curl -sS -D "$hdr" -c "$cookie" -b "$cookie" \
    -H "Content-Type: application/json" \
    -H "Accept-Version: v6" \
    -H "User-Agent: ${UA}" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -X POST -d "$payload" \
    "${BASE_URL}/ghost/api/admin/integrations/")
  echo "$resp" | jq -r \
    '.integrations[0]|{admin_api_key:(.api_keys[]|select(.type=="admin")|.secret),content_api_key:(.api_keys[]|select(.type=="content")|.secret)}'
}

# ----------------------------------------------------------------------------
# Mittels JWT: Integration prüfen/erstellen
# ----------------------------------------------------------------------------
create_or_get_integration() {
  log "Prüfe/Erstelle Integration (JWT)..."
  local list id resp
  list=$(api_jwt GET /integrations/?limit=all)
  id=$(echo "$list" | jq -r '.integrations[]? | select(.name=="Bootstrap Integration")|.id')
  if [ -n "$id" ] && [ "$id" != "null" ]; then
    echo "$list" | jq -r \
      '.integrations[]|select(.name=="Bootstrap Integration")|{admin_api_key:(.api_keys[]|select(.type=="admin")|.secret),content_api_key:(.api_keys[]|select(.type=="content")|.secret)}'
  else
    resp=$(api_jwt POST /integrations/ "$(jq -nc --arg n "Bootstrap Integration" '{integrations:[{name:$n}]}')")
    echo "$resp" | jq -r \
      '.integrations[0]|{admin_api_key:(.api_keys[]|select(.type=="admin")|.secret),content_api_key:(.api_keys[]|select(.type=="content")|.secret)}'
  fi
}

# ----------------------------------------------------------------------------
# Persistieren und Laden von API-Keys
# ----------------------------------------------------------------------------
persist_keys() {
  local admin content
  admin=$(echo "$1" | jq -r '.admin_api_key')
  content=$(echo "$1" | jq -r '.content_api_key')
  mkdir -p "$(dirname "$KEYS_FILE")"
  printf 'GHOST_ADMIN_API_KEY=%s\nGHOST_CONTENT_API_KEY=%s\n' "$admin" "$content" > "$KEYS_FILE"
  log "Keys gespeichert in $KEYS_FILE"
}

load_keys() {
  if [ -f "$KEYS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$KEYS_FILE"
    if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
      generate_jwt "$GHOST_ADMIN_API_KEY"
      log "JWT aus gespeicherten Keys erzeugt."
      return 0
    fi
  fi
  return 1
}

# ----------------------------------------------------------------------------
# Content-Bootstrap: Theme, Routes, Navigation, Seiten, Posts
# ----------------------------------------------------------------------------
bootstrap_content() {
  log "Lade Theme herunter"
  curl -fsSL "$SPECTRE_ZIP_URL" -o /tmp/spectre.zip
  log "Upload & Aktiviere Theme"
  local theme
  theme=$(curl -sS -H "Authorization: Ghost ${JWT_TOKEN}" \
    -F "file=@/tmp/spectre.zip" \
    "${BASE_URL}/ghost/api/admin/themes/upload/" \
    | jq -r '.themes[0].name')
  api_jwt PUT /themes/"$theme"/activate/ '{}'

  if [ -f "$ROUTES_FILE" ]; then
    log "Importiere Routes"
    curl -sS -H "Authorization: Ghost ${JWT_TOKEN}" \
      -F "file=@${ROUTES_FILE};type=text/yaml" \
      "${BASE_URL}/ghost/api/admin/settings/routes/yaml" >/dev/null
  fi

  log "Setze Navigation"
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
  }'

  log "Erstelle Seiten"
  for page in start impressum datenschutz presse beispielseite; do
    local title html body
    case "$page" in
      start) title="Start";;
      impressum) title="Impressum";;
      datenschutz) title="Datenschutzerklärung";;
      presse) title="Presse";;
      beispielseite) title="Beispielseite";;
    esac
    html="/bootstrap/pages/${page}.html"
    body=$(jq -nr \
      --arg t "$title" \
      --arg s "$page" \
      --arg h "$(sed ':a;N;$!ba;s/\n/\\n/g' "$html")" \
      --arg e "$GHOST_SETUP_EMAIL" \
      '{pages:[{title:$t,slug:$s,status:"published",html:$h,authors:[{email:$e}]}]}')
    api_jwt POST /pages/ "$body" >/dev/null
  done

  log "Erstelle Beispiel-Posts"
  api_jwt POST /posts/ "$(jq -nr \
    --arg h "$(sed ':a;N;$!ba;s/\n/\\n/g' /bootstrap/posts/beispiel-post.html)" \
    --arg e "$GHOST_SETUP_EMAIL" \
    '{posts:[{title:"Beispiel-Blogpost",slug:"beispiel-post",status:"published",html:$h,authors:[{email:$e}],tags:[]}]}' )" >/dev/null

  api_jwt POST /posts/ "$(jq -nr \
    --arg h "$(sed ':a;N;$!ba;s/\n/\\n/g' /bootstrap/posts/beispiel-pressemitteilung.html)" \
    --arg e "$GHOST_SETUP_EMAIL" \
    '{posts:[{title:"Beispiel-Pressemitteilung",slug:"beispiel-pressemitteilung",status:"published",html:$h,authors:[{email:$e}],tags:[{name:"#pressemitteilung"}]}]}' )" >/dev/null

  log "Content-Bootstrap abgeschlossen."
}

# =============================================================================
main() {
  log "=== Starte Ghost-Bootstrap ==="

  # 1) Setup durchführen, falls nötig
  if [ "$(setup_needed)" = "yes" ]; then
    do_setup
  else
    log "Initial-Setup bereits erfolgt."
  fi

  # 2) JWT initialisieren: Lade Keys oder lege Integration einmalig an
  if ! load_keys; then
    local keys_json
    keys_json=$(create_integration_via_session)
    persist_keys "$keys_json"
    GHOST_ADMIN_API_KEY=$(echo "$keys_json" | jq -r '.admin_api_key')
    generate_jwt "$GHOST_ADMIN_API_KEY"
  fi

  # 3) Integration per JWT ergänzen, Keys erneuern
  local integ_json
  integ_json=$(create_or_get_integration)
  persist_keys "$integ_json"

  # 4) Content-Bootstrap
  bootstrap_content
}

main
