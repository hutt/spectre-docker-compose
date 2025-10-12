#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Ghost Bootstrap Script – robust, idempotent & compatible with v6.x
# ============================================================================

BASE_URL="https://${DOMAIN}"
UA="Ghost-Bootstrap/1.0"
KEYS_FILE="/bootstrap/generated.keys.env"
ROUTES_FILE="/bootstrap/routes.yaml"

log() {
    printf '%s %s\n' "$(date +'%F %T')" "$*" >&2
}

# ----------------------------------------------------------------------------
# Step 1: Check if initial setup is needed
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
# Step 2: Initial setup (create owner account)
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
        log "Setup failed (HTTP $code)"; exit 1
    fi
    
    echo "$resp" | sed -n '/^{/,/^}/p' > /tmp/setup-response.json
    log "Setup successful."
}

# ----------------------------------------------------------------------------
# Generate JWT token from admin API key
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
# JWT-protected admin API calls
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
# One-time: Create integration via session + CSRF to get API key
# ----------------------------------------------------------------------------
create_integration_via_session() {
    log "Creating integration via admin session (one-time)..."
    local cookie hdr csrf payload resp
    
    cookie=$(mktemp -t ghost-cookie.XXXXXX)
    hdr=$(mktemp -t ghost-hdr.XXXXXX)
    
    # Create admin session (new endpoint for Ghost 6.x)
    curl -sS -D "$hdr" -c "$cookie" -b "$cookie" \
        -H "Content-Type: application/json" \
        -H "Accept-Version: v6" \
        -H "User-Agent: ${UA}" \
        -X POST \
        -d "$(jq -nc --arg u "$GHOST_SETUP_EMAIL" --arg p "$GHOST_SETUP_PASSWORD" \
            '{username:$u,password:$p}')" \
        "${BASE_URL}/ghost/api/admin/authentication/session/" >/dev/null
    
    # Extract CSRF token from response headers
    curl -sS -D "$hdr" -c "$cookie" -b "$cookie" \
        -H "Accept-Version: v6" \
        -H "User-Agent: ${UA}" \
        "${BASE_URL}/ghost/api/admin/site/" >/dev/null
    
    csrf=$(awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2);print $2}' "$hdr" | head -n1)
    if [ -z "$csrf" ]; then
        log "CSRF token not received"; exit 1
    fi
    
    payload='{"integrations":[{"name":"Bootstrap Integration"}]}'
    resp=$(curl -sS -D "$hdr" -c "$cookie" -b "$cookie" \
        -H "Content-Type: application/json" \
        -H "Accept-Version: v6" \
        -H "User-Agent: ${UA}" \
        -H "Origin: ${BASE_URL}" \
        -H "X-CSRF-Token: ${csrf}" \
        -X POST -d "$payload" \
        "${BASE_URL}/ghost/api/admin/integrations/")
    
    # Return: JSON with admin_api_key and content_api_key
    echo "$resp" | jq -r \
        '.integrations[0]|{admin_api_key:(.api_keys[]|select(.type=="admin")|.secret),content_api_key:(.api_keys[]|select(.type=="content")|.secret)}'
    
    rm -f "$cookie" "$hdr"
}

# ----------------------------------------------------------------------------  
# Via JWT: Check/create integration
# ----------------------------------------------------------------------------
create_or_get_integration() {
    log "Checking/creating integration (JWT)..."
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
# Persist and load API keys
# ----------------------------------------------------------------------------
persist_keys() {
    local admin content
    admin=$(echo "$1" | jq -r '.admin_api_key')
    content=$(echo "$1" | jq -r '.content_api_key')
    
    mkdir -p "$(dirname "$KEYS_FILE")"
    printf 'GHOST_ADMIN_API_KEY=%s\nGHOST_CONTENT_API_KEY=%s\n' "$admin" "$content" > "$KEYS_FILE"
    log "Keys saved to $KEYS_FILE"
}

load_keys() {
    if [ -f "$KEYS_FILE" ]; then
        # shellcheck disable=SC1090
        . "$KEYS_FILE"
        if [ -n "${GHOST_ADMIN_API_KEY:-}" ]; then
            generate_jwt "$GHOST_ADMIN_API_KEY"
            log "JWT generated from saved keys."
            return 0
        fi
    fi
    return 1
}

# ----------------------------------------------------------------------------
# Check if theme is already installed and active
# ----------------------------------------------------------------------------
check_theme_status() {
    local themes active_theme
    themes=$(api_jwt GET /themes/)
    active_theme=$(echo "$themes" | jq -r '.themes[] | select(.active == true) | .name')
    
    if [ "$active_theme" = "spectre" ]; then
        log "Spectre theme already active"
        return 0
    else
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Upload and activate theme via multipart form upload
# ----------------------------------------------------------------------------
upload_activate_theme() {
    log "Downloading Spectre theme..."
    if ! curl -fsSL "$SPECTRE_ZIP_URL" -o /tmp/spectre.zip; then
        log "Failed to download theme"; exit 1
    fi
    
    log "Uploading & activating theme..."
    local theme_resp theme_name
    
    # Upload theme using multipart form data
    theme_resp=$(curl -sS \
        -H "Authorization: Ghost ${JWT_TOKEN}" \
        -H "Accept-Version: v6" \
        -H "User-Agent: ${UA}" \
        -F "file=@/tmp/spectre.zip" \
        "${BASE_URL}/ghost/api/admin/themes/upload/")
    
    theme_name=$(echo "$theme_resp" | jq -r '.themes[0].name')
    if [ -z "$theme_name" ] || [ "$theme_name" = "null" ]; then
        log "Theme upload failed"; exit 1
    fi
    
    # Activate the uploaded theme
    api_jwt PUT "/themes/$theme_name/activate/" '{}' >/dev/null
    log "Theme $theme_name activated successfully"
    
    rm -f /tmp/spectre.zip
}

# ----------------------------------------------------------------------------
# Import routes via file upload (requires session authentication)
# ----------------------------------------------------------------------------
import_routes() {
    if [ ! -f "$ROUTES_FILE" ]; then
        log "Routes file not found: $ROUTES_FILE"
        return
    fi
    
    log "Importing routes..."
    local cookie hdr csrf
    
    cookie=$(mktemp -t ghost-cookie.XXXXXX)
    hdr=$(mktemp -t ghost-hdr.XXXXXX)
    
    # Create admin session
    curl -sS -D "$hdr" -c "$cookie" -b "$cookie" \
        -H "Content-Type: application/json" \
        -H "Accept-Version: v6" \
        -H "User-Agent: ${UA}" \
        -X POST \
        -d "$(jq -nc --arg u "$GHOST_SETUP_EMAIL" --arg p "$GHOST_SETUP_PASSWORD" \
            '{username:$u,password:$p}')" \
        "${BASE_URL}/ghost/api/admin/authentication/session/" >/dev/null
    
    # Get CSRF token
    curl -sS -D "$hdr" -c "$cookie" -b "$cookie" \
        -H "Accept-Version: v6" \
        -H "User-Agent: ${UA}" \
        "${BASE_URL}/ghost/api/admin/site/" >/dev/null
    
    csrf=$(awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2);print $2}' "$hdr" | head -n1)
    
    if [ -n "$csrf" ]; then
        curl -sS -c "$cookie" -b "$cookie" \
            -H "Accept-Version: v6" \
            -H "User-Agent: ${UA}" \
            -H "Origin: ${BASE_URL}" \
            -H "X-CSRF-Token: ${csrf}" \
            -F "routes=@${ROUTES_FILE}" \
            "${BASE_URL}/ghost/api/admin/settings/routes/yaml/" >/dev/null
        log "Routes imported successfully"
    else
        log "Could not get CSRF token for routes import"
    fi
    
    rm -f "$cookie" "$hdr"
}

# ----------------------------------------------------------------------------
# Set navigation via settings API
# ----------------------------------------------------------------------------
set_navigation() {
    log "Setting navigation..."
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

# ----------------------------------------------------------------------------
# Create pages from HTML templates
# ----------------------------------------------------------------------------
create_pages() {
    log "Creating pages..."
    
    for page in start impressum datenschutz presse beispielseite; do
        local title html body existing_page
        
        case "$page" in
            start) title="Start";;
            impressum) title="Impressum";;
            datenschutz) title="Datenschutzerklärung";;
            presse) title="Presse";;
            beispielseite) title="Beispielseite";;
        esac
        
        html="/bootstrap/pages/${page}.html"
        if [ ! -f "$html" ]; then
            log "Page template not found: $html"
            continue
        fi
        
        # Check if page already exists
        existing_page=$(api_jwt GET "/pages/slug/${page}/" 2>/dev/null || echo '{}')
        if echo "$existing_page" | jq -e '.pages[0].id' >/dev/null; then
            log "Page $page already exists, skipping"
            continue
        fi
        
        body=$(jq -nr \
            --arg t "$title" \
            --arg s "$page" \
            --arg h "$(cat "$html" | sed ':a;N;$!ba;s/\n/\\n/g; s/"/\\"/g')" \
            --arg e "$GHOST_SETUP_EMAIL" \
            '{pages:[{title:$t,slug:$s,status:"published",html:$h,authors:[{email:$e}]}]}')
        
        if api_jwt POST /pages/ "$body" >/dev/null; then
            log "Created page: $title"
        else
            log "Failed to create page: $title"
        fi
    done
}

# ----------------------------------------------------------------------------
# Create example posts from HTML templates
# ----------------------------------------------------------------------------
create_posts() {
    log "Creating example posts..."
    
    # Example blog post
    local post_html="/bootstrap/posts/beispiel-post.html"
    if [ -f "$post_html" ]; then
        # Check if post already exists
        local existing_post=$(api_jwt GET "/posts/slug/beispiel-post/" 2>/dev/null || echo '{}')
        if ! echo "$existing_post" | jq -e '.posts[0].id' >/dev/null; then
            local post_body=$(jq -nr \
                --arg h "$(cat "$post_html" | sed ':a;N;$!ba;s/\n/\\n/g; s/"/\\"/g')" \
                --arg e "$GHOST_SETUP_EMAIL" \
                '{posts:[{title:"Beispiel-Blogpost",slug:"beispiel-post",status:"published",html:$h,authors:[{email:$e}],tags:[]}]}')
            
            if api_jwt POST /posts/ "$post_body" >/dev/null; then
                log "Created post: Beispiel-Blogpost"
            else
                log "Failed to create post: Beispiel-Blogpost"
            fi
        else
            log "Post 'Beispiel-Blogpost' already exists, skipping"
        fi
    fi
    
    # Example press release
    local press_html="/bootstrap/posts/beispiel-pressemitteilung.html"
    if [ -f "$press_html" ]; then
        # Check if post already exists
        local existing_press=$(api_jwt GET "/posts/slug/beispiel-pressemitteilung/" 2>/dev/null || echo '{}')
        if ! echo "$existing_press" | jq -e '.posts[0].id' >/dev/null; then
            local press_body=$(jq -nr \
                --arg h "$(cat "$press_html" | sed ':a;N;$!ba;s/\n/\\n/g; s/"/\\"/g')" \
                --arg e "$GHOST_SETUP_EMAIL" \
                '{posts:[{title:"Beispiel-Pressemitteilung",slug:"beispiel-pressemitteilung",status:"published",html:$h,authors:[{email:$e}],tags:[{name:"#pressemitteilung"}]}]}')
            
            if api_jwt POST /posts/ "$press_body" >/dev/null; then
                log "Created post: Beispiel-Pressemitteilung"
            else
                log "Failed to create post: Beispiel-Pressemitteilung"
            fi
        else
            log "Post 'Beispiel-Pressemitteilung' already exists, skipping"
        fi
    fi
}

# ----------------------------------------------------------------------------
# Content bootstrap: Theme, Routes, Navigation, Pages, Posts
# ----------------------------------------------------------------------------
bootstrap_content() {
    # Check if theme is already active
    if ! check_theme_status; then
        upload_activate_theme
    fi
    
    import_routes
    set_navigation
    create_pages
    create_posts
    
    log "Content bootstrap completed."
}

# ============================================================================
# Main execution
# ============================================================================
main() {
    log "=== Starting Ghost Bootstrap ==="
    
    # 1) Perform setup if needed
    if [ "$(setup_needed)" = "yes" ]; then
        do_setup
    else
        log "Initial setup already completed."
    fi
    
    # 2) Initialize JWT: Load keys or create integration one-time
    if ! load_keys; then
        local keys_json
        keys_json=$(create_integration_via_session)
        persist_keys "$keys_json"
        GHOST_ADMIN_API_KEY=$(echo "$keys_json" | jq -r '.admin_api_key')
        generate_jwt "$GHOST_ADMIN_API_KEY"
    fi
    
    # 3) Supplement integration via JWT, refresh keys
    local integ_json
    integ_json=$(create_or_get_integration)
    persist_keys "$integ_json"
    
    # 4) Content bootstrap
    bootstrap_content
    
    log "=== Ghost Bootstrap Completed Successfully ==="
}

main
