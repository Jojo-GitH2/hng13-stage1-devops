#!/bin/sh 

set -eu

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOGFILE="deploy_${TIMESTAMP}.log"

# Exit codes
E_INVALID_INPUT=2
E_GIT_FAIL=3
E_SSH_FAIL=4
E_REMOTE_FAIL=5
E_TRANSFER_FAIL=6
E_DEPLOY_FAIL=7
E_CLEANUP_FAIL=8

# Functions
log() {
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOGFILE"
}

prompt() {
  printf '%s: ' "$1" >&2
  IFS= read -r ans || ans=''
  # remove CR (Windows) and trim leading/trailing whitespace
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

  # remove CR (Windows) and trim leading/trailing whitespace
  secret="$(printf '%s' "$secret" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$secret"
}

# validators
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

# set -x
# Collect parameters
if [ "$CLEANUP_ONLY" -eq 0 ]; then
  printf '=== Collecting deployment parameters ===\n' | tee -a "$LOGFILE"

  REPO_URL="$(prompt 'Git repository HTTPS URL (e.g. https://github.com/owner/repo.git)')"

  # set +x
  if [ -z "$REPO_URL" ] || ! is_https_url "$REPO_URL"; then
    printf 'Invalid or missing HTTPS repository URL\n' | tee -a "$LOGFILE"
    exit $E_INVALID_INPUT
  fi

  # set -x
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

  # Masked log entry (do NOT write actual PAT)
  log "Collected params: repo=${REPO_URL}, branch=${BRANCH}, remote=${REMOTE_USER}@${REMOTE_HOST}, ssh_key=${SSH_KEY}, port=${APP_PORT}, app_name=${APP_NAME}"
  printf 'Parameters collected and validated — proceeding\n' | tee -a "$LOGFILE"
else
  # Cleanup-only mode: request minimal data
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
  printf 'Cleanup parameters collected\n' | tee -a "$LOGFILE"
fi

