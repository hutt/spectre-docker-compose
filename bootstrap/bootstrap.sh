#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Konfiguration
# ------------------------------------------------------------
# Interne Ghost-URL nur für Healthchecks (keine Auth-Operationen)
INTERNAL_BASE_URL="http://ghost:2368"
# Öffentliche Admin-URL exakt wie in Ghost konfiguriert (Compose: url=https://${DOMAIN})
# Alle Admin-API-Calls, die Auth/CSRF/Domain-Semantik brauchen, laufen über diese URL.
ADMIN_URL="${ADMIN_URL:-https://${DOMAIN}}"

COOKIE="$(mktemp)"                         # Gemeinsamer Cookie-Jar
ROUTES_FILE="/bootstrap/routes.yaml"       # routes.yaml Quelle
GENERATED_KEYS_FILE="/bootstrap/generated.keys.env"
UA="Mozilla/5.0 (compatible; Ghost-Bootstrap/1.0)"  # Konsistenter User-Agent
APIVER="v6.0"                              # Ghost Admin API Version Header

log() { printf '%s %s\n' "$(date +'%F %T')" "$*" >&2; }

# ------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------

# Warten bis Ghost intern erreichbar ist (kein Redirect-Kontext nötig)
wait_for_ghost() {
  log "Warte auf Ghost unter ${INTERNAL_BASE_URL} ..."
  for i in $(seq 1 120); do
    if curl -sf \
         -c "$COOKIE" -b "$COOKIE" \
         -H "Accept: application/json" \
         -H "Accept-Version: $APIVER" \
         -H "User-Agent: $UA" \
         "${INTERNAL_BASE_URL}/ghost/api/admin/site/" >/dev/null; then
      log "Ghost erreichbar."
      return 0
    fi
    sleep 2
  done
  log "Ghost wurde nicht rechtzeitig erreichbar."
  exit 1
}

# Prüfen, ob Ersteinrichtung noch nötig ist
setup_needed() {
  # Wichtig: den Setup-Endpoint auf der ADMIN_URL (öffentliche Domain) abfragen
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -L \
    -c "$COOKIE" -b "$COOKIE" \
    -H "Accept: application/json" \
    -H "Accept-Version: $APIVER" \
    -H "User-Agent: $UA" \
    "${ADMIN_URL}/ghost/api/admin/authentication/setup/")
  if [ "$code" = "404" ]; then
    echo "no"
  else
    echo "yes"
  fi
}

# Ersteinrichtung ohne CSRF (Ghost 6: Setup benötigt keinen CSRF)
do_setup() {
  log "Führe Initial-Setup durch ..."
  local payload
  payload=$(jq -n --arg n "$GHOST_SETUP_NAME" \
                  --arg e "$GHOST_SETUP_EMAIL" \
                  --arg p "$GHOST_SETUP_PASSWORD" \
                  --arg t "$GHOST_SETUP_BLOG_TITLE" \
                  '{setup:[{name:$n,email:$e,password:$p,blogTitle:$t}]}')

  # Setup-Call über ADMIN_URL, Origin muss zur Domain passen; -L erlaubt etwaige Redirects
  local code
  code=$(curl -s -o /tmp/setup.res -w "%{http_code}" -L \
    -c "$COOKIE" -b "$COOKIE" \
    -H "Content-Type: application/json" \
    -H "Origin: ${ADMIN_URL}" \
    -H "Accept-Version: $APIVER" \
    -H "User-Agent: $UA" \
    -X POST \
    -d "$payload" \
    "${ADMIN_URL}/ghost/api/admin/authentication/setup/")
  if [ "$code" != "201" ]; then
    log "Setup fehlgeschlagen (HTTP $code):"
    sed -n '1,200p' /tmp/setup.res >&2 || true
    exit 1
  fi
  log "Setup abgeschlossen."
}

# Nach dem Setup: CSRF-Token aus Response-Headern beziehen (nur für Integrations-Erstellung nötig)
# Wichtig: immer auf ADMIN_URL, damit Domain/Cookie/Header übereinstimmen
get_csrf() {
  log "Hole CSRF-Token ..."
  local headers token
  headers="$(mktemp)"

  # GET /site auf ADMIN_URL liefert bei gültiger Session 'X-CSRF-Token'
  curl -s -L -D "$headers" -o /dev/null \
       -c "$COOKIE" -b "$COOKIE" \
       -H "Accept: application/json" \
       -H "Accept-Version: $APIVER" \
       -H "Origin: ${ADMIN_URL}" \
       -H "User-Agent: $UA" \
       "${ADMIN_URL}/ghost/api/admin/site/"

  token="$(awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2);print $2}' "$headers" || true)"

  if [ -z "${token:-}" ]; then
    log "Kein CSRF-Token im Header gefunden (prüfe Admin-Domain, Cookies, Redirects)."
    exit 1
  fi

  echo "$token"
}

# Bestehende Integrationen lesen / neue Integration anlegen
create_or_get_integration() {
  local csrf="$1" name="${2:-Bootstrap Integration}"

  # 1) Liste vorhandener Integrationen holen (idempotent)
  local existing id
  existing=$(curl -s -L \
    -c "$COOKIE" -b "$COOKIE" \
    -H "Accept: application/json" \
    -H "Accept-Version: $APIVER" \
    -H "Origin: ${ADMIN_URL}" \
    -H "User-Agent: $UA" \
    "${ADMIN_URL}/ghost/api/admin/integrations/?limit=all" || true)

  id=$(echo "$existing" | jq -r --arg n "$name" '.integrations[]? | select(.name==$n) | .id' 2>/dev/null || true)
  if [ -n "${id:-}" ] && [ "$id" != "null" ]; then
    log "Integration '$name' existiert bereits (id=$id)."
    echo "$existing" | jq -r --arg n "$name" '
      .integrations[] | select(.name==$n) |
      {
        name, id,
        admin_api_key: (.api_keys[]? | select(.type=="admin") | .secret),
        content_api_key: (.api_keys[]? | select(.type=="content") | .secret)
      }'
    return 0
  fi

  # 2) Neue Integration anlegen (POST), benötigt gültige Session + CSRF
  log "Erstelle Integration '$name' …"
  local resp
  resp=$(curl -s -L \
    -c "$COOKIE" -b "$COOKIE" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "Accept-Version: $APIVER" \
    -H "Origin: ${ADMIN_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -H "User-Agent: $UA" \
    -X POST \
    -d "$(jq -n --arg n "$name" '{integrations:[{name:$n}]}')" \
    "${ADMIN_URL}/ghost/api/admin/integrations/")

  echo "$resp" | jq -r '
    .integrations[0] |
    {
      name, id,
      admin_api_key: (.api_keys[]? | select(.type=="admin") | .secret),
      content_api_key: (.api_keys[]? | select(.type=="content") | .secret)
    }'
}

# Admin-/Content-Keys persistieren (für spätere Läufe)
persist_keys() {
  local json="$1" out="${2:-$GENERATED_KEYS_FILE}"
  local ADMIN_KEY CONTENT_KEY
  ADMIN_KEY=$(echo "$json" | jq -r '.admin_api_key // empty')
  CONTENT_KEY=$(echo "$json" | jq -r '.content_api_key // empty')
  [ -z "$ADMIN_KEY" ] && { log "Kein Admin API Key in Antwort gefunden."; return 1; }
  mkdir -p "$(dirname "$out")"
  {
    echo "# generated by bootstrap $(date -Iseconds)"
    echo "GHOST_ADMIN_API_KEY=$ADMIN_KEY"
    echo "GHOST_CONTENT_API_KEY=$CONTENT_KEY"
  } > "$out"
  log "API-Keys gespeichert unter $out"
}

# Bereits generierte Keys laden (idempotent)
load_generated_keys() {
  if [ -f "$GENERATED_KEYS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$GENERATED_KEYS_FILE"
    export GHOST_ADMIN_API_KEY="${GHOST_ADMIN_API_KEY:-}"
    export GHOST_CONTENT_API_KEY="${GHOST_CONTENT_API_KEY:-}"
    if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
      log "Geladener Admin API Key aus ${GENERATED_KEYS_FILE}."
    fi
  fi
}

# Base64 URL-sicher (ohne =, +/, Zeilenumbrüche)
b64url() {
  openssl base64 -A 2>/dev/null | tr -d '=' | tr '+/' '-_'
}

# JWT aus Admin API Key (id:secretHEX) erzeugen (HS256, aud=/admin/)
generate_jwt_token() {
  local api_key="$1"
  local id secret
  IFS=':' read -r id secret <<< "$api_key"

  local now exp header payload signature
  now=$(date +%s)
  exp=$((now + 300))  # 5 Minuten

  header=$(printf '{"alg":"HS256","typ":"JWT","kid":"%s"}' "$id" | b64url)
  payload=$(printf '{"iat":%s,"exp":%s,"aud":"/admin/"}' "$now" "$exp" | b64url)
  signature=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -binary -sha256 -mac HMAC -macopt hexkey:"$secret" \
    | b64url)

  printf '%s.%s.%s' "$header" "$payload" "$signature"
}

# Einheitlicher Wrapper für Admin-API Calls mit JWT (bevorzugt) oder Cookie+CSRF
# Nutzung: api_call "<METHOD>" "<PATH>" "<JSON_BODY|empty>" "<CSRF|empty>" "<IS_MULTIPART:true|false>"
api_call() {
  local method="$1" path="$2" body="${3:-}" csrf="${4:-}" is_multipart="${5:-false}"
  local url="${ADMIN_URL}${path}"

  if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
    # Auth via JWT aus Admin API Key
    local token
    token="$(generate_jwt_token "$GHOST_ADMIN_API_KEY")"
    if [ "$is_multipart" = "true" ]; then
      # body enthält die -F Parameter (wird via eval-ähnlicher Expansion direkt übergeben)
      curl -s -L \
        -H "Authorization: Ghost ${token}" \
        -H "Accept-Version: $APIVER" \
        -H "User-Agent: $UA" \
        -X "$method" \
        $body \
        "$url"
    else
      curl -s -L \
        -H "Authorization: Ghost ${token}" \
        -H "Content-Type: application/json" \
        -H "Accept-Version: $APIVER" \
        -H "User-Agent: $UA" \
        -X "$method" \
        ${body:+-d "$body"} \
        "$url"
    fi
  else
    # Fallback: Session-Cookies + CSRF (nur kurz nach Setup genutzt)
    if [ "$is_multipart" = "true" ]; then
      curl -s -L \
        -c "$COOKIE" -b "$COOKIE" \
        -H "Origin: ${ADMIN_URL}" \
        -H "X-CSRF-Token: ${csrf}" \
        -H "Accept-Version: $APIVER" \
        -H "User-Agent: $UA" \
        -X "$method" \
        $body \
        "$url"
    else
      curl -s -L \
        -c "$COOKIE" -b "$COOKIE" \
        -H "Content-Type: application/json" \
        -H "Origin: ${ADMIN_URL}" \
        -H "X-CSRF-Token: ${csrf}" \
        -H "Accept-Version: $APIVER" \
        -H "User-Agent: $UA" \
        -X "$method" \
        ${body:+-d "$body"} \
        "$url"
    fi
  fi
}

# Theme herunterladen und hochladen (Upload-Endpoint erlaubt Integrations-Auth)
download_theme() {
  local url="${SPECTRE_ZIP_URL:-}"
  [ -z "$url" ] && { log "SPECTRE_ZIP_URL ist leer."; exit 1; }
  log "Lade Theme: ${url}"
  curl -fsSL "$url" -o /tmp/spectre.zip
}

upload_theme() {
  log "Lade Theme zu Ghost hoch ..."
  local resp
  if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
    resp=$(api_call "POST" "/ghost/api/admin/themes/upload/" "-F file=@/tmp/spectre.zip" "" "true")
  else
    # Nur falls JWT noch nicht verfügbar ist (unwahrscheinlich), Cookie+CSRF nutzen
    local csrf="${1:-}"
    resp=$(api_call "POST" "/ghost/api/admin/themes/upload/" "-F file=@/tmp/spectre.zip" "$csrf" "true")
  fi

  echo "$resp" | tee /tmp/theme-upload.json >/dev/null
  if ! jq -e '.themes and .themes[0].name' /tmp/theme-upload.json >/dev/null 2>&1; then
    log "Theme-Upload fehlgeschlagen. Antwort:"
    sed -n '1,200p' /tmp/theme-upload.json >&2 || true
    exit 1
  fi
  jq -r '.themes[0].name' /tmp/theme-upload.json
}

activate_theme() {
  local name="$1"
  log "Aktiviere Theme: ${name}"
  api_call "PUT" "/ghost/api/admin/themes/${name}/activate/" "" "" "false" >/dev/null
}

upload_routes() {
  [ -f "$ROUTES_FILE" ] || { log "routes.yaml nicht gefunden unter ${ROUTES_FILE}"; return 0; }
  log "Importiere routes.yaml ..."
  api_call "PUT" "/ghost/api/admin/settings/routes/yaml" "-F file=@${ROUTES_FILE};type=text/yaml" "" "true" >/dev/null
}

# Existenzcheck per slug (mit JWT; ohne JWT nicht zuverlässig über Admin-Domain)
resource_exists() {
  local type="$1" slug="$2"
  local token code
  if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
    token="$(generate_jwt_token "$GHOST_ADMIN_API_KEY")"
    code=$(curl -s -o /dev/null -w "%{http_code}" -L \
      -H "Accept: application/json" \
      -H "Accept-Version: $APIVER" \
      -H "Authorization: Ghost ${token}" \
      -H "User-Agent: $UA" \
      "${ADMIN_URL}/ghost/api/admin/${type}/slug/${slug}/?formats=html")
    [ "$code" = "200" ]
  else
    # Fallback: ohne JWT keinen harten Fehler, aber 'false' zurückgeben
    return 1
  fi
}

create_page() {
  local slug="$1" title="$2" file="$3" show_title_and_feature_image="${4:-true}"
  if resource_exists "pages" "$slug"; then
    log "Seite '$slug' existiert bereits, überspringe."
    return
  fi
  local html jq_data
  html="$(< "$file")"
  log "Erstelle Seite '$slug' …"

  if [ "$show_title_and_feature_image" = "false" ]; then
    jq_data=$(jq -n \
      --arg title "$title" \
      --arg slug "$slug" \
      --arg html "$html" \
      --arg author "$GHOST_SETUP_EMAIL" \
      --argjson show_image false \
      '{pages:[{title:$title,slug:$slug,status:"published",html:$html,authors:[{email:$author}],meta: {"show_title_and_feature_image": $show_image}}]}')
  else
    jq_data=$(jq -n \
      --arg title "$title" \
      --arg slug "$slug" \
      --arg html "$html" \
      --arg author "$GHOST_SETUP_EMAIL" \
      '{pages:[{title:$title,slug:$slug,status:"published",html:$html,authors:[{email:$author}]}]}')
  fi

  api_call "POST" "/ghost/api/admin/pages/" "$jq_data" "" "false" >/dev/null
}

create_post() {
  local slug="$1" title="$2" file="$3" tags_json="$4" feature_image="${5:-}"
  if resource_exists "posts" "$slug"; then
    log "Post '$slug' existiert bereits, überspringe."
    return
  fi
  local html jq_data
  html="$(< "$file")"
  log "Erstelle Post '$slug' …"

  if [ -n "$feature_image" ]; then
    jq_data=$(jq -n \
      --arg title "$title" \
      --arg slug  "$slug" \
      --arg html  "$html" \
      --arg author "$GHOST_SETUP_EMAIL" \
      --arg json_tags "$tags_json" \
      --arg feature_image "$feature_image" \
      '{posts:[{title:$title,slug:$slug,status:"published",html:$html,feature_image:$feature_image,authors:[{email:$author}],tags:( $json_tags | fromjson )}]}')
  else
    jq_data=$(jq -n \
      --arg title "$title" \
      --arg slug  "$slug" \
      --arg html  "$html" \
      --arg author "$GHOST_SETUP_EMAIL" \
      --arg json_tags "$tags_json" \
      '{posts:[{title:$title,slug:$slug,status:"published",html:$html,authors:[{email:$author}],tags:( $json_tags | fromjson )}]}')
  fi

  api_call "POST" "/ghost/api/admin/posts/" "$jq_data" "" "false" >/dev/null
}

update_navigation() {
  log "Aktualisiere Haupt- und sekundäre Navigation …"
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
  api_call "PUT" "/ghost/api/admin/settings/?source=html" "$body" "" "false" >/dev/null
}

# ------------------------------------------------------------
# Hauptablauf
# ------------------------------------------------------------
main() {
  wait_for_ghost
  load_generated_keys

  # 1) Setup falls nötig – zwingend über ADMIN_URL aufrufen (keinen CSRF nötig)
  if [ "$(setup_needed)" = "yes" ]; then
    do_setup

    # 2) Nach Setup: CSRF für Integrations-Erstellung holen (gleiche ADMIN_URL & Cookie)
    local csrf
    csrf="$(get_csrf)"

    # 3) Integration anlegen und Keys persistieren
    local keys_json
    keys_json="$(create_or_get_integration "$csrf" "Bootstrap Integration")"
    persist_keys "$keys_json" "$GENERATED_KEYS_FILE"

    # Admin-Key in diese Laufzeit übernehmen (ab jetzt nur noch JWT)
    export GHOST_ADMIN_API_KEY
    GHOST_ADMIN_API_KEY="$(echo "$keys_json" | jq -r '.admin_api_key')"
    [ -n "$GHOST_ADMIN_API_KEY" ] || { log "Admin API Key leer."; exit 1; }
  else
    # Kein Setup nötig – Admin-Key laden erwartet
    if [ -z "${GHOST_ADMIN_API_KEY:-}" ]; then
      log "Warnung: Kein GHOST_ADMIN_API_KEY in Umgebung; versuche geladenen Key."
      if [ -f "$GENERATED_KEYS_FILE" ]; then
        # shellcheck disable=SC1090
        . "$GENERATED_KEYS_FILE"
        export GHOST_ADMIN_API_KEY="${GHOST_ADMIN_API_KEY:-}"
      fi
      [ -n "${GHOST_ADMIN_API_KEY:-}" ] || { log "Kein Admin API Key verfügbar."; exit 1; }
    fi
  fi

  # 4) Theme laden/hochladen/aktivieren (JWT)
  download_theme
  theme_name="$(upload_theme)"
  [ -n "$theme_name" ] && activate_theme "$theme_name"

  # 5) routes.yaml importieren (JWT)
  upload_routes

  # 6) Navigation setzen (JWT)
  update_navigation

  # 7) Seiten anlegen (JWT)
  sed -e "s|\[BLOGTITLE\]|${GHOST_SETUP_BLOG_TITLE}|g" \
      /bootstrap/pages/start.html > /tmp/start.html
  create_page "start" "Start" "/tmp/start.html" "false"

  YEAR_NOW=$(date '+%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      -e "s|\[DOMAIN\]|${DOMAIN}|g" \
      -e "s|\[JAHR\]|${YEAR_NOW}|g" \
      /bootstrap/pages/impressum.html > /tmp/impressum.html
  create_page "impressum" "Impressum" "/tmp/impressum.html" "true"

  DATE_NOW=$(date '+%d.%m.%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[DATUM\]|${DATE_NOW}|g" \
      /bootstrap/pages/datenschutz.html > /tmp/datenschutz.html
  create_page "datenschutz" "Datenschutzerklärung" "/tmp/datenschutz.html" "true"

  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/pages/presse.html > /tmp/presse.html
  create_page "presse" "Presse" "/tmp/presse.html" "true"

  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      /bootstrap/pages/beispielseite.html > /tmp/beispielseite.html
  create_page "beispielseite" "Beispielseite" "/tmp/beispielseite.html" "true"

  # 8) Posts anlegen (JWT)
  create_post "beispiel-post" "Beispiel-Blogpost" "/bootstrap/posts/beispiel-post.html" '[]' \
    "https://images.unsplash.com/photo-1599045118108-bf9954418b76?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&q=80&w=2000"

  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/posts/beispiel-pressemitteilung.html > /tmp/beispiel-pressemitteilung.html
  create_post "beispiel-pressemitteilung" "Beispiel-Pressemitteilung" "/tmp/beispiel-pressemitteilung.html" \
    '[{"name":"#pressemitteilung"}]'

  log "Bootstrap erfolgreich abgeschlossen."
}

main
