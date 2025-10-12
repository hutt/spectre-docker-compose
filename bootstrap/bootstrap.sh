#!/usr/bin/env bash
set -euo pipefail

BASE_URL="http://ghost:2368"
COOKIE="$(mktemp)"
ROUTES_FILE="/bootstrap/routes.yaml"

# Hilfsfunktionen
wait_for_ghost() {
  echo "Warte auf Ghost unter ${BASE_URL} ..."
  for i in $(seq 1 120); do
    if curl -sf "${BASE_URL}/ghost/api/admin/site/" >/dev/null; then
      echo "Ghost erreichbar."
      return 0
    fi
    sleep 2
  done
  echo "Ghost wurde nicht rechtzeitig erreichbar." >&2
  exit 1
}

get_csrf() {
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Accept: application/json" \
    "${BASE_URL}/ghost/api/admin/csrf-token/" \
  | jq -r '.csrf'
}

setup_needed() {
  # Wenn Setup-Endpoint 404 liefert, ist Ghost bereits eingerichtet.
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIE" -b "$COOKIE" \
    -H "Accept: application/json" \
    "${BASE_URL}/ghost/api/admin/authentication/setup/")
  if [ "$code" = "404" ]; then
    echo "no"
  else
    echo "yes"
  fi
}

do_setup() {
  local csrf="$1"
  echo "Führe Initial-Setup durch ..."
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Content-Type: application/json" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -X POST \
    -d "$(jq -n --arg n "$GHOST_SETUP_NAME" \
                 --arg e "$GHOST_SETUP_EMAIL" \
                 --arg p "$GHOST_SETUP_PASSWORD" \
                 --arg t "$GHOST_SETUP_BLOG_TITLE" \
          '{setup:[{name:$n,email:$e,password:$p,blogTitle:$t}]}')" \
    "${BASE_URL}/ghost/api/admin/authentication/setup/" >/dev/null
  echo "Setup abgeschlossen."
}

download_theme() {
  local url="${SPECTRE_ZIP_URL:-}"
  [ -z "$url" ] && { echo "SPECTRE_ZIP_URL ist leer." >&2; exit 1; }
  echo "Lade Theme: ${url}"
  curl -fsSL "$url" -o /tmp/spectre.zip
}

upload_theme() {
  local csrf="$1"
  echo "Lade Theme zu Ghost hoch ..."
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -F "file=@/tmp/spectre.zip" \
    "${BASE_URL}/ghost/api/admin/themes/upload/" \
  | tee /tmp/theme-upload.json >/dev/null
  jq -r '.themes[0].name' /tmp/theme-upload.json
}

activate_theme() {
  local csrf="$1"
  local name="$2"
  echo "Aktiviere Theme: ${name}"
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -X PUT \
    "${BASE_URL}/ghost/api/admin/themes/${name}/activate/" >/dev/null
}

upload_routes() {
  local csrf="$1"
  [ -f "$ROUTES_FILE" ] || { echo "routes.yaml nicht gefunden unter ${ROUTES_FILE}" >&2; return 0; }
  echo "Importiere routes.yaml ..."
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
    -F "file=@${ROUTES_FILE};type=text/yaml" \
    -X PUT \
    "${BASE_URL}/ghost/api/admin/settings/routes/yaml" >/dev/null
}

update_navigation() {
  local csrf="$1"
  echo "Aktualisiere Haupt- und sekundäre Navigation …"
  curl -s -c "$COOKIE" -b "$COOKIE" \
    -H "Content-Type: application/json" \
    -H "Origin: ${BASE_URL}" \
    -H "X-CSRF-Token: ${csrf}" \
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
    "${BASE_URL}/ghost/api/admin/settings/?source=html"
}

resource_exists() {
  local type="$1" # posts|pages
  local slug="$2"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIE" -b "$COOKIE" \
    -H "Accept: application/json" \
    "${BASE_URL}/ghost/api/admin/${type}/slug/${slug}/?formats=html")
  [ "$code" = "200" ]
}

create_page() {
  local csrf="$1" slug="$2" title="$3" file="$4" show_title_and_feature_image="$5"
  if resource_exists "pages" "$slug"; then
    echo "Seite '$slug' existiert bereits, überspringe."
    return
  fi
  local html
  html="$(< "$file")"
  echo "Erstelle Seite '$slug' …"
  
  # JSON mit optionale Einstellung für show_title_and_feature_image
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
    -X POST \
    -d "$jq_data" \
    "${BASE_URL}/ghost/api/admin/pages/" >/dev/null
}

create_post() {
  local csrf="$1" slug="$2" title="$3" file="$4" tags_json="$5" feature_image="${6:-}"
  if resource_exists "posts" "$slug"; then
    echo "Post '$slug' existiert bereits, überspringe."
    return
  fi
  local html
  html="$(< "$file")"
  echo "Erstelle Post '$slug' …"
  
  # JSON mit feature_image wenn gesetzt
  if [ -n "$feature_image" ]; then
    curl -s -c "$COOKIE" -b "$COOKIE" \
      -H "Content-Type: application/json" \
      -H "Origin: ${BASE_URL}" \
      -H "X-CSRF-Token: ${csrf}" \
      -X POST \
      -d "$(jq -n \
            --arg title "$title" \
            --arg slug  "$slug" \
            --arg html  "$html" \
            --arg author "$GHOST_SETUP_EMAIL" \
            --arg json_tags "$tags_json" \
            --arg feature_image "$feature_image" \
            '{posts:[{title:$title,slug:$slug,status:"published",html:$html,feature_image:$feature_image,authors:[{email:$author}],tags:( $json_tags | fromjson )}]}')" \
      "${BASE_URL}/ghost/api/admin/posts/" >/dev/null
  else
    curl -s -c "$COOKIE" -b "$COOKIE" \
      -H "Content-Type: application/json" \
      -H "Origin: ${BASE_URL}" \
      -H "X-CSRF-Token: ${csrf}" \
      -X POST \
      -d "$(jq -n \
            --arg title "$title" \
            --arg slug  "$slug" \
            --arg html  "$html" \
            --arg author "$GHOST_SETUP_EMAIL" \
            --arg json_tags "$tags_json" \
            '{posts:[{title:$title,slug:$slug,status:"published",html:$html,authors:[{email:$author}],tags:( $json_tags | fromjson )}]}')" \
      "${BASE_URL}/ghost/api/admin/posts/" >/dev/null
  fi
}

main() {
  wait_for_ghost

  # Ersteinrichtung
  local csrf
  csrf="$(get_csrf)"
  if [ "$(setup_needed)" = "yes" ]; then
    do_setup "$csrf"
    # neue Session/CSRF holen
    csrf="$(get_csrf)"
  else
    echo "Setup bereits erledigt."
  fi

  download_theme
  theme_name="$(upload_theme "$csrf")"
  [ -n "$theme_name" ] && activate_theme "$csrf" "$theme_name"

  upload_routes "$csrf"

  update_navigation "$csrf"

  # Seiten
  ## Start
  sed -e "s|\[BLOGTITLE\]|${GHOST_SETUP_BLOG_TITLE}|g" \
      /bootstrap/pages/start.html > /tmp/start.html
  create_page "$csrf" "start" "Start" "/tmp/start.html" "false"

  ## Impressum
  export YEAR_NOW=$(date '+%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      -e "s|\[DOMAIN\]|${DOMAIN}|g" \
      -e "s|\[JAHR\]|${YEAR_NOW}|g" \
      /bootstrap/pages/impressum.html > /tmp/impressum.html
  create_page "$csrf" "impressum" "Impressum" "/tmp/impressum.html" "true"

  ## Datenschutz
  export DATE_NOW=$(date '+%d.%m.%Y')
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      -e "s|\[DATUM\]|${DATE_NOW}|g" \
      /bootstrap/pages/datenschutz.html > /tmp/datenschutz.html
  create_page "$csrf" "datenschutz" "Datenschutzerklärung" "/tmp/datenschutz.html" "true"

  ## Presse
  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/pages/presse.html > /tmp/presse.html
  create_page "$csrf" "presse" "Presse" "/tmp/presse.html" "true"

  ## Beispielseite
  sed -e "s|\[Vorname Nachname\]|${GHOST_SETUP_NAME}|g" \
      /bootstrap/pages/beispielseite.html > /tmp/beispielseite.html
  create_page "$csrf" "beispielseite" "Beispielseite" "/tmp/beispielseite.html" "true"

  # Blogposts
  ## Beispiel-Post
  create_post "$csrf" "beispiel-post"              "Beispiel-Blogpost"          "/bootstrap/posts/beispiel-post.html"              '[]'                             "https://images.unsplash.com/photo-1599045118108-bf9954418b76?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3wxMTc3M3wwfDF8c2VhcmNofDE3fHxob3NwaXRhbHxlbnwwfHx8fDE3NjAxMDM0MzV8MA&ixlib=rb-4.1.0&q=80&w=2000"
  
  ## Beispiel-Pressemitteilung
  sed -e "s|\[EMAIL\]|${GHOST_SETUP_EMAIL}|g" \
      /bootstrap/posts/beispiel-pressemitteilung.html > /tmp/beispiel-pressemitteilung.html
  create_post "$csrf" "beispiel-pressemitteilung"  "Beispiel-Pressemitteilung"  "/tmp/beispiel-pressemitteilung.html"  '[{"name":"#pressemitteilung"}]' null

  echo "Bootstrap erfolgreich abgeschlossen."
}

main
