#!/bin/sh 

set -eu

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
# Place log file outside the repo so it won't be copied into the app directory
LOGFILE="/tmp/deploy_${TIMESTAMP}.log"
DEFAULT_BRANCH="main"


# exit codes
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
    # call on_error without a reliable lineno (POSIX sh doesn't provide an ERR trap)
    on_error '?'
  else
    log "Deploy completed (exit 0)"
  fi
}

# POSIX /bin/sh: trap ERR is not supported. Trap EXIT only.
trap on_exit EXIT

# prompt() {
#   # $1 = prompt message
#   printf '%s: ' "$1"
#   read ans
#   printf '%s' "$ans"
# }

prompt() {
  # $1 = prompt message
  printf '%s: ' "$1" >&2
  IFS= read -r ans || ans=''
  # remove CR (Windows) and trim leading/trailing whitespace
  ans="$(printf '%s' "$ans" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$ans"
}

# prompt_hidden() {
#   printf '%s: ' "$1"
#   # Try to disable echo (most /bin/sh implementations support stty)
#   if stty -echo 2>/dev/null; then
#     read secret
#     stty echo
#     printf '\n'
#     printf '%s' "$secret"
#   else
#     printf '\n'
#     printf 'Warning: cannot hide input on this terminal; input will be visible\n' >>"$LOGFILE"
#     read secret
#     printf '%s' "$secret"
#   fi
# }

prompt_hidden() {
  # $1 = prompt message
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

  # remove CR (Windows) and trim leading/trailing whitespace
  secret="$(printf '%s' "$secret" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$secret"
}

# Basic validators
# is_https_url() {
#   case "$1" in
#     https://*) return 0 ;;
#     *) return 1 ;;
#   esac
# }
is_https_url() {
  case "$1" in
    https://*/*)
      # reject whitespace
      case "$1" in
        *[[:space:]]*) return 1 ;;
      esac
      # require a hostname containing a dot (e.g. github.com) and at least one path segment
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
  if [ -f "$1" ]; then
    return 0
  fi
  return 1
}

# Check for optional --cleanup mode as first arg
CLEANUP_ONLY=0
if [ "${1:-}" = "--cleanup" ]; then
  CLEANUP_ONLY=1
fi


# Collect parameters - Step 1
if [ "$CLEANUP_ONLY" -eq 0 ]; then
  printf '=== Collecting deployment parameters ===\n' | tee -a "$LOGFILE"

  REPO_URL="$(prompt 'Git repository HTTPS URL (e.g. https://github.com/owner/repo.git)')"

  # set +x
  if [ -z "$REPO_URL" ] || ! is_https_url "$REPO_URL"; then
    printf 'Invalid or missing HTTPS repository URL\n' | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  GIT_PAT="$(prompt_hidden 'Personal Access Token (PAT) - will be hidden if possible')"
  if [ -z "$GIT_PAT" ]; then
    printf 'PAT is required\n' | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  # set +x

  BRANCH="$(prompt 'Branch (default: main)')"
  if [ -z "$BRANCH" ]; then
    BRANCH="main"
  fi

  REMOTE_USER="$(prompt 'Remote SSH username')"
  if [ -z "$REMOTE_USER" ]; then
    printf 'Remote SSH username is required\n' | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  # Use a no-sudo directory under the remote user's home so sudo is not required
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

  # # Backend API URL required by the frontend (VITE_API_URL)
  # BACKEND_URL="$(prompt 'Backend API URL (VITE_API_URL) e.g. http://backend-host:5063/api')"
  # if [ -z "$BACKEND_URL" ]; then
  #   printf 'Backend API URL is required\n' | tee -a "$LOGFILE"
  #   exit $E_INVALID_INPUT
  # fi

  # Detect container port from Dockerfile if possible (EXPOSE), default to 80
  CONTAINER_PORT=""
  if [ -f "./Dockerfile" ]; then
    CONTAINER_PORT="$(sed -n 's/^[[:space:]]*EXPOSE[[:space:]]\+\([0-9]\+\).*/\1/ip' ./Dockerfile | head -n1 || true)"
  fi
  if [ -z "$CONTAINER_PORT" ]; then
    CONTAINER_PORT=80
  fi

  # # Ask which host port to publish (host -> container). Default to 80 for typical frontends.
  # HOST_PORT="$(prompt "Host port to expose (host -> container ${CONTAINER_PORT}) (default 8080)")"
  # if [ -z "$HOST_PORT" ]; then
  #   HOST_PORT=8080
  # fi
  # if ! is_numeric "$HOST_PORT"; then
  #   printf 'Host port must be numeric\n' | tee -a "$LOGFILE"
  #   exit $E_INVALID_INPUT
  # fi

  # Masked log entry (do NOT write actual PAT)
  log "Collected params: repo=${REPO_URL}, branch=${BRANCH}, remote=${REMOTE_USER}@${REMOTE_HOST}, ssh_key=${SSH_KEY}, port=${APP_PORT}, app_name=${APP_NAME}"
  printf 'Parameters collected and validated — proceeding\n' | tee -a "$LOGFILE"

  # Clone or Update repository locally - Step 2
  printf '=== Cloning or updating repository ===\n' | tee -a "$LOGFILE"
  LOCAL_BASE_DIR="/tmp/${APP_NAME}_deploy"

  # # Remove previous working dir if exists
  # if [ -d "$LOCAL_BASE_DIR" ]; then
  #   printf 'Previous work directory found — cleaning up...\n' | tee -a "$LOGFILE"
  #   rm -rf "$LOCAL_BASE_DIR" || {
  #     printf 'Failed to remove old working directory\n' | tee -a "$LOGFILE"
  #     exit $E_CLEANUP_FAIL
  #   }
  # fi

# GIT_CLONE_URL="$(printf '%s' "$REPO_URL" | sed "s#https://#https://${GIT_PAT}@#")"
# git clone --branch "$BRANCH" "$GIT_CLONE_URL" "$LOCAL_BASE_DIR" >>"$LOGFILE" 2>&1 || {
#   printf 'Git clone failed\n' | tee -a "$LOGFILE"
#   exit $E_GIT_FAIL
# }
# printf 'Repository cloned/updated successfully\n' | tee -a "$LOGFILE"

  # Mask PAT in logs for security
  SAFE_REPO_URL="$(printf '%s' "$REPO_URL" | sed 's#https://#https://<TOKEN>@#')"


  # Clone or pull repository
  log "Cloning repository: ${REPO_URL} (branch: ${BRANCH})"
  printf 'Cloning repository... this may take a while.\n' | tee -a "$LOGFILE"

  # Construct the HTTPS URL with embedded token for Git
  AUTH_REPO_URL=$(printf '%s' "$REPO_URL" | sed "s#https://#https://${GIT_PAT}@#")

  # If a repo already exists, update it
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
    # No existing repo — attempt a clone
    if GIT_TERMINAL_PROMPT=0 git clone --branch "$BRANCH" "$AUTH_REPO_URL" "$LOCAL_BASE_DIR" >>"$LOGFILE" 2>&1; then
      printf 'Repository cloned successfully\n' | tee -a "$LOGFILE"
    else
      printf 'Failed to clone repository\n' | tee -a "$LOGFILE"
      exit $E_GIT_FAIL
    fi
  fi

  printf 'Repository ready at: %s\n' "$LOCAL_BASE_DIR" | tee -a "$LOGFILE"

  # === Step 3: Navigate into cloned directory and verify Docker setup ===
  printf '=== Verifying cloned repository contents ===\n' | tee -a "$LOGFILE"

  # Ensure local base directory exists
  if [ ! -d "$LOCAL_BASE_DIR" ]; then
    printf 'Error: Local directory not found: %s\n' "$LOCAL_BASE_DIR" | tee -a "$LOGFILE"
    exit $E_GIT_FAIL
  fi

  # Ensure it's a git work tree
  if ! git -C "$LOCAL_BASE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'Error: %s does not appear to be a git repository\n' "$LOCAL_BASE_DIR" | tee -a "$LOGFILE"
    exit $E_GIT_FAIL
  fi

  # Change into the repo base dir
  cd "$LOCAL_BASE_DIR" || {
    printf 'Error: Failed to enter directory %s\n' "$LOCAL_BASE_DIR" | tee -a "$LOGFILE"
    exit $E_GIT_FAIL
  }

  log "Entered repository directory: $(pwd)"

  # Look for Dockerfile or docker-compose in repo root or one level deep.
  # Prefer root; otherwise pick the first matching subdirectory.
  DOCKER_PATH="$(find . -maxdepth 1 -type f \( -iname Dockerfile -o -iname docker-compose.yml -o -iname docker-compose.yaml \) -print -quit || true)"

  if [ -z "$DOCKER_PATH" ]; then
    # search one level deep
    DOCKER_PATH="$(find . -maxdepth 2 -type f \( -iname Dockerfile -o -iname docker-compose.yml -o -iname docker-compose.yaml \) -print -quit || true)"
  fi

  if [ -n "$DOCKER_PATH" ]; then
    # normalize and cd to the directory containing the docker file if not root
    DOCKER_DIR="$(dirname "$DOCKER_PATH")"
    # strip leading "./" if present
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
    # Provide debugging info to help diagnose why nothing was found
    printf 'Error: No Dockerfile or docker-compose.yml found in %s (checked root and one level deep)\n' "$(pwd)" | tee -a "$LOGFILE"
    printf 'Top-level files/directories:\n' | tee -a "$LOGFILE"
    ls -la . | tee -a "$LOGFILE"
    printf 'You may need to specify the correct subdirectory or update the repository layout.\n' | tee -a "$LOGFILE"
    exit $E_GIT_FAIL
  fi

  printf 'Repository verified successfully and ready for deployment.\n' | tee -a "$LOGFILE"

    # === Step 4: Transfer files to remote server ===
  printf '=== Transferring files to remote server ===\n' | tee -a "$LOGFILE"

  REMOTE_BASE_DIR="${REMOTE_BASE_DIR%/}"  # remove trailing slash if any
  REMOTE_APP_DIR="${REMOTE_BASE_DIR}/${APP_NAME}"
  NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}.conf"

  # === SSH connectivity dry-run ===
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

  # Create remote directory structure
  printf 'Ensuring remote directory exists...\n' | tee -a "$LOGFILE"
  if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p \"${REMOTE_APP_DIR}\" && chmod 755 \"${REMOTE_APP_DIR}\""; then
    printf 'Failed to prepare remote directory\n' | tee -a "$LOGFILE"
    exit $E_REMOTE_FAIL
  fi

  # === Step 5: Prepare remote environment (Docker + nginx) ===
  printf 'Checking/Installing Docker, docker-compose and nginx on remote host (requires passwordless sudo)...\n' | tee -a "$LOGFILE"

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<'EOF' >>"$LOGFILE" 2>&1
set -e

# Install Docker if not present
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker..."
  if command -v apt-get >/dev/null 2>&1; then

    # for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove $pkg; done

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

# Ensure Docker service running
sudo systemctl enable docker
sudo systemctl start docker

sudo usermod -aG docker $USER
newgrp docker


# Install nginx if not present
if ! command -v nginx >/dev/null 2>&1; then
  echo "Installing nginx..."
  sudo apt-get install -y nginx
  sudo systemctl enable nginx
  sudo systemctl start nginx
fi
EOF

  printf 'Remote environment prepared successfully.\n' | tee -a "$LOGFILE"

  # === Step 6: Transfer files via rsync or scp ===
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
  # Create remote dir, upload a temporary script and run it detached under nohup so ssh does not block.
  # POSIX-safe: use /bin/sh on remote, avoid bash-only features locally.
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" <<EOF
  set -e
  cd "${REMOTE_BASE_DIR}/${APP_NAME}"

  # Build Docker image
  docker build -t "${APP_NAME}:latest" .

  echo "Removing existing container: ${APP_NAME}"
  sudo docker rm -f "${APP_NAME}" || true


  # Run new container
  docker run -d -p ${APP_PORT}:${CONTAINER_PORT} --name "${APP_NAME}" "${APP_NAME}:latest"
EOF

  printf 'Application deployed successfully on remote host.\n' | tee -a "$LOGFILE"

# Create remote Nginx configuration dynamically
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" sh <<EOF
set -e
sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

NGINX_CONF="/etc/nginx/sites-available/$APP_NAME.conf"

# Create or overwrite the Nginx config
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

# Enable site and reload Nginx
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
  # Cleanup-only mode: request minimal data and perform remote cleanup
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

  # Run cleanup commands on the remote host. Expand local variables into the heredoc so the remote side receives concrete names.
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<EOF >>"$LOGFILE" 2>&1
set -e

APP_NAME="${APP_NAME}"
REMOTE_APP_DIR="${REMOTE_APP_DIR}"
NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/${APP_NAME}.conf"

echo "Cleaning up application: \$APP_NAME"

# Stop and remove container (if present)
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

# Remove deployed application files
if [ -d "\$REMOTE_APP_DIR" ]; then
  # prefer non-sudo removal for user-owned dirs, fallback to sudo if that fails
  rm -rf "\$REMOTE_APP_DIR" || ( sudo rm -rf "\$REMOTE_APP_DIR" || true )
  echo "Removed application directory: \$REMOTE_APP_DIR"
else
  echo "Application directory not found: \$REMOTE_APP_DIR"
fi

# Remove Nginx site config and reload if possible
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