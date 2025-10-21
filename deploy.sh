#!/bin/sh 

set -eu

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOGFILE="deploy_${TIMESTAMP}.log"

# Error codes
E_INVALID_INPUT=2


# Functions
log() {
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOGFILE"
}

prompt() {
  # $1 = prompt message
  printf '%s: ' "$1" >&2
  IFS= read -r ans || ans=''
  # remove CR (Windows) and trim leading/trailing whitespace
  ans="$(printf '%s' "$ans" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$ans"
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

fi

