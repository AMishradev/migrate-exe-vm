#!/usr/bin/env bash
#
# migrate-exe-vm.sh
#
# Safely copy useful configuration from an existing exe.dev VM to a new one.
# Runs LOCALLY (not inside either VM). Uses SSH + rsync.
#
# Usage:
#   ~/Downloads/migrate-exe-vm.sh <new-vm-hostname>
#   ~/Downloads/migrate-exe-vm.sh --source tango-mountain.exe.xyz new-machine.exe.xyz
#
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Defaults / configuration
# ----------------------------------------------------------------------------
SSH_USER="exedev"
SOURCE_HOST="tango-mountain.exe.xyz"
DEST_HOST=""
DRY_RUN=0
VERBOSE=0
INCLUDE_SECRETS=1   # copy credentials by default; --exclude-secrets opts out
CREATE_VM=1         # create a fresh exe.dev VM first; --no-create to reuse one
EXE_SSH_HOST="exe.dev"   # control host for 'ssh exe.dev new'

# Extra args forwarded verbatim to 'ssh exe.dev new' (e.g. --cpu, --memory).
EXE_NEW_ARGS=()

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Paths (relative to the remote HOME) to copy when they exist.
CONFIG_PATHS=(
  ".bashrc"
  ".bash_aliases"
  ".blerc"
  ".inputrc"
  ".tmux.conf"
  ".local/bin/"
)

# Extra credential paths copied ONLY when --include-secrets is given.
# Note: .ssh/authorized_keys and known_hosts are excluded below so we never
# clobber the destination's login access.
SECRET_PATHS=(
  ".config/composio/env"
  ".ssh/"
  ".netrc"
)

# Files we run "bash -n" against on the destination for validation.
VALIDATE_FILES=(
  ".bashrc"
  ".bash_aliases"
  ".blerc"
)

# Packages to ensure on the destination.
REQUIRED_PKGS=(git make gawk tmux rsync)

# ble.sh install details.
BLESH_REPO="https://github.com/akinomyoga/ble.sh.git"
BLESH_DEST=".local/share/blesh"

# tmux scrollback. tmux has no true "infinite" buffer (history-limit is an
# integer), so we use a very large value for effectively-unlimited scrollback.
# This overrides tmux's default of 2000 lines on the destination.
TMUX_HISTORY_LIMIT=1000000000

# ----------------------------------------------------------------------------
# Summary accumulators
# ----------------------------------------------------------------------------
COPIED=()
SKIPPED=()
BACKUPS=()
PKGS_INSTALLED=()
BLESH_STATUS="not attempted"
VALIDATION_RESULTS=()

# ----------------------------------------------------------------------------
# Colors / logging
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'
  C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_BOLD=''
fi

log()   { printf '%s[*]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_OK"   "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
err()   { printf '%s[x]%s %s\n' "$C_ERR"  "$C_RESET" "$*" >&2; }
vlog()  { (( VERBOSE )) && printf '    %s\n' "$*" || true; }

# ----------------------------------------------------------------------------
# Temp dir + cleanup trap
# ----------------------------------------------------------------------------
TMPDIR_LOCAL=""
cleanup() {
  local rc=$?
  if [[ -n "$TMPDIR_LOCAL" && -d "$TMPDIR_LOCAL" ]]; then
    rm -rf -- "$TMPDIR_LOCAL"
    vlog "Removed temporary directory: $TMPDIR_LOCAL"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'err "Interrupted."; exit 130' INT TERM
trap 'err "Error on line $LINENO (exit $?)."' ERR

# ----------------------------------------------------------------------------
# Usage
# ----------------------------------------------------------------------------
usage() {
  cat <<EOF
${C_BOLD}migrate-exe-vm.sh${C_RESET} - copy config from one exe.dev VM to another.

Runs locally. Copies safe shell/tmux/ble.sh configuration from a source VM
to a new destination VM, backing up destination files first, installing
missing dependencies, and installing ble.sh.

${C_BOLD}Usage:${C_RESET}
  $0 [options] <new-vm-hostname>

${C_BOLD}Options:${C_RESET}
  --source HOST      Source VM hostname (default: ${SOURCE_HOST})
  --no-create        Do NOT create a VM; treat <name> as an existing host and
                     migrate config into it (the old behavior).
  --exe-new-arg ARG  Pass an extra argument through to 'ssh exe.dev new'
                     (repeatable), e.g. --exe-new-arg --cpu=4
  --dry-run          Show what would happen; make no changes; no confirmation.
  --verbose          Print extra detail.
  --exclude-secrets  Do NOT copy credentials. By default the script copies
                     ~/.config/composio/env, SSH identity keys (~/.ssh/,
                     minus authorized_keys and known_hosts), and ~/.netrc.
                     Use this flag to skip all of those.
  --include-secrets  Explicitly copy credentials (this is already the default).
  --help             Show this help.

${C_BOLD}Example:${C_RESET}
  $0 new-machine.exe.xyz
  $0 --source tango-mountain.exe.xyz --verbose new-machine.exe.xyz

${C_BOLD}Copies (when present):${C_RESET}
  ~/.bashrc  ~/.bash_aliases  ~/.blerc  ~/.inputrc  ~/.tmux.conf  ~/.local/bin/

${C_BOLD}Never copies:${C_RESET}
  SSH private keys, API keys, auth tokens, ~/.config/composio/env,
  shell history, caches, temp files, secret env files, ble.sh cache.
EOF
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || { err "--source requires an argument"; exit 2; }
      SOURCE_HOST="$2"; shift 2 ;;
    --source=*)
      SOURCE_HOST="${1#*=}"; shift ;;
    --no-create) CREATE_VM=0; shift ;;
    --create) CREATE_VM=1; shift ;;
    --exe-new-arg)
      [[ $# -ge 2 ]] || { err "--exe-new-arg requires an argument"; exit 2; }
      EXE_NEW_ARGS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --exclude-secrets) INCLUDE_SECRETS=0; shift ;;
    --include-secrets) INCLUDE_SECRETS=1; shift ;;   # explicit; also the default
    --help|-h) usage; exit 0 ;;
    --) shift; break ;;
    -*)
      err "Unknown option: $1"; usage; exit 2 ;;
    *)
      if [[ -z "$DEST_HOST" ]]; then
        DEST_HOST="$1"; shift
      else
        err "Unexpected argument: $1"; exit 2
      fi ;;
  esac
done

# Allow a positional after `--`
if [[ -z "$DEST_HOST" && $# -gt 0 ]]; then
  DEST_HOST="$1"; shift
fi

if [[ -z "$DEST_HOST" ]]; then
  err "Missing <new-vm-name>."
  usage
  exit 2
fi

SRC="${SSH_USER}@${SOURCE_HOST}"

# ----------------------------------------------------------------------------
# Local prerequisites
# ----------------------------------------------------------------------------
log "Checking local prerequisites..."
missing_local=()
local_tools=(ssh rsync mktemp)
(( CREATE_VM )) && local_tools+=(jq)   # needed to parse 'exe.dev new --json'
for tool in "${local_tools[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || missing_local+=("$tool")
done
if (( ${#missing_local[@]} )); then
  err "Missing required local tools: ${missing_local[*]}"
  exit 1
fi
ok "Local tools present: ${local_tools[*]}"

# ----------------------------------------------------------------------------
# SSH helpers
# ----------------------------------------------------------------------------
SSH_OPTS=(-o BatchMode=no -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

# ----------------------------------------------------------------------------
# Create the destination VM (unless --no-create)
# ----------------------------------------------------------------------------
# exe.dev auto-generates the real hostname from the requested name, so we parse
# it back out of the JSON response and use that for the migration below.
if (( CREATE_VM )); then
  # exe.dev VM names must be 5-52 chars, lowercase, digits, single hyphens.
  # Normalize what the user gave us so 'kms_proxy_vm' -> 'kms-proxy-vm'. Also
  # strip a trailing exe.dev domain so 'foo.exe.xyz' -> 'foo' (not 'foo-exe-xyz').
  vm_name="$(printf '%s' "$DEST_HOST" \
    | sed -E 's/\.(exe\.(xyz|dev))$//' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  if [[ "$vm_name" != "$DEST_HOST" ]]; then
    warn "Normalized VM name '${DEST_HOST}' -> '${vm_name}' (exe.dev naming rules)."
  fi

  if (( DRY_RUN )); then
    warn "[dry-run] Would create exe.dev VM '${vm_name}' via 'ssh ${EXE_SSH_HOST} new'."
    DEST_HOST="${vm_name}.exe.xyz"
  else
    log "Creating new exe.dev VM '${vm_name}'..."
    # Guard the array expansion: an empty array under 'set -u' is an error on
    # macOS's bash 3.2, so only splice EXE_NEW_ARGS in when it has elements.
    new_cmd=(ssh "${SSH_OPTS[@]}" "$EXE_SSH_HOST" new --name="$vm_name" --json)
    (( ${#EXE_NEW_ARGS[@]} )) && new_cmd+=("${EXE_NEW_ARGS[@]}")
    new_json="$("${new_cmd[@]}" 2>&1)" || {
        err "VM creation call failed:"; printf '%s\n' "$new_json" >&2; exit 1; }

    if printf '%s' "$new_json" | jq -e 'has("error")' >/dev/null 2>&1; then
      err "exe.dev rejected the request: $(printf '%s' "$new_json" | jq -r '.error')"
      exit 1
    fi

    DEST_HOST="$(printf '%s' "$new_json" | jq -r '.ssh_host // empty')"
    if [[ -z "$DEST_HOST" ]]; then
      err "Could not parse ssh_host from exe.dev response:"
      printf '%s\n' "$new_json" >&2
      exit 1
    fi
    ok "VM created: ${DEST_HOST}"

    # Poll until the new VM accepts SSH before we try to migrate into it.
    log "Waiting for ${DEST_HOST} to accept SSH..."
    ready=0
    for i in $(seq 1 30); do
      if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${DEST_HOST}" 'echo ok' >/dev/null 2>&1; then
        ready=1; break
      fi
      vlog "not ready yet (attempt $i)"; sleep 5
    done
    if (( ! ready )); then
      err "VM ${DEST_HOST} did not become SSH-reachable in time."
      exit 1
    fi
    ok "VM is reachable."
  fi
fi

DST="${SSH_USER}@${DEST_HOST}"

ssh_run() {
  # ssh_run <host> <remote-command...>
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" "$host" "$@"
}

check_host() {
  local host="$1"
  log "Verifying SSH connectivity to ${host}..."
  if ssh_run "$host" 'echo ok' >/dev/null 2>&1; then
    ok "Connected to ${host}"
  else
    err "Cannot connect to ${host} over SSH as ${SSH_USER}."
    exit 1
  fi
}

# rsync wrappers.
# RSYNC_FETCH: pulls source -> local temp dir. This never modifies a VM, so it
#   always runs for real (even in --dry-run) to build an accurate push plan.
# RSYNC_PUSH:  pushes local temp dir -> destination, honoring --dry-run.
RSYNC_FETCH=(rsync -a --human-readable -e "ssh ${SSH_OPTS[*]}")
(( VERBOSE )) && RSYNC_FETCH+=(-v)

RSYNC_PUSH=("${RSYNC_FETCH[@]}")
(( DRY_RUN )) && RSYNC_PUSH+=(--dry-run)

# Always-on exclusions: caches, history, temp/log/swap files. These are never
# useful to copy regardless of --include-secrets.
RSYNC_EXCLUDES=(
  --exclude='*_history'
  --exclude='.bash_history'
  --exclude='.zsh_history'
  --exclude='*.log'
  --exclude='*.tmp'
  --exclude='*.swp'
  --exclude='.cache/'
  --exclude='cache/'
  --exclude='*.cache'
  --exclude='blesh/cache/'
  --exclude='.blesh/cache/'
  --exclude='**/blesh/cache/'
  # Never overwrite the destination's login access or host trust, even when
  # copying SSH identity keys.
  --exclude='authorized_keys'
  --exclude='authorized_keys2'
  --exclude='known_hosts'
  --exclude='known_hosts.*'
)

if (( INCLUDE_SECRETS )); then
  # User opted in: pull credentials too, and add them to the copy list.
  CONFIG_PATHS+=("${SECRET_PATHS[@]}")
else
  # Default: hard-block secrets from ever being copied.
  RSYNC_EXCLUDES+=(
    --exclude='.ssh/'
    --exclude='id_rsa*'
    --exclude='id_ed25519*'
    --exclude='id_ecdsa*'
    --exclude='id_dsa*'
    --exclude='*.pem'
    --exclude='*.key'
    --exclude='*.p12'
    --exclude='*.pfx'
    --exclude='*.env'
    --exclude='.env'
    --exclude='.env.*'
    --exclude='*.token'
    --exclude='*token*'
    --exclude='*secret*'
    --exclude='.netrc'
    --exclude='.config/composio/env'
  )
fi

# ----------------------------------------------------------------------------
# Start
# ----------------------------------------------------------------------------
printf '\n%s=== exe.dev VM migration ===%s\n' "$C_BOLD" "$C_RESET"
log "Source:      ${SRC}"
log "Destination: ${DST}"
(( DRY_RUN )) && warn "DRY-RUN mode: no changes will be made."
if (( INCLUDE_SECRETS )); then
  warn "INCLUDE-SECRETS mode: credentials WILL be copied"
  warn "  (~/.config/composio/env, SSH identity keys, ~/.netrc)."
  warn "  authorized_keys and known_hosts are NOT copied (login-safety)."
fi
echo

check_host "$SRC"
if (( DRY_RUN && CREATE_VM )); then
  warn "[dry-run] Skipping destination connectivity check (VM not created)."
else
  check_host "$DST"
fi

# ----------------------------------------------------------------------------
# Confirmation (skip in dry-run)
# ----------------------------------------------------------------------------
if (( ! DRY_RUN )); then
  printf '%sThis will modify the destination VM %s%s (with backups).%s\n' \
    "$C_WARN" "$C_BOLD" "$DST" "$C_RESET"
  if (( INCLUDE_SECRETS )); then
    printf '%sSECRETS will be copied to %s. Only continue if you fully trust it.%s\n' \
      "$C_ERR" "$DST" "$C_RESET"
  fi
  read -r -p "Proceed? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) warn "Aborted by user."; exit 0 ;;
  esac
fi

# ----------------------------------------------------------------------------
# Secure local temp dir
# ----------------------------------------------------------------------------
TMPDIR_LOCAL="$(mktemp -d "${TMPDIR:-/tmp}/migrate-exe-vm.XXXXXX")"
chmod 700 "$TMPDIR_LOCAL"
vlog "Temporary directory: $TMPDIR_LOCAL"

# ----------------------------------------------------------------------------
# Step 1: Pull config from source into temp dir
# ----------------------------------------------------------------------------
log "Fetching configuration from source VM..."
for path in "${CONFIG_PATHS[@]}"; do
  # Check existence on source.
  if ssh_run "$SRC" "test -e \"\$HOME/$path\"" 2>/dev/null; then
    local_target="$TMPDIR_LOCAL/$path"
    mkdir -p "$(dirname "$local_target")"
    # Relative remote paths are resolved against the remote user's HOME.
    if "${RSYNC_FETCH[@]}" "${RSYNC_EXCLUDES[@]}" \
         "${SRC}:$path" "$local_target"; then
      COPIED+=("$path")
      vlog "Fetched: $path"
    else
      SKIPPED+=("$path (fetch failed)")
      warn "Failed to fetch $path"
    fi
  else
    SKIPPED+=("$path (absent on source)")
    vlog "Absent on source: $path"
  fi
done

if (( ${#COPIED[@]} == 0 )); then
  warn "Nothing was fetched from the source. Exiting."
  exit 0
fi

# ----------------------------------------------------------------------------
# Step 2: Backup destination files (that we are about to overwrite)
# ----------------------------------------------------------------------------
log "Creating timestamped backups on destination..."
for path in "${COPIED[@]}"; do
  # Only back up regular files (not the .local/bin/ dir wholesale).
  case "$path" in
    */) continue ;;  # directory paths handled per-file by rsync; skip dir backup
  esac
  if ssh_run "$DST" "test -f \"\$HOME/$path\"" 2>/dev/null; then
    backup="${path}.backup-${TIMESTAMP}"
    if (( DRY_RUN )); then
      vlog "[dry-run] Would back up ~/$path -> ~/$backup"
      BACKUPS+=("$backup (dry-run)")
    else
      ssh_run "$DST" "cp -p \"\$HOME/$path\" \"\$HOME/$backup\""
      BACKUPS+=("$backup")
      vlog "Backed up ~/$path -> ~/$backup"
    fi
  fi
done

# ----------------------------------------------------------------------------
# Step 3: Push config from temp dir to destination
# ----------------------------------------------------------------------------
log "Pushing configuration to destination VM..."
for path in "${COPIED[@]}"; do
  local_source="$TMPDIR_LOCAL/$path"
  # Ensure the remote parent directory exists (rsync won't create intermediate
  # dirs like ~/.config/composio on its own). For a trailing-slash dir path,
  # the target itself is the directory to create.
  if [[ "$path" == */ ]]; then
    remote_parent="${path%/}"
  else
    remote_parent="$(dirname "$path")"
  fi
  if [[ "$remote_parent" != "." ]]; then
    if (( DRY_RUN )); then
      vlog "[dry-run] Would ensure remote dir ~/$remote_parent"
    else
      ssh_run "$DST" "mkdir -p \"\$HOME/$remote_parent\""
    fi
  fi
  # For a directory path (trailing slash) rsync -a syncs contents (no --delete).
  # Relative remote paths are resolved against the remote user's HOME.
  "${RSYNC_PUSH[@]}" "${RSYNC_EXCLUDES[@]}" \
    "$local_source" "${DST}:$path"
  vlog "Pushed: $path"
done

# ----------------------------------------------------------------------------
# Step 3b: Configure tmux scrollback + mouse on destination
# ----------------------------------------------------------------------------
# tmux defaults to history-limit 2000. Force a huge value in the destination's
# ~/.tmux.conf so scrollback is effectively infinite, and enable mouse mode so
# the wheel/trackpad scrolls into that buffer. Any pre-existing history-limit
# or mouse lines are replaced so they can't override us.
log "Configuring tmux scrollback (history-limit=${TMUX_HISTORY_LIMIT}) + mouse on..."
if (( DRY_RUN )); then
  vlog "[dry-run] Would set 'set -g history-limit ${TMUX_HISTORY_LIMIT}' and 'set -g mouse on' in ~/.tmux.conf"
else
  if ssh_run "$DST" "
    set -e
    conf=\"\$HOME/.tmux.conf\"
    touch \"\$conf\"
    # Drop any existing history-limit / mouse lines, then append our values.
    tmp=\$(mktemp)
    grep -v -E '^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?(history-limit|mouse)' \"\$conf\" > \"\$tmp\" || true
    printf '\n# Effectively-unlimited scrollback + mouse (set by migrate-exe-vm.sh)\nset -g history-limit ${TMUX_HISTORY_LIMIT}\nset -g mouse on\n' >> \"\$tmp\"
    mv \"\$tmp\" \"\$conf\"
  " >/dev/null 2>&1; then
    ok "tmux history-limit=${TMUX_HISTORY_LIMIT} and mouse on set on destination"
  else
    warn "Failed to update tmux config on destination"
  fi
fi

# ----------------------------------------------------------------------------
# Step 4: Install missing dependencies on destination
# ----------------------------------------------------------------------------
log "Ensuring destination dependencies: ${REQUIRED_PKGS[*]}"
for pkg in "${REQUIRED_PKGS[@]}"; do
  if ssh_run "$DST" "command -v $pkg >/dev/null 2>&1"; then
    vlog "$pkg already installed"
  else
    if (( DRY_RUN )); then
      PKGS_INSTALLED+=("$pkg (dry-run)")
      vlog "[dry-run] Would install $pkg"
    else
      log "Installing $pkg on destination..."
      if ssh_run "$DST" "
        set -e
        if command -v apt-get >/dev/null 2>&1; then
          sudo apt-get update -qq && sudo apt-get install -y $pkg
        elif command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y $pkg
        elif command -v yum >/dev/null 2>&1; then
          sudo yum install -y $pkg
        elif command -v pacman >/dev/null 2>&1; then
          sudo pacman -Sy --noconfirm $pkg
        elif command -v apk >/dev/null 2>&1; then
          sudo apk add $pkg
        else
          echo 'no supported package manager' >&2; exit 1
        fi
      " >/dev/null 2>&1; then
        PKGS_INSTALLED+=("$pkg")
        ok "Installed $pkg"
      else
        PKGS_INSTALLED+=("$pkg (FAILED)")
        warn "Failed to install $pkg"
      fi
    fi
  fi
done

# ----------------------------------------------------------------------------
# Step 5: Install ble.sh on destination
# ----------------------------------------------------------------------------
log "Installing ble.sh on destination..."
if ssh_run "$DST" "test -f \"\$HOME/$BLESH_DEST/ble.sh\"" 2>/dev/null; then
  BLESH_STATUS="already installed"
  vlog "ble.sh already present at ~/$BLESH_DEST"
elif (( DRY_RUN )); then
  BLESH_STATUS="would install (dry-run)"
  vlog "[dry-run] Would clone and install ble.sh"
else
  if ssh_run "$DST" "
    set -e
    tmp=\$(mktemp -d)
    trap 'rm -rf \"\$tmp\"' EXIT
    git clone --recursive --depth 1 '$BLESH_REPO' \"\$tmp/ble.sh\"
    make -C \"\$tmp/ble.sh\" install PREFIX=\"\$HOME/.local\"
  " >/dev/null 2>&1; then
    if ssh_run "$DST" "test -f \"\$HOME/$BLESH_DEST/ble.sh\""; then
      BLESH_STATUS="installed"
      ok "ble.sh installed at ~/$BLESH_DEST"
    else
      BLESH_STATUS="install completed but ble.sh not found"
      warn "$BLESH_STATUS"
    fi
  else
    BLESH_STATUS="FAILED"
    warn "ble.sh installation failed"
  fi
fi

# ----------------------------------------------------------------------------
# Step 6: Validate copied configuration on destination
# ----------------------------------------------------------------------------
log "Validating copied configuration (bash -n)..."
for f in "${VALIDATE_FILES[@]}"; do
  if ssh_run "$DST" "test -f \"\$HOME/$f\"" 2>/dev/null; then
    if ssh_run "$DST" "bash -n \"\$HOME/$f\"" 2>/dev/null; then
      VALIDATION_RESULTS+=("$f: OK")
      vlog "$f: syntax OK"
    else
      VALIDATION_RESULTS+=("$f: SYNTAX ERROR")
      warn "$f failed bash -n syntax check"
    fi
  else
    VALIDATION_RESULTS+=("$f: not present")
  fi
done

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
print_list() {
  local title="$1"; shift
  printf '%s%s%s\n' "$C_BOLD" "$title" "$C_RESET"
  local item printed=0
  for item in "$@"; do
    [[ -n "$item" ]] || continue   # skip empty (bash 3.2 empty-array artifact)
    printf '  - %s\n' "$item"
    printed=1
  done
  (( printed )) || printf '  (none)\n'
}

echo
printf '%s========== SUMMARY ==========%s\n' "$C_BOLD" "$C_RESET"
(( DRY_RUN )) && warn "DRY-RUN: no changes were actually made."
print_list "Files copied:"       "${COPIED[@]:-}"
print_list "Files skipped:"      "${SKIPPED[@]:-}"
print_list "Backups created:"    "${BACKUPS[@]:-}"
print_list "Packages installed:" "${PKGS_INSTALLED[@]:-}"
printf '%sble.sh status:%s %s\n'  "$C_BOLD" "$C_RESET" "$BLESH_STATUS"
print_list "Validation results:" "${VALIDATION_RESULTS[@]:-}"
echo
ok "Done."
