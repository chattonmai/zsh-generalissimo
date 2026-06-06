#!/usr/bin/env zsh
# ssh-connettersi.sh — Interactive SSH manager powered by gum
# Usage: ./ssh-connettersi.sh  or  source it and call `ssi`
#
#   ssi            full SSH > main menu
#   ssi connect    fast path → Connect search
#   ssi <alias>    connect directly to a known host
#   ssi -h         usage
#
# ~/.ssh/config is the single source of truth. Only the top-level config file is
# ever written; Include'd files (e.g. OrbStack) are read but never modified.

# ─────────────────────────────────────────────
# Styles / Theme  (shared palette with git-gusto)
# ─────────────────────────────────────────────

_SG_PRIMARY=212    # magenta — cursor, selected, accents
_SG_SECONDARY=141  # purple  — headers, prompts
_SG_SUCCESS=84     # green
_SG_WARN=215       # orange
_SG_ERROR=203      # red
_SG_MUTED=245      # gray

_SG_CONFIG="$HOME/.ssh/config"
_SG_SSH_DIR="$HOME/.ssh"

# Session cache of host aliases. Cleared by Config → Reload.
_SG_HOSTS=""

# Make Homebrew (gum) and /usr/local (kiro) bins reachable even in shells where
# brew shellenv never ran (non-login shells, script execution). Idempotent.
for _sg_d in /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in
    *":$_sg_d:"*) ;;
    *) [[ -d "$_sg_d" ]] && export PATH="$_sg_d:$PATH" ;;
  esac
done
unset _sg_d

_sg_theme() {
  export GUM_CHOOSE_CURSOR="❯ "
  export GUM_CHOOSE_CURSOR_FOREGROUND=$_SG_PRIMARY
  export GUM_CHOOSE_HEADER_FOREGROUND=$_SG_SECONDARY
  export GUM_CHOOSE_SELECTED_FOREGROUND=$_SG_PRIMARY
  export GUM_CHOOSE_HEIGHT=12
  export GUM_CHOOSE_LABEL_DELIMITER="|"

  export GUM_FILTER_INDICATOR="❯"
  export GUM_FILTER_INDICATOR_FOREGROUND=$_SG_PRIMARY
  export GUM_FILTER_PROMPT="❯ "
  export GUM_FILTER_PROMPT_FOREGROUND=$_SG_SECONDARY
  export GUM_FILTER_MATCH_FOREGROUND=$_SG_PRIMARY
  export GUM_FILTER_HEADER_FOREGROUND=$_SG_SECONDARY
  export GUM_FILTER_HEIGHT=15

  export GUM_INPUT_PROMPT="❯ "
  export GUM_INPUT_PROMPT_FOREGROUND=$_SG_SECONDARY
  export GUM_INPUT_CURSOR_FOREGROUND=$_SG_PRIMARY

  export GUM_CONFIRM_PROMPT_FOREGROUND=$_SG_SECONDARY
  export GUM_CONFIRM_SELECTED_BACKGROUND=$_SG_PRIMARY
  export GUM_CONFIRM_SELECTED_FOREGROUND=235

  export GUM_SPIN_SPINNER="minidot"
  export GUM_SPIN_SPINNER_FOREGROUND=$_SG_PRIMARY
  export GUM_SPIN_TITLE_FOREGROUND=$_SG_SECONDARY

  export GUM_PAGER_HELP_FOREGROUND=$_SG_MUTED
}

# Status helpers degrade to plain echo if gum isn't reachable, so a missing gum
# never masks the real message with "command not found: gum".
_sg_style() { local c="$1"; shift; if command -v gum &>/dev/null; then gum style --foreground "$c" "$@"; else print -r -- "$@"; fi; }
_sg_header()  { if command -v gum &>/dev/null; then gum style --border rounded --border-foreground $_SG_PRIMARY --foreground $_SG_SECONDARY --padding "0 1" --bold " $1"; else print -r -- "== $1 =="; fi; }
_sg_success() { _sg_style $_SG_SUCCESS   "✔ $1"; }
_sg_warn()    { _sg_style $_SG_WARN      "⚠ $1"; }
_sg_error()   { _sg_style $_SG_ERROR     "✘ $1"; }
_sg_info()    { _sg_style $_SG_SECONDARY "→ $1"; }

# ─────────────────────────────────────────────
# Guards
# ─────────────────────────────────────────────

_sg_require_gum() {
  if ! command -v gum &>/dev/null; then
    # Non-login shells may miss Homebrew's bin; add the common locations.
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    hash -r 2>/dev/null
  fi
  if ! command -v gum &>/dev/null; then
    echo "Error: 'gum' is not installed. Install it with: brew install gum" >&2
    return 1
  fi
}

_sg_require_config() {
  if [[ ! -f "$_SG_CONFIG" ]]; then
    _sg_error "No SSH config found at $_SG_CONFIG"
    return 1
  fi
}

# ─────────────────────────────────────────────
# Layout helpers (grouped boxes), self-contained
# ─────────────────────────────────────────────

# Lay stdin items into a column-major, space-padded grid fitting <width> columns.
_sg_columnize() {
  awk -v width="$1" '
    { items[NR]=$0; if (length($0) > maxw) maxw=length($0) }
    END {
      if (NR == 0) exit
      gap=2; colw=maxw+gap
      ncols=int(width/colw); if (ncols < 1) ncols=1
      nrows=int((NR + ncols - 1) / ncols)
      for (r=0; r<nrows; r++) {
        line=""
        for (c=0; c<ncols; c++) {
          idx=c*nrows + r + 1
          if (idx <= NR) {
            s=items[idx]; line=line s
            pad=colw-length(s); while (pad-- > 0) line=line " "
          }
        }
        gsub(/ +$/, "", line); print line
      }
    }
  '
}

# Render stdin lines as one box per prefix group (split on first <delim>); lines
# without <delim> go in a "default" box. Usage: _sg_group_boxes <delim> <color> <width>
_sg_group_boxes() {
  local delim="$1" color="${2:-$_SG_PRIMARY}" width="${3:-100}"
  local line key
  local -A members
  local -a order

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *"$delim"* ]]; then
      key="${line%%${delim}*}"
    else
      key="default"
    fi
    [[ -z "${members[$key]+x}" ]] && order+=("$key")
    members[$key]+="${line}"$'\n'
  done

  local inner=$(( width - 4 ))
  (( inner < 10 )) && inner=10

  for key in "${order[@]}"; do
    gum style \
      --border rounded --border-foreground "$color" --padding "0 1" \
      "$(gum style --foreground "$color" --bold "$key")
$(echo "${members[$key]%$'\n'}" | _sg_columnize "$inner")"
  done
}

# ─────────────────────────────────────────────
# Host data
# ─────────────────────────────────────────────

# Aliases from ~/.ssh/config: expand multi-name Host lines, drop wildcards.
_sg_host_aliases() {
  [[ -n "$_SG_HOSTS" ]] && { print -r -- "$_SG_HOSTS"; return; }
  _SG_HOSTS=$(awk '
    tolower($1) == "host" {
      for (i = 2; i <= NF; i++)
        if ($i !~ /[*?]/) print $i
    }
  ' "$_SG_CONFIG" 2>/dev/null | awk '!seen[$0]++')
  print -r -- "$_SG_HOSTS"
}

# Effective hostname/user/port/identityfile for an alias, via `ssh -G`.
# Sets globals: _SG_D_HOST _SG_D_USER _SG_D_PORT _SG_D_KEY
_sg_host_detail() {
  local alias="$1" line k v
  _SG_D_HOST="" _SG_D_USER="" _SG_D_PORT="" _SG_D_KEY=""
  while IFS=' ' read -r k v; do
    case "$k" in
      hostname)     _SG_D_HOST="$v" ;;
      user)         _SG_D_USER="$v" ;;
      port)         _SG_D_PORT="$v" ;;
      identityfile) [[ -z "$_SG_D_KEY" ]] && _SG_D_KEY="$v" ;;
    esac
  done < <(ssh -G "$alias" 2>/dev/null)
}

# gum-filter picker over host aliases. Echoes the chosen alias (empty on cancel).
_sg_pick_host() {
  local hosts
  hosts=$(_sg_host_aliases)
  [[ -z "$hosts" ]] && { _sg_warn "No hosts found in $_SG_CONFIG" >&2; return 1; }
  print -r -- "$hosts" | gum filter --placeholder "${1:-Search host...}"
}

# ─────────────────────────────────────────────
# Key data
# ─────────────────────────────────────────────

# Private keys in ~/.ssh: files that have a matching .pub sibling.
_sg_key_list() {
  setopt local_options null_glob
  local pub priv
  for pub in "$_SG_SSH_DIR"/*.pub; do
    priv="${pub%.pub}"
    [[ -f "$priv" ]] && print -r -- "$priv"
  done
}

# gum-filter picker over private keys. Echoes the chosen path (empty on cancel).
_sg_pick_key() {
  local keys
  keys=$(_sg_key_list)
  [[ -z "$keys" ]] && { _sg_warn "No keypairs found in $_SG_SSH_DIR" >&2; return 1; }
  print -r -- "$keys" | gum filter --placeholder "${1:-Search key...}"
}

# ─────────────────────────────────────────────
# Connect
# ─────────────────────────────────────────────

# Action menu for a selected host (shared by Connect + Hosts → Search).
_sg_host_actions() {
  local alias="$1" action
  action=$(gum choose --header "$alias" \
    " Connect|connect" \
    " Copy SSH Command|copy" \
    " Show Details|details" \
    " Back|back")
  case "$action" in
    connect) _sg_connect_target "$alias" ;;
    copy)    printf 'ssh %s' "$alias" | pbcopy; _sg_success "Copied: ssh $alias" ;;
    details) _sg_show_details "$alias" ;;
  esac
}

# After choosing Connect, pick where: terminal SSH or open the host in Kiro.
_sg_connect_target() {
  local alias="$1" how
  how=$(gum choose --header "Connect to $alias" \
    " Terminal (ssh)|term" \
    " Kiro|ide" \
    " Back|back")
  case "$how" in
    term) _sg_info "ssh $alias"; ssh "$alias" ;;
    ide)  _sg_open_ide "$alias" ;;
  esac
}

# Open a remote folder on <alias> in Kiro via Remote-SSH (open-remote-ssh).
_sg_open_ide() {
  local alias="$1" user defpath remote_path authority rc kbin
  # Resolve kiro by PATH, else fall back to the known install location, so this
  # works even in a shell where /usr/local/bin isn't on PATH.
  kbin=$(command -v kiro 2>/dev/null)
  [[ -z "$kbin" && -x /usr/local/bin/kiro ]] && kbin=/usr/local/bin/kiro
  if [[ -z "$kbin" ]]; then
    _sg_error "kiro CLI not found (looked on PATH and /usr/local/bin)."; return
  fi
  _sg_host_detail "$alias"
  user="${_SG_D_USER:-$USER}"
  [[ "$user" == "root" ]] && defpath="/root" || defpath="/home/$user"
  if command -v gum &>/dev/null; then
    remote_path=$(gum input --header "Remote folder on $alias" --value "$defpath" --width 50)
  else
    printf 'Remote folder on %s [%s]: ' "$alias" "$defpath" >&2
    IFS= read -r remote_path
    [[ -z "$remote_path" ]] && remote_path="$defpath"
  fi
  remote_path="${remote_path//$'\r'/}"
  [[ -z "$remote_path" ]] && return

  # Kiro's CLI is a shell script with an env-based bash shebang; normalize PATH
  # so system shells are always reachable even if the current shell was trimmed.
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
  hash -r 2>/dev/null

  authority="ssh-remote+${user}@${alias}"
  _sg_info "$kbin --remote $authority $remote_path"
  "$kbin" --remote "$authority" "$remote_path"
  rc=$?

  if (( rc == 0 )); then
    _sg_success "Launched Kiro → ${user}@${alias}:$remote_path (watch for the remote window / connect prompt)."
  else
    _sg_error "Kiro exited rc=$rc. Output:"
  fi
}

_sg_show_details() {
  local alias="$1"
  _sg_host_detail "$alias"
  gum style --border rounded --border-foreground $_SG_PRIMARY --padding "0 1" \
    "$(gum style --foreground $_SG_PRIMARY --bold "Host")          $alias
$(gum style --foreground $_SG_SECONDARY "HostName")      ${_SG_D_HOST:-—}
$(gum style --foreground $_SG_SECONDARY "User")          ${_SG_D_USER:-—}
$(gum style --foreground $_SG_SECONDARY "Port")          ${_SG_D_PORT:-22}
$(gum style --foreground $_SG_SECONDARY "IdentityFile")  ${_SG_D_KEY:-—}"
}

_sg_connect() {
  _sg_require_gum || return
  _sg_require_config || return
  local alias
  echo ""; _sg_banner; echo ""
  alias=$(_sg_pick_host "Connect to...") || return
  [[ -z "$alias" ]] && return
  _sg_host_actions "$alias"
}

# ─────────────────────────────────────────────
# Hosts
# ─────────────────────────────────────────────

_sg_hosts_list() {
  _sg_require_config || return
  local hosts out
  hosts=$(_sg_host_aliases)
  [[ -z "$hosts" ]] && { _sg_warn "No hosts found."; return; }
  out=$(print -r -- "$hosts" | _sg_group_boxes "-" "$_SG_PRIMARY" 100)
  print -r -- "$out" | gum pager
}

_sg_hosts_test() {
  _sg_require_config || return
  local alias
  alias=$(_sg_pick_host "Test connection to...") || return
  [[ -z "$alias" ]] && return
  if gum spin --title "Testing $alias..." -- \
      ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
          "$alias" true; then
    _sg_success "$alias is reachable (authenticated)."
  else
    # BatchMode failures still prove reachability when the refusal is auth-related.
    _sg_warn "$alias did not complete a non-interactive login (unreachable, or needs a passphrase/interactive auth)."
  fi
}

_sg_hosts_add() {
  _sg_require_config || return
  local alias host user port key block keys

  _sg_header "Add host"
  echo ""

  alias=$(gum input --header "Alias" --placeholder "e.g. aws-prod" --width 40)
  [[ -z "$alias" ]] && return
  if [[ "$alias" == *[[:space:]]* ]]; then
    _sg_error "Alias can't contain spaces."; return
  fi
  if _sg_host_aliases | grep -qxF "$alias"; then
    _sg_error "Host '$alias' already exists in $_SG_CONFIG."; return
  fi

  host=$(gum input --header "HostName" --placeholder "IP or domain" --width 40)
  [[ -z "$host" ]] && { _sg_info "HostName is required — aborted."; return; }
  user=$(gum input --header "User" --placeholder "(optional)" --width 40)
  port=$(gum input --header "Port" --value "22" --width 40)

  # IdentityFile: require pinning an existing key.
  keys=$(_sg_key_list)
  if [[ -z "$keys" ]]; then
    _sg_warn "No keypairs found in $_SG_SSH_DIR — nothing to pin."
    gum confirm "Add '$alias' without an IdentityFile?" || { _sg_info "Aborted."; return; }
    key=""
  else
    # Format as "basename|fullpath" to satisfy GUM_CHOOSE_LABEL_DELIMITER ("|"):
    # shows the key name, returns the full path.
    local k
    key=$(for k in ${(f)keys}; do print -r -- "$(basename "$k")|$k"; done \
      | gum choose --header "IdentityFile (required)")
    [[ -z "$key" ]] && { _sg_info "No key selected — aborted."; return; }
  fi

  # Build the block, including only the fields that were filled in.
  block="Host $alias"$'\n'"  HostName $host"
  [[ -n "$user" ]]            && block+=$'\n'"  User $user"
  [[ -n "$port" && "$port" != "22" ]] && block+=$'\n'"  Port $port"
  [[ -n "$key" ]]            && block+=$'\n'"  IdentityFile $key"

  echo ""
  gum style --border rounded --border-foreground $_SG_PRIMARY --padding "0 1" "$block"
  echo ""
  gum confirm "Append this host to $_SG_CONFIG?" || { _sg_info "Aborted."; return; }

  _sg_backup_config
  printf '\n%s\n' "$block" >> "$_SG_CONFIG"
  _SG_HOSTS=""   # refresh cache
  _sg_success "Added '$alias' (backup written)."
}

# Aliases safe to remove: single-alias, non-wildcard Host lines in the top-level
# config (excludes multi-alias lines and Include'd hosts).
_sg_removable_hosts() {
  awk '$1=="Host" && NF==2 && $2 !~ /[*?]/ { print $2 }' "$_SG_CONFIG" 2>/dev/null
}

_sg_hosts_remove() {
  _sg_require_config || return
  local alias block removable
  removable=$(_sg_removable_hosts)
  [[ -z "$removable" ]] && { _sg_warn "No removable hosts in $_SG_CONFIG."; return; }

  alias=$(print -r -- "$removable" | gum filter --placeholder "Remove host...") || return
  [[ -z "$alias" ]] && return

  # Preview the block being removed.
  block=$(awk -v t="$alias" '
    $1=="Host" { inb=0; for (i=2;i<=NF;i++) if ($i==t) inb=1 }
    inb { print }
  ' "$_SG_CONFIG")
  echo ""
  gum style --border rounded --border-foreground $_SG_WARN --padding "0 1" "$block"
  echo ""
  gum confirm "Remove host '$alias' from $_SG_CONFIG?" || { _sg_info "Aborted."; return; }

  _sg_backup_config
  local tmp; tmp=$(mktemp)
  awk -v t="$alias" '
    $1=="Host" { inb=0; for (i=2;i<=NF;i++) if ($i==t) inb=1 }
    inb { next }
    { print }
  ' "$_SG_CONFIG" > "$tmp" && mv "$tmp" "$_SG_CONFIG"
  _SG_HOSTS=""   # refresh cache
  _sg_success "Removed '$alias' (backup written)."
}

_sg_hosts() {
  _sg_require_gum || return
  local choice a
  while true; do
    choice=$(gum choose --header "Hosts >" \
      " List|list" \
      " Search|search" \
      " Add|add" \
      " Remove|remove" \
      " Test Connection|test" \
      " Back|back")
    [[ -z "$choice" || "$choice" == "back" ]] && return
    case "$choice" in
      list)   _sg_hosts_list ;;
      search) a=$(_sg_pick_host) && [[ -n "$a" ]] && _sg_host_actions "$a" ;;
      add)    _sg_hosts_add ;;
      remove) _sg_hosts_remove ;;
      test)   _sg_hosts_test ;;
    esac
  done
}

# ─────────────────────────────────────────────
# Keys
# ─────────────────────────────────────────────

_sg_keys_list() {
  local key fp out
  local keys; keys=$(_sg_key_list)
  [[ -z "$keys" ]] && { _sg_warn "No keypairs found in $_SG_SSH_DIR"; return; }
  out=$(print -r -- "$keys" | while IFS= read -r key; do
    fp=$(ssh-keygen -lf "$key" 2>/dev/null)
    gum style "$(gum style --foreground $_SG_PRIMARY --bold "$(basename "$key")")
$(gum style --foreground $_SG_MUTED "$key")
$(gum style --foreground $_SG_SECONDARY "${fp:-no fingerprint}")
"
  done)
  print -r -- "$out" | gum pager
}

_sg_keys_show_pub() {
  local key pub action
  key=$(_sg_pick_key "Show public key...") || return
  [[ -z "$key" ]] && return
  pub="${key}.pub"
  [[ -f "$pub" ]] || { _sg_error "No public key at $pub"; return; }
  action=$(gum choose --header "$(basename "$pub")" \
    " Copy to clipboard|copy" \
    " View|view" \
    " Back|back")
  case "$action" in
    copy) pbcopy < "$pub"; _sg_success "Copied $(basename "$pub") to clipboard." ;;
    view) gum style --border rounded --border-foreground $_SG_PRIMARY --padding "0 1" \
            "$(cat "$pub")" ;;
  esac
}

_sg_keys_generate() {
  local name path comment pass
  _sg_header "Generate key"
  echo ""
  name=$(gum input --header "Key name" --placeholder "e.g. id_work" --width 40)
  [[ -z "$name" ]] && return
  if [[ "$name" == *[/[:space:]]* ]]; then
    _sg_error "Key name can't contain spaces or slashes."
    return
  fi
  path="$_SG_SSH_DIR/$name"
  if [[ -e "$path" ]]; then
    _sg_error "$path already exists."
    return
  fi
  comment=$(gum input --value "$USER@$(hostname -s)" --placeholder "Comment..." --width 40)
  pass=$(gum input --password --placeholder "Passphrase (blank for none)...")

  if ssh-keygen -t ed25519 -f "$path" -C "$comment" -N "$pass"; then
    chmod 600 "$path"; chmod 644 "$path.pub"
    _sg_success "Created $path"
    if gum confirm "Show the new public key?"; then
      gum style --border rounded --border-foreground $_SG_PRIMARY --padding "0 1" \
        "$(cat "$path.pub")"
    fi
  else
    _sg_error "Key generation failed."
  fi
}

_sg_keys_remove() {
  local key name typed
  key=$(_sg_pick_key "Remove key...") || return
  [[ -z "$key" ]] && return
  name=$(basename "$key")

  gum style --foreground $_SG_WARN "$(ssh-keygen -lf "$key" 2>/dev/null)"

  if grep -qiE "IdentityFile.*$name([^.]|$)" "$_SG_CONFIG" 2>/dev/null; then
    _sg_warn "$name is referenced by an IdentityFile in $_SG_CONFIG."
    gum confirm "Delete it anyway?" || return
  fi

  typed=$(gum input --placeholder "Type '$name' to confirm deletion...")
  if [[ "$typed" != "$name" ]]; then
    _sg_info "Name did not match — aborted."
    return
  fi
  rm -f "$key" "$key.pub"
  _sg_success "Removed $name and $name.pub"
}

_sg_keys_add_agent() {
  local key
  key=$(_sg_pick_key "Add to agent...") || return
  [[ -z "$key" ]] && return
  if [[ "$OSTYPE" == darwin* ]] && gum confirm "Store passphrase in macOS Keychain?"; then
    ssh-add --apple-use-keychain "$key" && _sg_success "Added $(basename "$key") (keychain)."
  else
    ssh-add "$key" && _sg_success "Added $(basename "$key") to agent."
  fi
}

_sg_keys_remove_agent() {
  local key
  key=$(_sg_pick_key "Remove from agent...") || return
  [[ -z "$key" ]] && return
  ssh-add -d "$key" && _sg_success "Removed $(basename "$key") from agent."
}

_sg_keys() {
  _sg_require_gum || return
  local choice
  while true; do
    choice=$(gum choose --header "Keys >" \
      " List|list" \
      " Show Public Key|show" \
      " Generate|generate" \
      " Remove|remove" \
      " Add To Agent|add" \
      " Remove From Agent|rm" \
      " Back|back")
    [[ -z "$choice" || "$choice" == "back" ]] && return
    case "$choice" in
      list)     _sg_keys_list ;;
      show)     _sg_keys_show_pub ;;
      generate) _sg_keys_generate ;;
      remove)   _sg_keys_remove ;;
      add)      _sg_keys_add_agent ;;
      rm)       _sg_keys_remove_agent ;;
    esac
  done
}

# ─────────────────────────────────────────────
# Agent
# ─────────────────────────────────────────────

_sg_agent_status() {
  local out
  out=$(ssh-add -l 2>&1)
  case "$?" in
    0) _sg_header "Loaded identities"; echo ""
       gum style --foreground $_SG_SECONDARY "$out" ;;
    1) _sg_info "Agent is running but has no identities loaded." ;;
    *) _sg_warn "ssh-agent is not running ($out)." ;;
  esac
}

_sg_agent_clear() {
  gum confirm "Remove all loaded keys?" || return
  ssh-add -D && _sg_success "Cleared all identities from the agent."
}

_sg_agent() {
  _sg_require_gum || return
  local choice
  while true; do
    choice=$(gum choose --header "Agent >" \
      " Status|status" \
      " Load Key|load" \
      " Unload Key|unload" \
      " Clear Agent|clear" \
      " Back|back")
    [[ -z "$choice" || "$choice" == "back" ]] && return
    case "$choice" in
      status) _sg_agent_status ;;
      load)   _sg_keys_add_agent ;;
      unload) _sg_keys_remove_agent ;;
      clear)  _sg_agent_clear ;;
    esac
  done
}

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────

_sg_backup_config() {
  cp "$_SG_CONFIG" "$_SG_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
}

_sg_config_view_host() {
  _sg_require_config || return
  local alias
  alias=$(_sg_pick_host "View resolved config for...") || return
  [[ -z "$alias" ]] && return
  ssh -G "$alias" 2>/dev/null | gum pager
}

_sg_config_open() {
  _sg_require_config || return
  local editor
  editor=$(gum choose --header "Open $_SG_CONFIG with..." \
    " Kiro|kiro" \
    " Default Editor|default" \
    " Back|back")
  case "$editor" in
    kiro)    command -v kiro &>/dev/null || { _sg_error "kiro not found."; return; }
             _sg_backup_config; kiro "$_SG_CONFIG" ;;
    default) _sg_backup_config; ${EDITOR:-vi} "$_SG_CONFIG" ;;
    *)       return ;;
  esac
  _SG_HOSTS=""   # config may have changed — drop cache
  _sg_info "Host cache refreshed."
}

_sg_config_reload() {
  _SG_HOSTS=""
  _sg_success "Reloaded host cache from $_SG_CONFIG"
}

_sg_config() {
  _sg_require_gum || return
  local choice
  while true; do
    choice=$(gum choose --header "Config >" \
      " View Host|view" \
      " Open Config|open" \
      " Reload|reload" \
      " Back|back")
    [[ -z "$choice" || "$choice" == "back" ]] && return
    case "$choice" in
      view)   _sg_config_view_host ;;
      open)   _sg_config_open ;;
      reload) _sg_config_reload ;;
    esac
  done
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

_sg_usage() {
  cat <<'EOF'
ssi — gum-powered SSH manager

  ssi            full SSH > menu (Connect / Hosts / Keys / Agent / Config)
  ssi connect    fast path: search hosts and connect
  ssi <alias>    connect directly to a known host
  ssi -h         this help

~/.ssh/config is the source of truth. Backups (config.bak.*) are written before
any config edit; Include'd files are never modified.
EOF
}

# Compact banner shown before the fast-path picker.
_sg_banner() {
  local n loaded
  n=$(_sg_host_aliases | grep -c .)
  loaded=$(ssh-add -l 2>/dev/null | grep -c .)
  gum style \
    --border rounded --border-foreground $_SG_PRIMARY --padding "0 2" \
    "$(gum style --foreground $_SG_PRIMARY --bold " SSH")    $(gum style --foreground $_SG_SECONDARY --bold "${n} hosts")    $(gum style --foreground $_SG_MUTED "🔑 ${loaded} loaded")    $(gum style --foreground $_SG_MUTED "menu · 'ssi menu'")"
}

_sg_menu() {
  _sg_require_gum || return
  local choice
  while true; do
    echo ""
    _sg_header "SSH >"
    echo ""
    choice=$(gum choose --header "What do you want to do?" \
      " Connect|Connect" \
      " Hosts|Hosts" \
      " Keys|Keys" \
      " Agent|Agent" \
      " Config|Config" \
      " Quit|Quit")
    [[ -z "$choice" || "$choice" == "Quit" ]] && return
    case "$choice" in
      Connect) _sg_connect ;;
      Hosts)   _sg_hosts ;;
      Keys)    _sg_keys ;;
      Agent)   _sg_agent ;;
      Config)  _sg_config ;;
    esac
  done
}

ssi() {
  _sg_require_gum || return
  _sg_theme

  case "$1" in
    -h|--help|help) _sg_usage; return ;;
    ""|menu)        _sg_menu; return ;;
    connect)        _sg_connect; return ;;             # fast picker
    *)              _sg_info "ssh $1"; ssh "$1" ;;     # direct connect
  esac
}

# Run ssi directly when executed as a script (not when sourced).
if [[ "$zsh_eval_context" == "toplevel" ]]; then
  ssi "$@"
fi
