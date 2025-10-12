#!/usr/bin/env bash
set -euo pipefail

# Basis-URL für interne Service-Kommunikation (Traefik umgehen)
BASE_URL="${GHOST_ADMIN_URL:-http://ghost:2368}"

COOKIE="$(mktemp)"
ROUTES_FILE="/bootstrap/routes.yaml"
UA="Mozilla/5.0 (compatible; Ghost-Bootstrap/1.0)"

log() { printf '%s %s\n' "$(date +'%F %T')" "$*" >&2; }

# ---- Hilfsfunktionen ---------------------------------------------------------

wait_for_ghost() {
  log "Warte auf Ghost unter ${BASE_URL} ..."
  for i in $(seq 1 120); do
    if curl -sf -c "$COOKIE" -b "$COOKIE" -H "Accept: application/json" -H "User-Agent: $UA" \
         "${BASE_URL}/ghost/api/admin/site/" >/dev/null; then
      log "Ghost erreichbar."
      return 0
    fi
    sleep 2
  done
  log "Ghost wurde nicht rechtzeitig erreichbar."
  exit 1
}

# Session-Login mit E-Mail/Passwort (Ghost 6+)
login_session() {
  log "Melde Session an ..."
  # Erst einmal /site aufrufen, einige Setups wollen das vorab
  curl -s -o /dev/null -w "%{http_code}" \
       -c "$COOKIE" -b "$COOKIE" \
       -H "Accept: application/json" -H "User-Agent: $UA" \
       "${BASE_URL}/ghost/api/admin/site/" >/dev/null || true

  # Session erstellen
  local code body
  body=$(jq -n --arg e "$GHOST_SETUP_EMAIL" --arg p "$GHOST_SETUP_PASSWORD" '{username:$e,password:$p}')
  code=$(curl -s -o /tmp/login.json -w "%{http_code}" \
              -c "$COOKIE" -b "$COOKIE" \
              -H "Content-Type: application/json" \
              -H "Origin: ${BASE_URL}" \
              -H "User-Agent: $UA" \
              -X POST \
              -d "$body" \
              "${BASE_URL}/ghost/api/admin/session/")
  if [ "$code" != "201" ] && [ "$code" != "204" ]; then
    log "Session-Login fehlgeschlagen (HTTP $code). Antwort:"
    cat /tmp/login.json >&2 || true
    exit 1
  fi
  log "Session erstellt."
}

# CSRF-Token aus Header beziehen
get_csrf() {
  log "Hole CSRF-Token ..."
  # Der CSRF-Token kommt bei Ghost über den Response-Header "X-CSRF-Token"
  # Wir triggern eine einfache GET-Anfrage, um den Header zu erhalten
  local headers
  headers=$(mktemp)
  curl -s -D "$headers" -o /dev/null \
       -c "$COOKIE" -b "$COOKIE" \
       -H "Accept: application/json" \
       -H "User-Agent: $UA" \
       "${BASE_URL}/ghost/api/admin/site/"
  local token
  token=$(awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2);print $2}' "$headers" || true)
  if [ -z "${token:-}" ]; then
    # Fallback: versuche denselben Request noch einmal gegen /users/me
    curl -s -D "$headers" -o /dev/null \
         -c "$COOKIE" -b "$COOKIE" \
         -H "Accept: application/json" \
         -H "User-Agent: $UA" \
         "${BASE_URL}/ghost/api/admin/users/me/"
    token=$(awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2);print $2}' "$headers" || true)
  fi
  if [ -z "${token:-}" ]; then
    log "Kein CSRF-Token im Header gefunden."
    exit 1
  fi
  echo "$token"
}

setup_needed() {
  # Wenn Setup-Endpoint 404 liefert, ist Ghost bereits eingerichtet.
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
  local csrf="$1"
  log "Führe Initial-Setup durch ..."
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Content-Type: application/json" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
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

download_theme() {
  local url="${SPECTRE_ZIP_URL:-}"
  [ -z "$url" ] && { log "SPECTRE_ZIP_URL ist leer."; exit 1; }
  log "Lade Theme: ${url}"
  curl -fsSL "$url" -o /tmp/spectre.zip
}

upload_theme() {
  local csrf="$1"
  log "Lade Theme zu Ghost hoch ..."
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -H "User-Agent: $UA" \
    -F "file=@/tmp/spectre.zip" \
    "${BASE_URL}/ghost/api/admin/themes/upload/" \
  | tee /tmp/theme-upload.json >/dev/null

  if ! jq -e '.themes and .themes[0].name' /tmp/theme-upload.json >/dev/null 2>&1; then
    log "Theme-Upload fehlgeschlagen. Antwort:"
    cat /tmp/theme-upload.json >&2 || true
    exit 1
  fi
  jq -r '.themes[0].name' /tmp/theme-upload.json
}

activate_theme() {
  local csrf="$1"
  local name="$2"
  log "Aktiviere Theme: ${name}"
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -H "User-Agent: $UA" \
    -X PUT \
    "${BASE_URL}/ghost/api/admin/themes/${name}/activate/" >/dev/null
}

upload_routes() {
  local csrf="$1"
  [ -f "$ROUTES_FILE" ] || { log "routes.yaml nicht gefunden unter ${ROUTES_FILE}"; return 0; }
  log "Importiere routes.yaml ..."
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -H "User-Agent: $UA" \
    -F "file=@${ROUTES_FILE};type=text/yaml" \
    -X PUT \
    "${BASE_URL}/ghost/api/admin/settings/routes/yaml" >/dev/null
}

resource_exists() {
  local type="$1" # posts|pages
  local slug="$2"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIE" -b "$COOKIE" \
    -H "Accept: application/json" -H "User-Agent: $UA" \
    "${BASE_URL}/ghost/api/admin/${type}/slug/${slug}/?formats=html")
  [ "$code" = "200" ]
}

create_page() {
  local csrf="$1" slug="$2" title="$3" file="$4" show_title_and_feature_image="${5:-true}"
  if resource_exists "pages" "$slug"; then
    log "Seite '$slug' existiert bereits, überspringe."
    return
  fi
  local html
  html="$(< "$file")"
  log "Erstelle Seite '$slug' …"

  local jq_data
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

  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Content-Type: application/json" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -H "User-Agent: $UA" \
    -X POST \
    -d "$jq_data" \
    "${BASE_URL}/ghost/api/admin/pages/" >/dev/null
}

create_post() {
  local csrf="$1" slug="$2" title="$3" file="$4" tags_json="$5" feature_image="${6:-}"
  if resource_exists "posts" "$slug"; then
    log "Post '$slug' existiert bereits, überspringe."
    return
  fi
  local html
  html="$(< "$file")"
  log "Erstelle Post '$slug' …"

  local jq_data
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

  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Content-Type: application/json" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -H "User-Agent: $UA" \
    -X POST \
    -d "$jq_data" \
    "${BASE_URL}/ghost/api/admin/posts/" >/dev/null
}

update_navigation() {
  local csrf="$1"
  log "Aktualisiere Haupt- und sekundäre Navigation …"
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Content-Type: application/json" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -H "User-Agent: $UA" \
    -X PUT \
    -d '{
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
    }' \
    "${BASE_URL}/ghost/api/admin/settings/?source=html" >/dev/null
}

# ---- Hauptablauf ----------------------------------------------------------------

main() {
  wait_for_ghost

  # Falls Setup nötig: einmalige Einrichtung (Owner & Blogtitel)
  # Danach Session-Login (auch wenn Setup gerade stattfand – neue Session holen)
  if [ "$(setup_needed)" = "yes" ]; then
    # Für Setup brauchen wir zunächst eine Session + CSRF
    login_session
    csrf="$(get_csrf)"
    do_setup "$csrf"
  fi

  # Session neu sicherstellen und CSRF holen (frische Session)
  login_session
  csrf="$(get_csrf)"

  download_theme
  theme_name="$(upload_theme "$csrf")"
  [ -n "$theme_name" ] && activate_theme "$csrf" "$theme_name"

  upload_routes "$csrf"
  update_navigation "$csrf"

  # Seiten
  sed -e "s|\[BLOGTITLE\]|${GHOST_SETUP_BLOG_TITLE}|g" \
      /bootstrap/pages/start.html > /tmp/start.html
  create_page "$csrf" "start" "Start" "/tmp/start.html" "false"

  YEAR_NOW=$(date '+%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      -e "s|\[DOMAIN\]|${DOMAIN}|g" \
      -e "s|\[JAHR\]|${YEAR_NOW}|g" \
      /bootstrap/pages/impressum.html > /tmp/impressum.html
  create_page "$csrf" "impressum" "Impressum" "/tmp/impressum.html" "true"

  DATE_NOW=$(date '+%d.%m.%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[DATUM\]|${DATE_NOW}|g" \
      /bootstrap/pages/datenschutz.html > /tmp/datenschutz.html
  create_page "$csrf" "datenschutz" "Datenschutzerklärung" "/tmp/datenschutz.html" "true"

  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/pages/presse.html > /tmp/presse.html
  create_page "$csrf" "presse" "Presse" "/tmp/presse.html" "true"

  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      /bootstrap/pages/beispielseite.html > /tmp/beispielseite.html
  create_page "$csrf" "beispielseite" "Beispielseite" "/tmp/beispielseite.html" "true"

  # Blogposts
  create_post "$csrf" "beispiel-post" "Beispiel-Blogpost" "/bootstrap/posts/beispiel-post.html" '[]' \
    "https://images.unsplash.com/photo-1599045118108-bf9954418b76?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3wxMTc3M3wwfDF8c2VhcmNofDE3fHxob3NwaXRhbHxlbnwwfHx8fDE3NjAxMDM0MzV8MA&ixlib=rb-4.1.0&q=80&w=2000"

  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/posts/beispiel-pressemitteilung.html > /tmp/beispiel-pressemitteilung.html
  create_post "$csrf" "beispiel-pressemitteilung" "Beispiel-Pressemitteilung" "/tmp/beispiel-pressemitteilung.html" \
    '[{"name":"#pressemitteilung"}]'

  log "Bootstrap erfolgreich abgeschlossen."
}

main
