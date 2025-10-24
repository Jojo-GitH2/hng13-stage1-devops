#!/bin/sh

set -eu

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOGFILE="/tmp/deploy_${TIMESTAMP}.log"
DEFAULT_BRANCH="main"

E_INVALID_INPUT=2
E_GIT_FAIL=3
E_SSH_FAIL=4
E_REMOTE_FAIL=5
E_TRANSFER_FAIL=6
E_DEPLOY_FAIL=7
E_CLEANUP_FAIL=8

log() {
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOGFILE"
}

on_error() {
  lineno="${1:-?}"
  printf 'ERROR: line %s. See log %s\n' "$lineno" "$LOGFILE" | tee -a "$LOGFILE"
  log "Script failed at line ${lineno}"
}

on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'Deploy exited with error (code %d). See %s\n' "$rc" "$LOGFILE" | tee -a "$LOGFILE"
    on_error '?'
  else
    log "Deploy completed (exit 0)"
  fi
}

trap on_exit EXIT

prompt() {
  printf '%s: ' "$1" >&2
  IFS= read -r ans || ans=''
  ans="$(printf '%s' "$ans" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$ans"
}

prompt_hidden() {
  printf '%s: ' "$1" >&2
  if stty -echo 2>/dev/null; then
    IFS= read -r secret || secret=''
    stty echo
    printf '\n' >&2
  else
    printf '\n' >&2
    printf 'Warning: cannot hide input on this terminal; input will be visible\n' >&2
    IFS= read -r secret || secret=''
  fi
  secret="$(printf '%s' "$secret" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$secret"
}

is_https_url() {
  case "$1" in
    https://*/*)
      case "$1" in
        *[[:space:]]*) return 1 ;;
      esac
      case "$1" in
        https://*.*/*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

is_numeric() {
  case "$1" in
    ''|*[!0-9]* ) return 1 ;;
    *) return 0 ;;
  esac
}

file_exists() {
  [ -f "$1" ]
}

CLEANUP_ONLY=0
if [ "${1:-}" = "--cleanup" ]; then
  CLEANUP_ONLY=1
fi

if [ "$CLEANUP_ONLY" -eq 0 ]; then
  printf '=== Collecting deployment parameters ===\n' | tee -a "$LOGFILE"

  REPO_URL="$(prompt 'Git repository HTTPS URL (e.g. https://github.com/owner/repo.git)')"
  if [ -z "$REPO_URL" ] || ! is_https_url "$REPO_URL"; then
    printf 'Invalid or missing HTTPS repository URL\n' | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  GIT_PAT="$(prompt_hidden 'Personal Access Token (PAT) - will be hidden if possible')"
  if [ -z "$GIT_PAT" ]; then
    printf 'PAT is required\n' | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  BRANCH="$(prompt 'Branch (default: main)')"
  if [ -z "$BRANCH" ]; then
    BRANCH="$DEFAULT_BRANCH"
  fi

  REMOTE_USER="$(prompt 'Remote SSH username')"
  if [ -z "$REMOTE_USER" ]; then
    printf 'Remote SSH username is required\n' | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  REMOTE_BASE_DIR="/home/${REMOTE_USER}/"

  REMOTE_HOST="$(prompt 'Remote server IP or hostname')"
  if [ -z "$REMOTE_HOST" ]; then
    printf 'Remote host is required\n' | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  SSH_KEY="$(prompt 'SSH private key path (e.g. /home/user/.ssh/id_rsa)')"
  if [ -z "$SSH_KEY" ] || ! file_exists "$SSH_KEY"; then
    printf 'SSH key path missing or file does not exist: %s\n' "$SSH_KEY" | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  APP_PORT="$(prompt 'Application internal container port (numeric, e.g. 3000)')"
  if ! is_numeric "$APP_PORT"; then
    printf 'Application port must be numeric\n' | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  APP_NAME="$(prompt 'Application name (unique id, e.g. myapp)')"
  if [ -z "$APP_NAME" ]; then
    APP_NAME="app"
  fi

  CONTAINER_PORT=""
  if [ -f "./Dockerfile" ]; then
    CONTAINER_PORT="$(sed -n 's/^[[:space:]]*EXPOSE[[:space:]]\+\([0-9]\+\).*/\1/ip' ./Dockerfile | head -n1 || true)"
  fi
  if [ -z "$CONTAINER_PORT" ]; then
    CONTAINER_PORT=80
  fi

  log "Collected params: repo=${REPO_URL}, branch=${BRANCH}, remote=${REMOTE_USER}@${REMOTE_HOST}, ssh_key=${SSH_KEY}, port=${APP_PORT}, app_name=${APP_NAME}"
  printf 'Parameters collected and validated — proceeding\n' | tee -a "$LOGFILE"

  printf '=== Cloning or updating repository ===\n' | tee -a "$LOGFILE"
  LOCAL_BASE_DIR="/tmp/${APP_NAME}_deploy"
  SAFE_REPO_URL="$(printf '%s' "$REPO_URL" | sed 's#https://#https://<TOKEN>@#')"

  log "Cloning repository: ${REPO_URL} (branch: ${BRANCH})"
  printf 'Cloning repository... this may take a while.\n' | tee -a "$LOGFILE"

  AUTH_REPO_URL=$(printf '%s' "$REPO_URL" | sed "s#https://#https://${GIT_PAT}@#")

  if [ -d "$LOCAL_BASE_DIR/.git" ]; then
    printf 'Existing git repository found — updating...\n' | tee -a "$LOGFILE"
    (
      cd "$LOCAL_BASE_DIR" || exit $E_GIT_FAIL
      GIT_TERMINAL_PROMPT=0 git fetch --prune origin "$BRANCH" >>"$LOGFILE" 2>&1 &&
      GIT_TERMINAL_PROMPT=0 git checkout --force "$BRANCH" >>"$LOGFILE" 2>&1 &&
      GIT_TERMINAL_PROMPT=0 git reset --hard "origin/$BRANCH" >>"$LOGFILE" 2>&1
    ) || {
      printf 'Failed to update existing repository\n' | tee -a "$LOGFILE"
      exit $E_GIT_FAIL
    }
  else
    if GIT_TERMINAL_PROMPT=0 git clone --branch "$BRANCH" "$AUTH_REPO_URL" "$LOCAL_BASE_DIR" >>"$LOGFILE" 2>&1; then
      printf 'Repository cloned successfully\n' | tee -a "$LOGFILE"
    else
      printf 'Failed to clone repository\n' | tee -a "$LOGFILE"
      exit $E_GIT_FAIL
    fi
  fi

  printf 'Repository ready at: %s\n' "$LOCAL_BASE_DIR" | tee -a "$LOGFILE"

  printf '=== Verifying cloned repository contents ===\n' | tee -a "$LOGFILE"

  if [ ! -d "$LOCAL_BASE_DIR" ]; then
    printf 'Error: Local directory not found: %s\n' "$LOCAL_BASE_DIR" | tee -a "$LOGFILE"
    exit $E_GIT_FAIL
  fi

  if ! git -C "$LOCAL_BASE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'Error: %s does not appear to be a git repository\n' "$LOCAL_BASE_DIR" | tee -a "$LOGFILE"
    exit $E_GIT_FAIL
  fi

  cd "$LOCAL_BASE_DIR" || {
    printf 'Error: Failed to enter directory %s\n' "$LOCAL_BASE_DIR" | tee -a "$LOGFILE"
    exit $E_GIT_FAIL
  }

  log "Entered repository directory: $(pwd)"

  DOCKER_PATH="$(find . -maxdepth 1 -type f \( -iname Dockerfile -o -iname docker-compose.yml -o -iname docker-compose.yaml \) -print -quit || true)"
  if [ -z "$DOCKER_PATH" ]; then
    DOCKER_PATH="$(find . -maxdepth 2 -type f \( -iname Dockerfile -o -iname docker-compose.yml -o -iname docker-compose.yaml \) -print -quit || true)"
  fi

  if [ -n "$DOCKER_PATH" ]; then
    DOCKER_DIR="$(dirname "$DOCKER_PATH")"
    DOCKER_DIR="${DOCKER_DIR#./}"
    if [ -n "$DOCKER_DIR" ] && [ "$DOCKER_DIR" != "." ]; then
      printf 'Docker-related files found in subdirectory: %s\n' "$DOCKER_DIR" | tee -a "$LOGFILE"
      cd "$DOCKER_DIR" || {
        printf 'Error: Failed to enter docker directory %s\n' "$DOCKER_DIR" | tee -a "$LOGFILE"
        exit $E_GIT_FAIL
      }
      log "Switched to docker context dir: $(pwd)"
    else
      printf 'Docker-related files found in repository root\n' | tee -a "$LOGFILE"
    fi
  else
    printf 'Error: No Dockerfile or docker-compose.yml found in %s (checked root and one level deep)\n' "$(pwd)" | tee -a "$LOGFILE"
    printf 'Top-level files/directories:\n' | tee -a "$LOGFILE"
    ls -la . | tee -a "$LOGFILE"
    printf 'You may need to specify the correct subdirectory or update the repository layout.\n' | tee -a "$LOGFILE"
    exit $E_GIT_FAIL
  fi

  printf 'Repository verified successfully and ready for deployment.\n' | tee -a "$LOGFILE"

  printf '=== Transferring files to remote server ===\n' | tee -a "$LOGFILE"

  REMOTE_BASE_DIR="${REMOTE_BASE_DIR%/}"
  REMOTE_APP_DIR="${REMOTE_BASE_DIR}/${APP_NAME}"
  NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}.conf"

  printf 'Checking SSH connectivity to %s@%s ...\n' "$REMOTE_USER" "$REMOTE_HOST" | tee -a "$LOGFILE"

  if command -v nc >/dev/null 2>&1; then
    if ! nc -z -w 3 "$REMOTE_HOST" 22 2>/dev/null; then
      printf 'Warning: cannot reach %s:22 (TCP). SSH may fail\n' "$REMOTE_HOST" | tee -a "$LOGFILE"
    fi
  fi

  if ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" 'echo SSH_OK' >/dev/null 2>&1; then
    printf 'SSH key auth ok (non-interactive)\n' | tee -a "$LOGFILE"
  else
    printf 'Non-interactive SSH auth failed — trying interactive SSH (may prompt)...\n' | tee -a "$LOGFILE"
    if ssh -o ConnectTimeout=10 -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" 'echo SSH_OK' >>"$LOGFILE" 2>&1; then
      printf 'Interactive SSH succeeded\n' | tee -a "$LOGFILE"
    else
      printf 'SSH connectivity test failed. Check key, user, host, and security groups\n' | tee -a "$LOGFILE"
      exit $E_SSH_FAIL
    fi
  fi

  printf 'Ensuring remote directory exists...\n' | tee -a "$LOGFILE"
  if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p \"${REMOTE_APP_DIR}\" && chmod 755 \"${REMOTE_APP_DIR}\""; then
    printf 'Failed to prepare remote directory\n' | tee -a "$LOGFILE"
    exit $E_REMOTE_FAIL
  fi

  printf 'Checking/Installing Docker, docker-compose and nginx on remote host (requires passwordless sudo)...\n' | tee -a "$LOGFILE"

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<'EOF' >>"$LOGFILE" 2>&1
set -e
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
fi
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER || true
newgrp docker || true
if ! command -v nginx >/dev/null 2>&1; then
  echo "Installing nginx..."
  sudo apt-get install -y nginx
  sudo systemctl enable nginx
  sudo systemctl start nginx
fi
EOF

  printf 'Remote environment prepared successfully.\n' | tee -a "$LOGFILE"

  printf 'Copying files to remote server...\n' | tee -a "$LOGFILE"
  if command -v rsync >/dev/null 2>&1; then
    rsync -az -e "ssh -i \"${SSH_KEY}\" -o StrictHostKeyChecking=no" "${LOCAL_BASE_DIR}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_DIR}/" >>"$LOGFILE" 2>&1 || {
      printf 'rsync failed\n' | tee -a "$LOGFILE"
      exit $E_TRANSFER_FAIL
    }
  else
    scp -i "$SSH_KEY" -r "${LOCAL_BASE_DIR}/"* "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_DIR}/" >>"$LOGFILE" 2>&1 || {
      printf 'scp failed\n' | tee -a "$LOGFILE"
      exit $E_TRANSFER_FAIL
    }
  fi

  printf 'Files transferred successfully.\n' | tee -a "$LOGFILE"
  log "Deployment files synced to remote: ${REMOTE_APP_DIR}"
  printf '=== Step 4–6 completed successfully ===\n' | tee -a "$LOGFILE"

  printf "=== Configuring Nginx as reverse proxy ===\n" | tee -a "$LOGFILE"
  printf '=== Deploying application on remote host and configuring nginx (detached) ===\n' | tee -a "$LOGFILE"

  set -x
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" <<EOF
  set -e
  cd "${REMOTE_BASE_DIR}/${APP_NAME}"
  docker build -t "${APP_NAME}:latest" .
  echo "Removing existing container: ${APP_NAME}"
  sudo docker rm -f "${APP_NAME}" || true
  docker run -d -p ${APP_PORT}:${CONTAINER_PORT} --name "${APP_NAME}" "${APP_NAME}:latest"
EOF

  printf 'Application deployed successfully on remote host.\n' | tee -a "$LOGFILE"

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" sh <<EOF
set -e
sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
NGINX_CONF="/etc/nginx/sites-available/$APP_NAME.conf"
sudo sh -c "cat > \$NGINX_CONF" <<'NGINX_EOF'
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_EOF
if [ ! -f "/etc/nginx/sites-enabled/$APP_NAME.conf" ]; then
    sudo ln -s "/etc/nginx/sites-available/$APP_NAME.conf" "/etc/nginx/sites-enabled/$APP_NAME.conf"
fi
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl enable nginx
sudo systemctl restart nginx
echo "Nginx reverse proxy configured for $APP_NAME on port 80 -> $APP_PORT"
EOF

  printf "Reverse proxy configuration completed successfully.\n" | tee -a "$LOGFILE"
  set +x

else
  printf '=== Cleanup mode: collect remote info ===\n' | tee -a "$LOGFILE"
  REMOTE_USER="$(prompt 'Remote SSH username')"
  REMOTE_HOST="$(prompt 'Remote server IP or hostname')"
  SSH_KEY="$(prompt 'SSH private key path (e.g. /home/user/.ssh/id_rsa)')"
  APP_NAME="$(prompt 'Application name to cleanup (e.g. myapp)')"

  if [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_HOST" ] || [ -z "$SSH_KEY" ] || [ -z "$APP_NAME" ]; then
    printf 'All values are required for cleanup\n' | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  if ! file_exists "$SSH_KEY"; then
    printf 'SSH key file not found: %s\n' "$SSH_KEY" | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  log "Collected cleanup params: remote=${REMOTE_USER}@${REMOTE_HOST}, ssh_key=${SSH_KEY}, app_name=${APP_NAME}"
  printf 'Cleanup parameters collected — proceeding\n' | tee -a "$LOGFILE"

  REMOTE_BASE_DIR="/home/${REMOTE_USER}"
  REMOTE_APP_DIR="${REMOTE_BASE_DIR%/}/${APP_NAME}"

  printf 'Starting remote cleanup on %s@%s ...\n' "$REMOTE_USER" "$REMOTE_HOST" | tee -a "$LOGFILE"

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<EOF >>"$LOGFILE" 2>&1
set -e
APP_NAME="${APP_NAME}"
REMOTE_APP_DIR="${REMOTE_APP_DIR}"
NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/${APP_NAME}.conf"
echo "Cleaning up application: \$APP_NAME"
if command -v docker >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    sudo docker rm -f "\$APP_NAME" >/dev/null 2>&1 || true
    sudo docker rmi -f "\$APP_NAME:latest" >/dev/null 2>&1 || true
  else
    docker rm -f "\$APP_NAME" >/dev/null 2>&1 || true
    docker rmi -f "\$APP_NAME:latest" >/dev/null 2>&1 || true
  fi
else
  echo "docker: not present on remote; skipping container/image removal"
fi
if [ -d "\$REMOTE_APP_DIR" ]; then
  rm -rf "\$REMOTE_APP_DIR" || ( sudo rm -rf "\$REMOTE_APP_DIR" || true )
  echo "Removed application directory: \$REMOTE_APP_DIR"
else
  echo "Application directory not found: \$REMOTE_APP_DIR"
fi
if [ -f "\$NGINX_CONF" ] || [ -L "\$NGINX_ENABLED" ]; then
  if sudo -n true 2>/dev/null; then
    sudo rm -f "\$NGINX_CONF" "\$NGINX_ENABLED" >/dev/null 2>&1 || true
    if sudo nginx -t >/dev/null 2>&1; then
      sudo systemctl reload nginx || sudo nginx -s reload || true
    else
      echo "nginx test failed after removing config; check remote /etc/nginx" >&2
    fi
  else
    rm -f "\$NGINX_CONF" "\$NGINX_ENABLED" >/dev/null 2>&1 || true
    echo "Warning: passwordless sudo not available; nginx may require manual reload on remote" >&2
    echo "Run on remote (if needed): sudo nginx -t && sudo systemctl reload nginx" >&2
  fi
  echo "Removed nginx site configuration for \$APP_NAME"
else
  echo "No nginx site config found for \$APP_NAME"
fi
echo "Cleanup finished for \$APP_NAME"
EOF

  if [ $? -ne 0 ]; then
    printf 'Remote cleanup encountered errors (see %s)\n' "$LOGFILE" | tee -a "$LOGFILE"
    exit $E_REMOTE_FAIL
  fi

  printf 'Remote cleanup completed. See log: %s\n' "$LOGFILE" | tee -a "$LOGFILE"
  log "Cleanup completed for ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_DIR}"
fi
