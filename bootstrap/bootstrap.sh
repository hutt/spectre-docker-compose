#!/usr/bin/env bash
set -euo pipefail

# Basis-URL für interne Service-Kommunikation (Traefik umgehen)
BASE_URL="http://ghost:2368"
COOKIE="$(mktemp)"
ROUTES_FILE="/bootstrap/routes.yaml"
GENERATED_KEYS_FILE="/bootstrap/generated.keys.env"
UA="Mozilla/5.0 (compatible; Ghost-Bootstrap/1.0)"

log() { printf '%s %s\n' "$(date +'%F %T')" "$*" >&2; }

# ---- Hilfsfunktionen ---------------------------------------------------------

wait_for_ghost() {
  log "Warte auf Ghost unter ${BASE_URL} ..."
  for i in $(seq 1 120); do
    if curl -sf -c "$COOKIE" -b "$COOKIE" \
         -H "Accept: application/json" -H "User-Agent: $UA" \
         "${BASE_URL}/ghost/api/admin/site/" >/dev/null; then
      log "Ghost erreichbar."
      return 0
    fi
    sleep 2
  done
  log "Ghost wurde nicht rechtzeitig erreichbar."
  exit 1
}

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

do_setup() {
  log "Führe Initial-Setup durch ..."
  # Setup braucht KEINEN CSRF-Token!
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Content-Type: application/json" \
    -H "Origin: ${BASE_URL}" \
    -H "User-Agent: $UA" \
    -X POST \
    -d "$(jq -n --arg n "$GHOST_SETUP_NAME" \
                 --arg e "$GHOST_SETUP_EMAIL" \
                 --arg p "$GHOST_SETUP_PASSWORD" \
                 --arg t "$GHOST_SETUP_BLOG_TITLE" \
          '{setup:[{name:$n,email:$e,password:$p,blogTitle:$t}]}')" \
    "${BASE_URL}/ghost/api/admin/authentication/setup/" >/dev/null
  log "Setup abgeschlossen."
}

get_csrf() {
  log "Hole CSRF-Token ..."
  local headers token
  headers="$(mktemp)"

  curl -s -D "$headers" -o /dev/null \
       -c "$COOKIE" -b "$COOKIE" \
       -H "Accept: application/json" \
       -H "User-Agent: $UA" \
       "${BASE_URL}/ghost/api/admin/site/"

  token="$(awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2);print $2}' "$headers" || true)"

  if [ -z "${token:-}" ]; then
    log "Kein CSRF-Token im Header gefunden."
    exit 1
  fi

  echo "$token"
}

create_or_get_integration() {
  local csrf="$1" name="${2:-Bootstrap Integration}"
  
  # Bestehende Integrationen lesen
  local existing id
  existing=$(curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Accept: application/json" \
    -H "X-CSRF-Token: ${csrf}" \
    -H "Origin: ${BASE_URL}" \
    -H "User-Agent: $UA" \
    "${BASE_URL}/ghost/api/admin/integrations/?limit=all" || true)

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

  log "Erstelle Integration '$name' …"
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
      name, id,
      admin_api_key: (.api_keys[]? | select(.type=="admin") | .secret),
      content_api_key: (.api_keys[]? | select(.type=="content") | .secret)
    }'
}

download_theme() {
  local url="${SPECTRE_ZIP_URL:-}"
  [ -z "$url" ] && { log "SPECTRE_ZIP_URL ist leer."; exit 1; }
  log "Lade Theme: ${url}"
  curl -fsSL "$url" -o /tmp/spectre.zip
}

# Integration anlegen (oder vorhandene holen) und Admin-/Content-Keys extrahieren
create_or_get_integration() {
  local csrf="$1" name="${2:-Bootstrap Integration}"

  # Bestehende Integrationen lesen
  local existing id
  existing=$(curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Accept: application/json" \
    -H "User-Agent: $UA" \
    "${BASE_URL}/ghost/api/admin/integrations/?limit=all" || true)

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

  log "Erstelle Integration '$name' …"
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
      name, id,
      admin_api_key: (.api_keys[]? | select(.type=="admin") | .secret),
      content_api_key: (.api_keys[]? | select(.type=="content") | .secret)
    }'
}

# JWT-Token aus Admin API Key generieren
generate_jwt_token() {
  local api_key="$1"
  local id secret
  IFS=':' read -r id secret <<< "$api_key"
  
  local now exp header payload signature
  now=$(date +%s)
  exp=$((now + 300))  # 5 Minuten
  
  header=$(echo -n '{"alg":"HS256","typ":"JWT","kid":"'$id'"}' | base64 | tr -d '=' | tr '+' '-' | tr '/' '_')
  payload=$(echo -n '{"iat":'$now',"exp":'$exp',"aud":"/admin/"}' | base64 | tr -d '=' | tr '+' '-' | tr '/' '_')
  
  signature=$(echo -n "${header}.${payload}" | openssl dgst -binary -sha256 -mac HMAC -macopt hexkey:"$secret" | base64 | tr -d '=' | tr '+' '-' | tr '/' '_')
  
  echo "${header}.${payload}.${signature}"
}

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

# Wrapper für Admin-API-Aufruf mit API-Key (bevorzugt) oder Cookie+CSRF
# Nutzung: api_with_auth "<METHOD>" "<PATH>" "<JSON_BODY|empty>" "<CSRF|empty>" "<IS_MULTIPART:true|false>"
api_with_auth() {
  local method="$1" path="$2" body="${3:-}" csrf="${4:-}" is_multipart="${5:-false}"
  local url="${BASE_URL}${path}"

  if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
    # Auth via Admin API Key
    if [ "$is_multipart" = "true" ]; then
      # body muss bereits aus -F Parametern bestehen; hier übernehmen wir nur Header
      curl -s \
        -H "Authorization: Ghost ${GHOST_ADMIN_API_KEY}" \
        -H "User-Agent: $UA" \
        -X "$method" \
        $body \
        "$url"
    else
      curl -s \
        -H "Authorization: Ghost ${GHOST_ADMIN_API_KEY}" \
        -H "Content-Type: application/json" \
        -H "User-Agent: $UA" \
        -X "$method" \
        ${body:+-d "$body"} \
        "$url"
    fi
  else
    # Fallback: Cookie + CSRF (nur direkt nach Setup verlässlich)
    if [ "$is_multipart" = "true" ]; then
      curl -s -c "$COOKIE" -b "$COOKIE" \
        -H "Origin: ${BASE_URL}" \
        -H "X-CSRF-Token: ${csrf}" \
        -H "User-Agent: $UA" \
        -X "$method" \
        $body \
        "$url"
    else
      curl -s -c "$COOKIE" -b "$COOKIE" \
        -H "Content-Type: application/json" \
        -H "Origin: ${BASE_URL}" \
        -H "X-CSRF-Token: ${csrf}" \
        -H "User-Agent: $UA" \
        -X "$method" \
        ${body:+-d "$body"} \
        "$url"
    fi
  fi
}

upload_theme() {
  local csrf="$1"
  log "Lade Theme zu Ghost hoch ..."
  local resp
  if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
    # Mit Admin-Key, multipart
    resp=$(api_with_auth "POST" "/ghost/api/admin/themes/upload/" \
           "-F file=@/tmp/spectre.zip" "" "true")
  else
    # Mit Cookie+CSRF, multipart
    resp=$(api_with_auth "POST" "/ghost/api/admin/themes/upload/" \
           "-F file=@/tmp/spectre.zip" "$csrf" "true")
  fi

  echo "$resp" | tee /tmp/theme-upload.json >/dev/null
  if ! jq -e '.themes and .themes[0].name' /tmp/theme-upload.json >/dev/null 2>&1; then
    log "Theme-Upload fehlgeschlagen. Antwort:"
    cat /tmp/theme-upload.json >&2 || true
    exit 1
  fi
  jq -r '.themes[0].name' /tmp/theme-upload.json
}

activate_theme() {
  local csrf="$1" name="$2"
  log "Aktiviere Theme: ${name}"
  if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
    api_with_auth "PUT" "/ghost/api/admin/themes/${name}/activate/" "" "" "false" >/dev/null
  else
    api_with_auth "PUT" "/ghost/api/admin/themes/${name}/activate/" "" "$csrf" "false" >/dev/null
  fi
}

upload_routes() {
  local csrf="$1"
  [ -f "$ROUTES_FILE" ] || { log "routes.yaml nicht gefunden unter ${ROUTES_FILE}"; return 0; }
  log "Importiere routes.yaml ..."
  if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
    api_with_auth "PUT" "/ghost/api/admin/settings/routes/yaml" \
      "-F file=@${ROUTES_FILE};type=text/yaml" "" "true" >/dev/null
  else
    api_with_auth "PUT" "/ghost/api/admin/settings/routes/yaml" \
      "-F file=@${ROUTES_FILE};type=text/yaml" "$csrf" "true" >/dev/null
  fi
}

resource_exists() {
  local type="$1" slug="$2"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Accept: application/json" \
    -H "User-Agent: $UA" \
    -H "Authorization: Ghost ${GHOST_ADMIN_API_KEY:-}" \
    "${BASE_URL}/ghost/api/admin/${type}/slug/${slug}/?formats=html")
  [ "$code" = "200" ]
}

create_page() {
  local csrf="$1" slug="$2" title="$3" file="$4" show_title_and_feature_image="${5:-true}"
  if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
    # Nutzung der Admin-Key-Auth -> resource_exists funktioniert wie oben
    :
  else
    # Fallback-Existenzcheck ohne Key (Cookie/CSRF). Wenn nicht möglich, überspringen wir den Check.
    :
  fi

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

  if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
    api_with_auth "POST" "/ghost/api/admin/pages/" "$jq_data" "" "false" >/dev/null
  else
    api_with_auth "POST" "/ghost/api/admin/pages/" "$jq_data" "$csrf" "false" >/dev/null
  fi
}

create_post() {
  local csrf="$1" slug="$2" title="$3" file="$4" tags_json="$5" feature_image="${6:-}"
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

  if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
    api_with_auth "POST" "/ghost/api/admin/posts/" "$jq_data" "" "false" >/dev/null
  else
    api_with_auth "POST" "/ghost/api/admin/posts/" "$jq_data" "$csrf" "false" >/dev/null
  fi
}

update_navigation() {
  local csrf="$1"
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

  if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
    api_with_auth "PUT" "/ghost/api/admin/settings/?source=html" "$body" "" "false" >/dev/null
  else
    api_with_auth "PUT" "/ghost/api/admin/settings/?source=html" "$body" "$csrf" "false" >/dev/null
  fi
}

# ---- Hauptablauf ----------------------------------------------------------------

main() {
  wait_for_ghost

  if [ "$(setup_needed)" = "yes" ]; then
    # Setup OHNE CSRF
    do_setup

    # Nach Setup: CSRF holen für Integration-Erstellung
    csrf="$(get_csrf)"

    # Integration anlegen
    keys_json="$(create_or_get_integration "$csrf" "Bootstrap Integration")"
    
    # Admin-Key extrahieren und JWT generieren
    ADMIN_KEY=$(echo "$keys_json" | jq -r '.admin_api_key')
    export GHOST_ADMIN_API_KEY="$ADMIN_KEY"
    
    log "Verwende Admin API Key für weitere Requests."
  else
    log "Setup bereits durchgeführt."
    # Versuche gespeicherte Keys zu laden oder exit
    if [ ! -f "$GENERATED_KEYS_FILE" ]; then
      log "Kein Setup nötig, aber keine API Keys gefunden."
      exit 1
    fi
    source "$GENERATED_KEYS_FILE"
    export GHOST_ADMIN_API_KEY="${GHOST_ADMIN_API_KEY}"
  fi

  # Ab hier alle API-Calls mit JWT-Token
  JWT_TOKEN="$(generate_jwt_token "$GHOST_ADMIN_API_KEY")"

  # Download und Upload Theme mit JWT
  download_theme
  theme_name="$(upload_theme_with_jwt "$JWT_TOKEN")"
  [ -n "$theme_name" ] && activate_theme_with_jwt "$JWT_TOKEN" "$theme_name"

  upload_routes "${csrf:-}"
  update_navigation "${csrf:-}"

  # Seiten
  sed -e "s|\[BLOGTITLE\]|${GHOST_SETUP_BLOG_TITLE}|g" \
      /bootstrap/pages/start.html > /tmp/start.html
  create_page "${csrf:-}" "start" "Start" "/tmp/start.html" "false"

  YEAR_NOW=$(date '+%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      -e "s|\[DOMAIN\]|${DOMAIN}|g" \
      -e "s|\[JAHR\]|${YEAR_NOW}|g" \
      /bootstrap/pages/impressum.html > /tmp/impressum.html
  create_page "${csrf:-}" "impressum" "Impressum" "/tmp/impressum.html" "true"

  DATE_NOW=$(date '+%d.%m.%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[DATUM\]|${DATE_NOW}|g" \
      /bootstrap/pages/datenschutz.html > /tmp/datenschutz.html
  create_page "${csrf:-}" "datenschutz" "Datenschutzerklärung" "/tmp/datenschutz.html" "true"

  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/pages/presse.html > /tmp/presse.html
  create_page "${csrf:-}" "presse" "Presse" "/tmp/presse.html" "true"

  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      /bootstrap/pages/beispielseite.html > /tmp/beispielseite.html
  create_page "${csrf:-}" "beispielseite" "Beispielseite" "/tmp/beispielseite.html" "true"

  # Blogposts
  create_post "${csrf:-}" "beispiel-post" "Beispiel-Blogpost" "/bootstrap/posts/beispiel-post.html" '[]' \
    "https://images.unsplash.com/photo-1599045118108-bf9954418b76?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3wxMTc3M3wwfDF8c2VhcmNofDE3fHxob3NwaXRhbHxlbnwwfHx8fDE3NjAxMDM0MzV8MA&ixlib=rb-4.1.0&q=80&w=2000"

  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/posts/beispiel-pressemitteilung.html > /tmp/beispiel-pressemitteilung.html
  create_post "${csrf:-}" "beispiel-pressemitteilung" "Beispiel-Pressemitteilung" "/tmp/beispiel-pressemitteilung.html" \
    '[{"name":"#pressemitteilung"}]'

  log "Bootstrap erfolgreich abgeschlossen."
}

main
