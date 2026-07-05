#!/usr/bin/env zsh
# git-gusto.sh — Interactive Git workflow manager powered by gum
# Usage: ./git-gusto.sh  or  source it and call `gg`

# ─────────────────────────────────────────────
# Guards
# ─────────────────────────────────────────────

_gm_require_gum() {
  if ! command -v gum &>/dev/null; then
    echo "Error: 'gum' is not installed. Install it with: brew install gum" >&2
    return 1
  fi
}

_gm_require_git() {
  if ! command -v git &>/dev/null; then
    gum style --foreground $_GM_ERROR "'git' is not installed."
    return 1
  fi
}

_gm_remote_url() {
  local remote
  remote=$(gum input \
    --placeholder "Remote URL (https://... or git@...)" \
    --width 60)
  [[ -z "$remote" ]] && return 1
  echo "$remote"
}

_gm_git_init_branch() {
  local branch="${1:-main}"
  if git init -b "$branch" &>/dev/null 2>&1; then
    return 0
  fi

  git init || return 1
  git symbolic-ref HEAD "refs/heads/$branch" || return 1
}

_gm_git_init_main() { _gm_git_init_branch main; }

# Create the very first commit when the repo has no commits yet. Stages
# everything, then prompts for a message (defaulting to "Initial commit").
# Returns 1 if there is nothing to commit or the user cancels.
_gm_initial_commit() {
  if git rev-parse HEAD &>/dev/null 2>&1; then
    return 0
  fi

  local msg
  _gm_run add -A
  if [[ -z "$(git diff --cached --name-only)" ]]; then
    _gm_warn "Nothing to commit yet — add files before pushing."
    return 1
  fi

  msg=$(gum input --placeholder "Initial commit message..." --value "Initial commit" --width 60)
  [[ -z "$msg" ]] && return 1

  if _gm_run commit -m "$msg"; then
    _gm_success "Created initial commit: $msg"
  else
    _gm_error "Initial commit failed"
    return 1
  fi
}

# Add or update a named remote. $1 = remote name; when omitted, prompt for
# origin / upstream / a custom name. Reports whether it added or updated.
_gm_set_remote() {
  local name="$1" remote

  if [[ -z "$name" ]]; then
    name=$(gum choose --header "Remote name:" \
      " origin|origin" " upstream|upstream" " Custom…|__custom__")
    [[ -z "$name" ]] && return 1
    if [[ "$name" == "__custom__" ]]; then
      name=$(gum input --placeholder "Remote name (e.g. fork)" --width 40)
      [[ -z "$name" ]] && return 1
    fi
  fi

  remote=$(_gm_remote_url) || return 1
  if git remote get-url "$name" &>/dev/null 2>&1; then
    _gm_run remote set-url "$name" "$remote" || return 1
    _gm_success "Updated $name: $remote"
  else
    _gm_run remote add "$name" "$remote" || return 1
    _gm_success "Added $name: $remote"
  fi
}

# Bootstrap origin specifically — used by the init/push flows that require it.
# Offers to init a repo first when there isn't one, then delegates to the
# general helper with a fixed "origin" name.
_gm_set_origin() {
  if ! git rev-parse --git-dir &>/dev/null 2>&1; then
    gum confirm "This directory is not a git repository. Initialize it first?" || return 1
    _gm_git_init_main || return 1
    _gm_success "Initialized repository on main"
  fi

  _gm_set_remote origin
}

# Remote submenu: list / add-update / remove.
_gm_remote() {
  _gm_require_repo || return

  local action="$1"
  if [[ -z "$action" ]]; then
    action=$(gum choose --header "Remote:" \
      " List|List" " Add / Update|Set" " Remove|Remove" " Back|← Back")
  fi
  [[ -z "$action" ]] && return

  case "${action:l}" in
    list)            _gm_remote_list ;;
    set|add|update)  _gm_set_remote ;;
    remove|delete)   _gm_remote_delete ;;
    "← back"|back)   return ;;
    *) _gm_error "Unknown remote action: $action" ;;
  esac
}

_gm_remote_list() {
  local remotes
  remotes=$(git remote -v)
  [[ -z "$remotes" ]] && { _gm_warn "No remotes configured."; return; }
  {
    gum style --foreground $_GM_PRIMARY --bold " REMOTES"
    echo ""
    echo "$remotes"
  } | gum pager
}

_gm_remote_delete() {
  local name
  name=$(git remote | _gm_filter --placeholder "Select remote to remove...")
  [[ -z "$name" ]] && return
  gum confirm "Remove remote '$name'?" || return
  _gm_run remote remove "$name" && _gm_success "Removed remote: $name"
}

_gm_open_target() {
  local target="$1" action
  action=$(gum choose --header "Open in:" \
    " Kiro|Kiro" " Shell|Shell" " Skip|Skip")
  case "$action" in
    Kiro)  kiro "$target" ;;
    Shell) cd "$target" && exec $SHELL ;;
    Skip)  ;;
  esac
}

_gm_clone() {
  local remote dest target

  remote=$(_gm_remote_url) || return 1

  # Default the destination folder to the repo name parsed from the URL.
  local default
  default=$(basename "$remote" .git)
  dest=$(gum input \
    --placeholder "Destination folder (blank = $default)" \
    --value "$default" \
    --width 60)
  [[ -z "$dest" ]] && dest="$default"

  echo ""
  _gm_block "$_GM_BLOCK_HEX" \
    "Clone: $remote
Into:  $dest"
  echo ""
  gum confirm "Clone this repository?" || return 1

  _gm_cmd clone "$remote" "$dest"
  if ! gum spin --title "Cloning..." -- git clone "$remote" "$dest"; then
    _gm_error "Clone failed"
    return 1
  fi
  _gm_success "Cloned into $dest"

  target=$(cd "$dest" 2>/dev/null && pwd) || return 0
  local action
  action=$(gum choose --header "Open clone in:" \
    " Shell|shell" \
    " Open Clone With...|with" \
    " Skip|skip")

  case "$action" in
    shell) cd "$target" && exec $SHELL ;;
    with)  _gm_open_target "$target" ;;
    skip)  ;;
  esac
}

_gm_ensure_origin() {
  if git remote get-url origin &>/dev/null 2>&1; then
    return 0
  fi

  gum confirm "No origin remote is set. Set origin now?" || return 1
  _gm_set_origin
}

_gm_prefer_main_branch() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return 0

  if [[ "$branch" == "master" ]] && gum confirm "Rename branch 'master' to 'main' before pushing?"; then
    _gm_run branch -m main || return 1
    _gm_success "Renamed branch to main"
  fi
}

_gm_init_repo() {
  local branch

  gum confirm "Initialize git in this directory?" || return 1

  branch=$(gum choose --header "Default branch:" " main|main" " master|master")
  [[ -z "$branch" ]] && branch=main
  _gm_git_init_branch "$branch" || return 1
  _gm_success "Initialized repository on $branch"

  if gum confirm "Add a remote origin now?"; then
    _gm_set_origin || return 1

    branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    branch=${branch:-main}
    if gum confirm "Push current branch '$branch' to origin?"; then
      _gm_initial_commit || { _gm_info "Push skipped — no initial commit."; return; }
      _gm_cmd push -u origin "$branch"
      if gum spin --title "Pushing..." -- git push -u origin "$branch"; then
        _gm_success "Pushed $branch to origin"
      else
        _gm_error "Push failed"
      fi
    fi
  fi
}

_gm_repo_setup() {
  local action

  _gm_header "No Git Repository"
  echo ""

  action=$(gum choose \
    --header "Set up this directory:" \
    " Init Git Repository|Init Git Repository" \
    " Clone Repository|Clone Repository" \
    " Set Remote Origin|Set Remote Origin" \
    " Back|← Back")
  [[ -z "$action" || "${action:l}" == "← back" || "${action:l}" == "back" ]] && return 1

  case "$action" in
    "Init Git Repository")
      _gm_init_repo
      ;;
    "Clone Repository")
      _gm_clone
      ;;
    "Set Remote Origin")
      _gm_set_origin
      ;;
  esac

  return 0
}

_gm_repo_setup_menu() {
  local action
  _gm_repo_setup || return
  echo ""
  action=$(gum choose --header "Next step:" \
    " Open Main Menu|Open Main Menu" \
    " Quit|Quit")
  [[ "$action" == "Quit" || -z "$action" ]] && return 1
  return 0
}

_gm_repo_setup_if_needed() {
  if git rev-parse --git-dir &>/dev/null 2>&1; then
    return 0
  fi
  _gm_repo_setup_menu
  return $?
}

_gm_require_repo() {
  if git rev-parse --git-dir &>/dev/null 2>&1; then
    return 0
  fi
  _gm_error "Not inside a git repository."
  return 1
}

# ─────────────────────────────────────────────
# Styles / Theme
# ─────────────────────────────────────────────

# Magenta/Purple palette (256-color codes). Used by the style helpers and
# exported (via _gm_theme) to every gum widget for a consistent look.
_GM_SECONDARY=141  # purple  — headers, prompts
_GM_SUCCESS=84     # green
_GM_WARN=215       # orange
_GM_ERROR=203      # red
_GM_MUTED=245      # gray
_GM_BG=235         # dark gray — gum widget text background

# Truecolor palette for solid filled-background blocks (previews, confirmations,
# the "view" list screens). Fixed regardless of light/dark theme, since the
# block sets its own background explicitly.
_GM_BLOCK_HEX="#7C6FF0"        # primary block bg
_GM_BLOCK_WARN_HEX="#D98E3E"   # warn/destructive-preview block bg
_GM_BLOCK_ERROR_HEX="#D9556A"  # error/delete-preview block bg
_GM_BLOCK_FG_HEX="#F5F3FF"     # off-white text on any block bg

# Rotating palette for multi-group "view" screens (e.g. one color per
# feature/, fix/, chore/ branch prefix) so adjacent groups look distinct.
# _gm_group_boxes cycles through this starting at a caller-given offset.
_GM_BLOCK_PALETTE=(
  "#7C6FF0"  # purple
  "#5B8DEF"  # blue
  "#4EC9B0"  # teal
  "#E0607A"  # pink
  "#D98E3E"  # amber
  "#8FD14F"  # green
  "#B57EDC"  # lavender
  "#4FA8D8"  # sky
)

_GM_PRIMARY_DARK=213   # brighter magenta — cursor, selected, accents (dark theme)
_GM_FG_DARK=254             # off-white — gum widget text foreground (dark theme)
_GM_FG_HEX_DARK="#e4e4e4"   # off-white — terminal-wide foreground, OSC 10 (dark theme)
_GM_BG_HEX_DARK="#262626"   # dark gray — terminal-wide background, OSC 11 (dark theme)

_GM_PRIMARY_LIGHT=213  # magenta — cursor, selected, accents (light theme)
_GM_FG_LIGHT=235            # dark gray — gum widget text foreground (light theme)
_GM_FG_HEX_LIGHT="#141414"  # dark gray — terminal-wide foreground, OSC 10 (light theme)
_GM_BG_HEX_LIGHT="#FDFDFD"  # light gray — terminal-wide background, OSC 11 (light theme)

# Resolved per-run by _gm_apply_theme_pref (defaults to dark, today's behavior).
_GM_PRIMARY=$_GM_PRIMARY_DARK
_GM_FG=$_GM_FG_DARK
_GM_FG_HEX=$_GM_FG_HEX_DARK
_GM_BG_HEX=$_GM_BG_HEX_DARK

# Per-terminal theme preference, keyed by $TERM_PROGRAM (covers both terminal
# emulators and IDE-integrated terminals). Some terminals (e.g. Warp) ignore the
# OSC 11 background escape below, so their real background stays whatever their
# own theme is — 'gg theme light' lets a user match gg's foreground to that.
_gm_theme_config_file() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/git-gusto/theme.conf"; }

# Prints "light" or "dark" if a preference is saved for this $TERM_PROGRAM, else nothing.
_gm_theme_get_saved() {
  local key="${TERM_PROGRAM:-unknown}" file=$(_gm_theme_config_file)
  [[ -f "$file" ]] || return
  awk -F= -v k="$key" '$1==k{print $2}' "$file" | tail -1
}

# value: "light" | "dark" | "auto" (auto = remove override, revert to default).
_gm_theme_set_saved() {
  local value="$1" key="${TERM_PROGRAM:-unknown}" file=$(_gm_theme_config_file)
  mkdir -p "${file:h}"
  local tmp="${file}.tmp.$$"
  [[ -f "$file" ]] && grep -v "^${key}=" "$file" > "$tmp"
  [[ "$value" != "auto" ]] && echo "${key}=${value}" >> "$tmp"
  mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
}

# Apply the saved preference (if any) for this terminal; default stays dark.
_gm_apply_theme_pref() {
  if [[ "$(_gm_theme_get_saved)" == "light" ]]; then
    _GM_PRIMARY=$_GM_PRIMARY_LIGHT
    _GM_FG=$_GM_FG_LIGHT
    _GM_FG_HEX=$_GM_FG_HEX_LIGHT
    _GM_BG_HEX=$_GM_BG_HEX_LIGHT
  else
    _GM_PRIMARY=$_GM_PRIMARY_DARK
    _GM_FG=$_GM_FG_DARK
    _GM_FG_HEX=$_GM_FG_HEX_DARK
    _GM_BG_HEX=$_GM_BG_HEX_DARK
  fi
}

_gm_theme_cmd() {
  local action="${1:l}"
  case "$action" in
    light|dark)
      _gm_theme_set_saved "$action"
      _gm_success "Theme set to '$action' for ${TERM_PROGRAM:-this terminal}."
      ;;
    auto|reset)
      _gm_theme_set_saved "auto"
      _gm_success "Theme reset to default (dark) for ${TERM_PROGRAM:-this terminal}."
      ;;
    "")
      local saved=$(_gm_theme_get_saved)
      _gm_info "Current terminal (${TERM_PROGRAM:-unknown}): ${saved:-dark (default)}"
      ;;
    *) _gm_error "Usage: gg theme [light|dark|auto]" ;;
  esac
}

# Paint the whole terminal background/foreground for the duration of gg().
# Best-effort: OSC 10/11 are ignored by terminals that don't support them.
_gm_term_theme_start() {
  printf '\033]11;%s\007' "$_GM_BG_HEX"
  printf '\033]10;%s\007' "$_GM_FG_HEX"
}
# Restore the terminal's own default colors (OSC 110/111 reset codes).
_gm_term_theme_reset() {
  printf '\033]111\007'
  printf '\033]110\007'
  # Nudge a repaint: single-cell nudges (cursor toggle, blank line, a
  # printed-then-erased glyph) don't force Ghostty to redraw the rest of
  # the visible viewport — only editing a cell's content invalidates its
  # cached color. Toggling the alternate screen buffer forces a full,
  # non-destructive redraw of the primary screen on return (the same
  # mechanism vim/less/tmux rely on), without erasing any content.
  printf '\033[?1049h\033[?1049l'
}

# Theme every gum component once via its env vars. Called at the top of gg().
_gm_theme() {
  # choose
  export GUM_CHOOSE_CURSOR="❯ "
  export GUM_CHOOSE_CURSOR_FOREGROUND=$_GM_PRIMARY
  export GUM_CHOOSE_HEADER_FOREGROUND=$_GM_SECONDARY
  export GUM_CHOOSE_SELECTED_FOREGROUND=$_GM_PRIMARY
  export GUM_CHOOSE_ITEM_FOREGROUND=$_GM_FG
  export GUM_CHOOSE_HEIGHT=12
  export GUM_CHOOSE_LABEL_DELIMITER="|"   # items as "label|value"

  # filter
  export GUM_FILTER_INDICATOR="❯"
  export GUM_FILTER_INDICATOR_FOREGROUND=$_GM_PRIMARY
  export GUM_FILTER_PROMPT="❯ "
  export GUM_FILTER_PROMPT_FOREGROUND=$_GM_SECONDARY
  export GUM_FILTER_MATCH_FOREGROUND=$_GM_PRIMARY
  export GUM_FILTER_HEADER_FOREGROUND=$_GM_SECONDARY
  export GUM_FILTER_TEXT_FOREGROUND=$_GM_FG
  export GUM_FILTER_HEIGHT=15

  # input
  export GUM_INPUT_PROMPT="❯ "
  export GUM_INPUT_PROMPT_FOREGROUND=$_GM_SECONDARY
  export GUM_INPUT_CURSOR_FOREGROUND=$_GM_PRIMARY

  # confirm
  export GUM_CONFIRM_PROMPT_FOREGROUND=$_GM_SECONDARY
  export GUM_CONFIRM_SELECTED_BACKGROUND=$_GM_PRIMARY
  export GUM_CONFIRM_SELECTED_FOREGROUND=235

  # spin
  export GUM_SPIN_SPINNER="minidot"
  export GUM_SPIN_SPINNER_FOREGROUND=$_GM_PRIMARY
  export GUM_SPIN_TITLE_FOREGROUND=$_GM_SECONDARY

  # pager
  export GUM_PAGER_HELP_FOREGROUND=$_GM_MUTED
  export GUM_PAGER_FOREGROUND=$_GM_FG
}

_gm_header() {
  gum style \
    --border rounded \
    --border-foreground $_GM_PRIMARY \
    --foreground $_GM_SECONDARY \
    --padding "0 1" \
    --bold \
    " $1"
}

_gm_success() { gum style --foreground $_GM_SUCCESS "✔ $1"; }
_gm_warn()    { gum style --foreground $_GM_WARN    "⚠ $1"; }
_gm_error()   { gum style --foreground $_GM_ERROR   "✘ $1"; }
_gm_info()    { gum style --foreground $_GM_SECONDARY "→ $1"; }

# Render a solid filled-background block (lipglass-style) instead of an
# outlined border. Usage: _gm_block <hex-color> [gum style args...] <text>
_gm_block() {
  local hex="$1"; shift
  gum style --background "$hex" --foreground "$_GM_BLOCK_FG_HEX" \
    --bold --padding "1 2" "$@"
}

# Print the git command about to run (for transparency), e.g. _gm_cmd push -u origin main
_gm_cmd() { gum style --foreground $_GM_MUTED "\$ git $*"; }
# Print + run a git action command in one call.
_gm_run() { _gm_cmd "$@"; git "$@"; }

# gum filter, but never fall back to the cwd file browser on empty input.
_gm_filter() {
  local input
  input=$(cat)
  [[ -z "$input" ]] && return 1
  print -r -- "$input" | gum filter "$@"
}

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

_gm_current_branch() {
  git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD
}

_gm_repo_name() {
  basename "$(git rev-parse --show-toplevel 2>/dev/null)"
}

# Lay items read from stdin into a column-major, space-padded grid that fits
# within <width> columns. A single long outlier no longer forces every column
# to match its width — items longer than a cap render on their own full-width
# row below the grid instead, so the grid adapts down to as little as one
# column when items are long/width is small. Usage: _gm_columnize <width>
_gm_columnize() {
  awk -v width="$1" '
    { items[NR]=$0 }
    END {
      if (NR == 0) exit
      gap=2; cap=24
      maxw=0
      for (i=1; i<=NR; i++) {
        len=length(items[i])
        if (len <= cap && len > maxw) maxw=len
      }
      colw=maxw+gap
      ncols=int(width/colw); if (ncols < 1) ncols=1

      m=0
      for (i=1; i<=NR; i++) {
        if (length(items[i]) <= cap) { m++; norm[m]=items[i] }
        else { longn++; longitems[longn]=items[i] }
      }

      if (m > 0) {
        nrows=int((m + ncols - 1) / ncols)
        for (r=0; r<nrows; r++) {
          line=""
          for (c=0; c<ncols; c++) {
            idx=c*nrows + r + 1
            if (idx <= m) {
              s=norm[idx]; line=line s
              pad=colw-length(s); while (pad-- > 0) line=line " "
            }
          }
          gsub(/ +$/, "", line); print line
        }
      }
      for (i=1; i<=longn; i++) print longitems[i]
    }
  '
}

# Render refs (branches/tags) read from stdin as one full-width box per prefix
# group (split on the first <delim>); refs without <delim> go in a "•" box.
# Each box: bold group title + the full ref names laid out in dynamic columns.
# Groups cycle through _GM_BLOCK_PALETTE starting at <palette-offset>, so
# adjacent groups (feature/, fix/, chore/, ...) get visibly different colors.
# Usage: _gm_group_boxes <delim> <palette-offset> <width>
_gm_group_boxes() {
  local delim="$1" offset="${2:-0}" width="${3:-120}"
  local line key
  local -A members
  local -a order

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *"$delim"* ]]; then
      key="${line%%${delim}*}"
    else
      key="•"
    fi
    [[ -z "${members[$key]+x}" ]] && order+=("$key")
    members[$key]+="${line}"$'\n'
  done

  local inner=$(( width - 4 ))   # account for block padding (2) + margin (2)
  (( inner < 10 )) && inner=10

  local content blockw color_hex i=0 palette_len=${#_GM_BLOCK_PALETTE[@]}
  for key in "${order[@]}"; do
    color_hex="${_GM_BLOCK_PALETTE[$(( (offset + i) % palette_len + 1 ))]}"
    gum style --foreground "$color_hex" --bold " $key"
    content=$(echo "${members[$key]%$'\n'}" | _gm_columnize "$inner")
    blockw=$(echo "$content" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')
    (( blockw > inner )) && blockw=$inner
    (( blockw < 1 )) && blockw=1
    # _gm_block's --padding "1 2" adds 4 cols (2 left + 2 right); gum's --width
    # is the total rendered width including padding, so add it back here.
    _gm_block "$color_hex" --width "$(( blockw + 4 ))" "$content"
    echo ""
    (( i++ ))
  done
}

# Detect the prefix groups in the refs on stdin (split on the first <delim>;
# refs without <delim> form the "•" group). If 2+ groups exist, prompt to pick
# one group or All. Echoes the chosen group key, or "__ALL__" when All / when
# there's only a single group. Returns 1 if the user cancels the prompt.
_gm_pick_group() {
  local delim="$1" refs keys ngroups choice
  refs=$(cat)

  keys=$(echo "$refs" | awk -v d="$delim" '
    NF {
      if (index($0,d)) k=substr($0,1,index($0,d)-1); else k="•"
      if (!(k in seen)) { seen[k]=1; print k }
    }')
  ngroups=$(echo "$keys" | grep -c .)

  if (( ngroups <= 1 )); then
    echo "__ALL__"
    return 0
  fi

  # Items must be "label|value" because GUM_CHOOSE_LABEL_DELIMITER is "|";
  # map each bare key to "key|key" so gum accepts it.
  choice=$( { echo "All ($ngroups groups)|__ALL__"; echo "$keys" | sed 's/.*/&|&/'; } \
    | gum choose --header "Show group:")
  [[ -z "$choice" ]] && return 1
  echo "$choice"
}

# Keep only the refs on stdin that belong to <group> (split on <delim>).
# A <group> of "__ALL__" passes everything through unchanged.
_gm_filter_group() {
  local delim="$1" group="$2"
  if [[ "$group" == "__ALL__" ]]; then
    cat
    return
  fi
  awk -v d="$delim" -v g="$group" '
    {
      if (index($0,d)) k=substr($0,1,index($0,d)-1); else k="•"
      if (k==g) print
    }'
}

# ─────────────────────────────────────────────
# Status
# ─────────────────────────────────────────────

_gm_status() {
  _gm_require_repo || return

  local branch ahead behind modified untracked
  branch=$(_gm_current_branch)
  ahead=$(git rev-list @{u}..HEAD 2>/dev/null | wc -l | tr -d ' ')
  behind=$(git rev-list HEAD..@{u} 2>/dev/null | wc -l | tr -d ' ')
  modified=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  untracked=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')

  _gm_header "Status"
  echo ""
  gum style "Branch:    $(gum style --foreground $_GM_PRIMARY "$branch")"
  gum style "Modified:  $(gum style --foreground $_GM_WARN "$modified files")"
  gum style "Untracked: $(gum style --foreground $_GM_SECONDARY "$untracked files")"
  gum style "Ahead:     $(gum style --foreground $_GM_SUCCESS "$ahead")   Behind: $(gum style --foreground $_GM_ERROR "$behind")"
  echo ""

  if gum confirm "View full status?"; then
    git status | gum pager
  fi
}

# ─────────────────────────────────────────────
# Commit
# ─────────────────────────────────────────────

_gm_commit() {
  _gm_require_repo || return

  local branch type msg full_msg git_dir merge_msg_file

  branch=$(_gm_current_branch)
  _gm_header "Commit — $branch"
  echo ""

  # A merge conflict (MERGE_HEAD) or a pending squash (SQUASH_MSG) already has
  # a git-authored message on disk — surface it instead of building a fresh
  # conventional-commit message from scratch, which would silently discard it.
  git_dir=$(git rev-parse --git-dir)
  if git rev-parse -q --verify MERGE_HEAD &>/dev/null; then
    merge_msg_file="$git_dir/MERGE_MSG"
  elif [[ -f "$git_dir/SQUASH_MSG" ]]; then
    merge_msg_file="$git_dir/SQUASH_MSG"
  fi

  if [[ -n "$merge_msg_file" && -f "$merge_msg_file" ]]; then
    msg=$(grep -v '^#' "$merge_msg_file" | grep -v '^[[:space:]]*$' | head -1)
    msg=$(gum input --placeholder "Commit message..." --value "$msg" --width 60)
    [[ -z "$msg" ]] && return 1

    echo ""
    _gm_block "$_GM_BLOCK_HEX" "$msg"
    echo ""

    gum confirm "Commit with this message?" || return 1

    if _gm_run commit -m "$msg"; then
      _gm_success "Committed: $msg"
    else
      _gm_error "Commit failed"
      return 1
    fi
    return
  fi

  type=$(gum choose \
    --header "Select commit type:" \
    " feat|feat" " fix|fix" " docs|docs" " chore|chore" \
    " refactor|refactor" " test|test" " style|style" " ci|ci" \
    " Custom…|__custom__")
  [[ -z "$type" ]] && return 1
  if [[ "$type" == "__custom__" ]]; then
    type=$(gum input --placeholder "Custom type (e.g. wip, release)..." --width 40)
    [[ -z "$type" ]] && return 1
  fi

  msg=$(gum input --placeholder "Commit message..." --width 60)
  [[ -z "$msg" ]] && return 1

  full_msg="$branch | $type: $msg"

  echo ""
  _gm_block "$_GM_BLOCK_HEX" "$full_msg"
  echo ""

  gum confirm "Commit with this message?" || return 1

  if _gm_run commit -m "$full_msg"; then
    _gm_success "Committed: $full_msg"
  else
    _gm_error "Commit failed"
    return 1
  fi
}

# ─────────────────────────────────────────────
# Branch
# ─────────────────────────────────────────────

_gm_branch() {
  _gm_require_repo || return

  local action="$1"
  [[ $# -gt 0 ]] && shift

  # A scope passed as an argument (e.g. 'gg branch create') runs once and exits;
  # the interactive picker loops back to itself after each action.
  if [[ -n "$action" ]]; then
    case "${action:l}" in
      list)     _gm_branch_switch ;;
      view)     _gm_branch_view "$@" ;;
      create)   _gm_branch_create ;;
      rename)   _gm_branch_rename ;;
      delete)   _gm_branch_delete ;;
      "← back"|back) return ;;
      *) _gm_error "Unknown branch action: $action" ;;
    esac
    return
  fi

  while true; do
    action=$(gum choose \
      --header "Branch:" \
      " List|List" " View|View" " Create|Create" " Rename|Rename" " Delete|Delete" " Back|← Back")
    [[ -z "$action" || "${action:l}" == "← back" || "${action:l}" == "back" ]] && return

    case "${action:l}" in
      list)     _gm_branch_switch ;;
      view)     _gm_branch_view ;;
      create)   _gm_branch_create ;;
      rename)   _gm_branch_rename ;;
      delete)   _gm_branch_delete ;;
      *) _gm_error "Unknown branch action: $action" ;;
    esac
  done
}

_gm_branch_switch() {
  local branch dirty stashed
  branch=$(git branch --all \
    | grep -v HEAD \
    | sed 's/^[+* ]*//' \
    | sed 's|remotes/origin/||' \
    | sort -u \
    | _gm_filter --placeholder "Search branch...")
  [[ -z "$branch" ]] && return

  # Uncommitted changes block a checkout — offer to stash them out of the way.
  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$dirty" -gt 0 ]]; then
    if gum confirm "You have uncommitted changes. Stash them before switching?"; then
      _gm_cmd stash push -u -m "gg: switch to $branch"
      gum spin --title "Stashing..." -- git stash push -u -m "gg: switch to $branch" && stashed=1
    fi
  fi

  if ! _gm_run checkout "$branch"; then
    _gm_error "Checkout failed"
    [[ -n "$stashed" ]] && _gm_info "Your changes are stashed — 'git stash pop' to restore."
    return 1
  fi
  _gm_success "Switched to $branch"

  # Bring the stashed changes back onto the new branch if wanted.
  if [[ -n "$stashed" ]] && gum confirm "Restore your stashed changes here (stash pop)?"; then
    _gm_cmd stash pop
    if gum spin --title "Popping stash..." -- git stash pop; then
      _gm_success "Stash applied"
    else
      _gm_warn "Stash pop hit conflicts — resolve them, then 'git stash drop' if needed."
    fi
  fi
}

_gm_branch_create() {
  local name current base from

  name=$(gum input --placeholder "Branch name (e.g. feature/login)" --width 50)
  [[ -z "$name" ]] && return

  current=$(_gm_current_branch)
  from=$(gum choose --header "Create '$name' from:" \
    " Current ($current)|current" " Another branch|other" " Back|← Back")
  [[ -z "$from" || "$from" == "← Back" ]] && return

  if [[ "$from" == "other" ]]; then
    base=$(git branch --all \
      | grep -v HEAD \
      | sed 's/^[+* ]*//' \
      | sed 's|remotes/origin/||' \
      | sort -u \
      | _gm_filter --placeholder "Select base branch...")
    [[ -z "$base" ]] && return
    _gm_run checkout -b "$name" "$base"
    _gm_success "Created branch: $name (from $base)"
  else
    _gm_run checkout -b "$name"
    _gm_success "Created branch: $name (from $current)"
  fi

  if gum confirm "Push branch to remote?"; then
    _gm_cmd push -u origin "$name"
    if gum spin --title "Pushing..." -- git push -u origin "$name"; then
      _gm_success "Pushed $name to origin"
    else
      _gm_error "Push failed"
    fi
  fi
}

_gm_branch_rename() {
  local old new had_upstream

  old=$(git branch \
    | sed 's/^[+* ]*//' \
    | _gm_filter --placeholder "Select branch to rename...")
  [[ -z "$old" ]] && return

  new=$(gum input --placeholder "New name for '$old'" --value "$old" --width 50)
  [[ -z "$new" || "$new" == "$old" ]] && return

  # Note whether the branch tracks a remote before the rename drops it.
  git rev-parse --abbrev-ref --symbolic-full-name "$old@{u}" &>/dev/null 2>&1 && had_upstream=1

  _gm_run branch -m "$old" "$new" || { _gm_error "Rename failed"; return 1; }
  _gm_success "Renamed branch: $old → $new"

  # Remote branches can't be renamed in place — push the new name and drop the
  # old one, then re-track upstream.
  if [[ -n "$had_upstream" ]] && gum confirm "Update remote: push '$new' and delete '$old' on origin?"; then
    _gm_cmd push -u origin "$new"
    if ! gum spin --title "Pushing $new..." -- git push -u origin "$new"; then
      _gm_error "Push of '$new' failed — remote not updated"
      return 1
    fi
    _gm_cmd push origin --delete "$old"
    if gum spin --title "Deleting old remote branch..." -- git push origin --delete "$old"; then
      _gm_success "Remote updated: origin/$old → origin/$new"
    else
      _gm_warn "Pushed '$new' but failed to delete old remote branch '$old'"
    fi
  fi
}

_gm_branch_delete() {
  local scope branch

  while true; do
    scope=$(gum choose --header "Delete from:" \
      " Local|Local" " Remote|Remote" " All|All" " Back|← Back")
    [[ -z "$scope" || "${scope:l}" == "← back" || "${scope:l}" == "back" ]] && return

    case "${scope:l}" in
      local)
        branch=$(git branch \
          | grep -v '^\*' \
          | sed 's/^[+* ]*//' \
          | _gm_filter --placeholder "Select local branch to delete...")
        [[ -z "$branch" ]] && continue
        _gm_branch_delete_local "$branch" && _gm_branch_delete_remote_prompt "$branch"
        ;;
      remote)
        branch=$(git branch -r \
          | grep -v HEAD | sed 's|^[[:space:]]*origin/||' \
          | sort -u \
          | _gm_filter --placeholder "Select remote branch to delete...")
        [[ -z "$branch" ]] && continue
        _gm_branch_delete_remote "$branch"
        ;;
      all)
        local local_branches remote_branches combined selection kind
        local_branches=$(git branch | grep -v '^\*' | sed 's/^[+* ]*//')
        remote_branches=$(git branch -r | grep -v HEAD | sed 's|^[[:space:]]*origin/||' | sort -u)
        combined=$(
          [[ -n "$local_branches" ]] && printf "%s\n" "$local_branches" | sed 's/^/[local]  /'
          [[ -n "$remote_branches" ]] && printf "%s\n" "$remote_branches" | sed 's/^/[remote] /'
        )
        selection=$(echo "$combined" | _gm_filter --placeholder "Select branch to delete...")
        [[ -z "$selection" ]] && continue

        kind="${selection%%]*}]"
        branch="${selection#*] }"; branch="${branch## }"

        if [[ "$kind" == "[local]" ]]; then
          _gm_branch_delete_local "$branch" && _gm_branch_delete_remote_prompt "$branch"
        else
          _gm_branch_delete_remote "$branch"
        fi
        ;;
    esac
  done
}

_gm_branch_delete_local() {
  local branch="$1"
  gum confirm "Delete local branch '$branch'?" || return 1

  if _gm_run branch -d "$branch"; then
    _gm_success "Deleted local branch: $branch"
  else
    _gm_error "Local delete failed (use --force?)"
    return 1
  fi
}

_gm_branch_delete_remote_prompt() {
  local branch="$1"
  gum confirm "Delete remote branch '$branch' too?" && _gm_branch_delete_remote "$branch" --no-confirm
}

_gm_branch_delete_remote() {
  local branch="$1"
  if [[ "$2" != "--no-confirm" ]]; then
    gum confirm "Delete remote branch '$branch'?" || return 1
  fi

  _gm_cmd push origin --delete "$branch"
  if gum spin --title "Deleting remote..." -- git push origin --delete "$branch"; then
    _gm_success "Deleted remote branch: $branch"
  else
    _gm_error "Remote delete failed"
    return 1
  fi
}

_gm_branch_view() {
  local scope="$1" current local_branches remote_branches width group

  if [[ -z "$scope" ]]; then
    scope=$(gum choose --header "List branches:" \
      " All|All" " Local|Local" " Remote|Remote" " Back|← Back")
  fi
  [[ -z "$scope" || "${scope:l}" == "← back" || "${scope:l}" == "back" ]] && return

  current=$(_gm_current_branch)
  width=${COLUMNS:-0}; (( width < 20 )) && width=$(tput cols 2>/dev/null || echo 120)

  [[ "${scope:l}" == "local"  || "${scope:l}" == "all" ]] && \
    local_branches=$(git branch | sed 's/^[+* ]*//')
  [[ "${scope:l}" == "remote" || "${scope:l}" == "all" ]] && \
    remote_branches=$(git branch -r | grep -v HEAD | sed 's|^[[:space:]]*origin/||')

  # Offer a group (e.g. feature/, fix/) across whatever is being shown.
  group=$(printf "%s\n%s\n" "$local_branches" "$remote_branches" | _gm_pick_group "/") || return

  {
    if [[ -n "$local_branches" ]]; then
      gum style --foreground $_GM_PRIMARY --bold " LOCAL  (current: $current)"
      echo ""
      echo "$local_branches" | _gm_filter_group "/" "$group" | _gm_group_boxes "/" 0 $width
    fi

    [[ -n "$local_branches" && -n "$remote_branches" ]] && echo ""

    if [[ -n "$remote_branches" ]]; then
      gum style --foreground $_GM_SECONDARY --bold " REMOTE (origin)"
      echo ""
      echo "$remote_branches" | _gm_filter_group "/" "$group" | _gm_group_boxes "/" 4 $width
    fi
  } | gum pager
}

# ─────────────────────────────────────────────
# Tag
# ─────────────────────────────────────────────

_gm_tag() {
  _gm_require_repo || return

  local action="$1"

  if [[ -n "$action" ]]; then
    case "${action:l}" in
      list)            _gm_tag_list ;;
      view)            _gm_tag_view ;;
      add|create)      _gm_tag_create ;;
      remove|delete)   _gm_tag_delete ;;
      "← back"|back) return ;;
      *) _gm_error "Unknown tag action: $action" ;;
    esac
    return
  fi

  while true; do
    action=$(gum choose \
      --header "Tag:" \
      " List|List" " View|View" " Add|Add" " Remove|Remove" " Back|← Back")
    [[ -z "$action" || "${action:l}" == "← back" || "${action:l}" == "back" ]] && return

    case "${action:l}" in
      list)            _gm_tag_list ;;
      view)            _gm_tag_view ;;
      add|create)      _gm_tag_create ;;
      remove|delete)   _gm_tag_delete ;;
      *) _gm_error "Unknown tag action: $action" ;;
    esac
  done
}

_gm_tag_create() {
  local tag
  tag=$(gum input --placeholder "Tag name (e.g. v1.2.3 or prod=711.4.3)" --width 50)
  [[ -z "$tag" ]] && return

  echo ""
  _gm_block "$_GM_BLOCK_HEX" "Tag: $tag"
  echo ""
  gum confirm "Create tag '$tag'?" || return

  if ! _gm_run tag "$tag"; then
    _gm_error "Tag creation failed"
    return 1
  fi
  _gm_success "Created tag: $tag"

  if gum confirm "Push tag to remote?"; then
    _gm_cmd push origin "$tag"
    if gum spin --title "Pushing tag..." -- git push origin "$tag"; then
      _gm_success "Pushed tag: $tag"
    else
      _gm_error "Push failed"
    fi
  fi
}

_gm_tag_delete() {
  local tag
  tag=$(git tag --sort=-v:refname | _gm_filter --no-fuzzy-sort --placeholder "Select tag to delete...")
  [[ -z "$tag" ]] && return

  gum confirm "Delete local tag '$tag'?" || return

  if ! _gm_run tag -d "$tag"; then
    _gm_error "Local tag delete failed"
    return 1
  fi
  _gm_success "Deleted local tag: $tag"

  if gum confirm "Delete remote tag '$tag' too?"; then
    _gm_cmd push origin --delete "$tag"
    if gum spin --title "Deleting remote tag..." -- git push origin --delete "$tag"; then
      _gm_success "Deleted remote tag: $tag"
    else
      _gm_error "Remote tag delete failed"
    fi
  fi
}

# Quick pick-and-go, mirroring _gm_branch_switch: fuzzy-pick a tag and check
# it out (detached HEAD), stashing uncommitted changes out of the way first.
_gm_tag_list() {
  local tag dirty stashed
  tag=$(git tag --sort=-v:refname | _gm_filter --no-fuzzy-sort --placeholder "Search tag...")
  [[ -z "$tag" ]] && return

  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$dirty" -gt 0 ]]; then
    if gum confirm "You have uncommitted changes. Stash them before checkout?"; then
      _gm_cmd stash push -u -m "gg: checkout tag $tag"
      gum spin --title "Stashing..." -- git stash push -u -m "gg: checkout tag $tag" && stashed=1
    fi
  fi

  if ! _gm_run checkout "$tag"; then
    _gm_error "Checkout failed"
    [[ -n "$stashed" ]] && _gm_info "Your changes are stashed — 'git stash pop' to restore."
    return 1
  fi
  _gm_success "Checked out tag: $tag (detached HEAD)"

  if [[ -n "$stashed" ]] && gum confirm "Restore your stashed changes here (stash pop)?"; then
    _gm_cmd stash pop
    if gum spin --title "Popping stash..." -- git stash pop; then
      _gm_success "Stash applied"
    else
      _gm_warn "Stash pop hit conflicts — resolve them, then 'git stash drop' if needed."
    fi
  fi
}

# Read-only browse of all tags, grouped by prefix into colored blocks (matches
# _gm_branch_view / _gm_worktree_view).
_gm_tag_view() {
  local tags width group
  tags=$(git tag --sort=-v:refname)

  width=${COLUMNS:-0}; (( width < 20 )) && width=$(tput cols 2>/dev/null || echo 120)

  # Offer a group (e.g. prod=, stage=) when tags span more than one prefix.
  group=$(echo "$tags" | _gm_pick_group "=") || return

  {
    gum style --foreground $_GM_PRIMARY --bold " TAGS"
    echo ""
    echo "$tags" | _gm_filter_group "=" "$group" | _gm_group_boxes "=" 0 $width
  } | gum pager
}

# ─────────────────────────────────────────────
# Worktree
# ─────────────────────────────────────────────

_gm_worktree() {
  _gm_require_repo || return

  local action="$1"

  if [[ -n "$action" ]]; then
    case "${action:l}" in
      add|create)      _gm_worktree_create ;;
      remove|delete)   _gm_worktree_delete ;;
      list)     _gm_worktree_open ;;
      view)     _gm_worktree_view ;;
      "← back"|back) return ;;
      *) _gm_error "Unknown worktree action: $action" ;;
    esac
    return
  fi

  while true; do
    action=$(gum choose \
      --header "Worktree:" \
      " List|List" " View|View" " Add|Add" " Remove|Remove" " Back|← Back")
    [[ -z "$action" || "${action:l}" == "← back" || "${action:l}" == "back" ]] && return

    case "${action:l}" in
      add|create)      _gm_worktree_create ;;
      remove|delete)   _gm_worktree_delete ;;
      list)     _gm_worktree_open ;;
      view)     _gm_worktree_view ;;
      *) _gm_error "Unknown worktree action: $action" ;;
    esac
  done
}

_gm_worktree_create() {
  local scope branch
  scope=$(gum choose --header "Worktree from:" \
    " Local branch|Local branch" " Remote branch|Remote branch" " Back|← Back")
  [[ -z "$scope" || "$scope" == "← Back" ]] && return

  if [[ "$scope" == "Local branch" ]]; then
    branch=$(git branch \
      | grep -v HEAD \
      | sed 's/^[+* ]*//' \
      | _gm_filter --placeholder "Select local branch...")
  else
    branch=$(git branch -r \
      | grep -v HEAD \
      | sed 's|^[[:space:]]*origin/||' \
      | sort -u \
      | _gm_filter --placeholder "Select remote branch...")
  fi
  [[ -z "$branch" ]] && return

  _gm_worktree_create_for "$branch"
}

_gm_worktree_create_for() {
  local branch="$1"
  # NOTE: do not name a local var "path" — in zsh it is tied to $PATH.
  local repo_root repo_name parent safe_branch base name wt_path

  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  repo_name=$(basename "$repo_root")
  parent=$(dirname "$repo_root")
  safe_branch=$(echo "$branch" | tr '/' '-')
  # Worktrees are always gathered in a sibling <repo>.worktree/ folder,
  # anchored to the repo root so it's stable regardless of the cwd.
  base="${parent}/${repo_name}.worktree"

  # Only ask for the folder name; the parent dir is fixed.
  name=$(gum input \
    --placeholder "Worktree name" \
    --value "${safe_branch}-view" \
    --width 40)
  [[ -z "$name" ]] && return
  wt_path="${base}/${name}"

  echo ""
  _gm_block "$_GM_BLOCK_HEX" \
    "Branch: $branch
Name:   $name
Path:   $wt_path"
  echo ""

  gum confirm "Create worktree?" || return

  # Existing local branch → check it out; remote-only → create a tracking
  # local branch; otherwise create a fresh branch.
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    _gm_run worktree add "$wt_path" "$branch"
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    _gm_run worktree add "$wt_path" -b "$branch" "origin/$branch"
  else
    _gm_run worktree add "$wt_path" -b "$branch"
  fi
  _gm_success "Worktree created at $wt_path"

  local open_action
  open_action=$(gum choose --header "Open worktree in:" \
    " Shell|shell" \
    " Open Worktree With...|with" \
    " Skip|skip")

  case "$open_action" in
    shell) cd "$wt_path" && exec $SHELL ;;
    with)  _gm_open_target "$wt_path" ;;
    skip)  ;;
  esac
}

_gm_worktree_delete() {
  local selected wt_path branch worktrees

  worktrees=$(git worktree list | tail -n +2)
  [[ -z "$worktrees" ]] && { _gm_warn "No additional worktrees."; return; }

  selected=$(echo "$worktrees" | _gm_filter --placeholder "Select worktree to delete...")
  [[ -z "$selected" ]] && return

  wt_path=$(echo "$selected" | awk '{print $1}')
  branch=$(echo "$selected" | awk '{print $3}' | tr -d '[]')

  echo ""
  _gm_block "$_GM_BLOCK_ERROR_HEX" \
    "Branch: $branch
Path:   $wt_path"
  echo ""

  gum confirm "Remove worktree at '$wt_path'?" || return

  _gm_run worktree remove "$wt_path"
  _gm_success "Removed worktree: $wt_path"
}

_gm_worktree_open() {
  local selected wt_path branch action worktrees

  worktrees=$(git worktree list)
  [[ -z "$worktrees" ]] && { _gm_warn "No worktrees found."; return; }

  selected=$(echo "$worktrees" | _gm_filter --placeholder "Select worktree to open...")
  [[ -z "$selected" ]] && return

  wt_path=$(echo "$selected" | awk '{print $1}')
  branch=$(echo "$selected" | awk '{print $3}' | tr -d '[]')

  action=$(gum choose \
    --header "Open '$branch' in:" \
    " Shell|shell" \
    " Open With...|with" \
    " Copy Path|copy")

  case "$action" in
    shell) cd "$wt_path" && exec $SHELL ;;
    with)  _gm_open_target "$wt_path" ;;
    copy)  echo -n "$wt_path" | pbcopy && _gm_success "Path copied to clipboard" ;;
  esac
}

_gm_worktree_view() {
  {
    gum style --foreground $_GM_PRIMARY --bold " WORKTREES"
    git worktree list | while read -r line; do
      local wpath wbranch
      wpath=$(echo "$line" | awk '{print $1}')
      wbranch=$(echo "$line" | awk '{print $3}' | tr -d '[]')
      gum style "  $(gum style --foreground $_GM_SECONDARY "$wbranch")   $(gum style --foreground $_GM_MUTED "$wpath")"
    done
  } | gum pager
}

# ─────────────────────────────────────────────
# Refs  (Branch / Tag / Worktree in one menu)
# ─────────────────────────────────────────────

_gm_refs() {
  _gm_require_repo || return

  local choice
  while true; do
    choice=$(gum choose --header "Refs:" \
      " Branch|Branch" " Tag|Tag" " Worktree|Worktree" " Search|Search" " Back|← Back")
    [[ -z "$choice" || "${choice:l}" == "← back" || "${choice:l}" == "back" ]] && return

    case "$choice" in
      Branch)   _gm_branch ;;
      Tag)      _gm_tag ;;
      Worktree) _gm_worktree ;;
      Search)   _gm_search ;;
    esac
  done
}

# ─────────────────────────────────────────────
# Search
# ─────────────────────────────────────────────

_gm_search() {
  _gm_require_repo || return

  local scope="$1"

  # A scope passed as an argument (e.g. 'gg search commits') runs once and exits;
  # the interactive picker loops back to itself after each action.
  if [[ -n "$scope" ]]; then
    case "${scope:l}" in
      commits)  _gm_search_commits ;;
      branches) _gm_search_branches ;;
      tags)     _gm_search_tags ;;
      *) _gm_error "Unknown search scope: $scope" ;;
    esac
    return
  fi

  while true; do
    scope=$(gum choose --header "Search:" \
      " Commits|Commits" " Branches|Branches" " Tags|Tags" " Back|← Back")
    [[ -z "$scope" || "${scope:l}" == "← back" || "${scope:l}" == "back" ]] && return

    case "${scope:l}" in
      commits)  _gm_search_commits ;;
      branches) _gm_search_branches ;;
      tags)     _gm_search_tags ;;
      *) _gm_error "Unknown search scope: $scope" ;;
    esac
  done
}

_gm_search_commits() {
  local selected hash action

  while true; do
    selected=$(git log --oneline --all | _gm_filter --placeholder "Search commits...")
    [[ -z "$selected" ]] && return

    hash=$(echo "$selected" | awk '{print $1}')

    action=$(gum choose --header "Action for $hash:" \
      " Show Diff|Show Diff" " Show Files|Show Files" " Checkout|Checkout" " Copy Hash|Copy Hash" " Back|← Back")
    [[ -z "$action" || "$action" == "← Back" ]] && continue

    case "$action" in
      "Show Diff")  git show "$hash" | gum pager ;;
      "Show Files") git show --name-only "$hash" | gum pager ;;
      Checkout)
        if _gm_run checkout "$hash"; then
          _gm_success "Checked out $hash (detached HEAD)"
        else
          _gm_error "Checkout failed"
        fi
        ;;
      "Copy Hash")  echo -n "$hash" | pbcopy && _gm_success "Hash copied: $hash" ;;
    esac
  done
}

_gm_search_branches() {
  local branch action

  while true; do
    branch=$(git branch -a \
      | sed 's/^[+* ]*//' \
      | _gm_filter --placeholder "Search branches...")
    [[ -z "$branch" ]] && return

    action=$(gum choose --header "Action for '$branch':" \
      " Checkout|Checkout" " Show Commits|Show Commits" " Copy Name|Copy Name" " Back|← Back")
    [[ -z "$action" || "$action" == "← Back" ]] && continue

    case "$action" in
      Checkout)       _gm_run checkout "${branch#remotes/origin/}" ;;
      "Show Commits") git log --oneline "$branch" | gum pager ;;
      "Copy Name")    echo -n "$branch" | pbcopy && _gm_success "Copied: $branch" ;;
    esac
  done
}

_gm_search_tags() {
  local tag action

  while true; do
    tag=$(git tag --sort=-v:refname | _gm_filter --no-fuzzy-sort --placeholder "Search tags...")
    [[ -z "$tag" ]] && return

    action=$(gum choose --header "Action for '$tag':" \
      " Show Details|Show Details" " Checkout|Checkout" " Copy Name|Copy Name" " Back|← Back")
    [[ -z "$action" || "$action" == "← Back" ]] && continue

    case "$action" in
      "Show Details") git show "$tag" | gum pager ;;
      Checkout)       _gm_run checkout "$tag" ;;
      "Copy Name")    echo -n "$tag" | pbcopy && _gm_success "Copied: $tag" ;;
    esac
  done
}

# ─────────────────────────────────────────────
# Fetch / Pull / Push
# ─────────────────────────────────────────────

_gm_fetch() {
  _gm_require_repo || return

  local scope="$1"
  if [[ -z "$scope" ]]; then
    scope=$(gum choose --header "Fetch:" \
      " Origin|Origin" " All Remotes|All Remotes" " Back|← Back")
  fi
  [[ -z "$scope" || "${scope:l}" == "← back" || "${scope:l}" == "back" ]] && return

  if [[ "${scope:l}" != "all remotes" && "${scope:l}" != "all" ]]; then
    _gm_cmd fetch --prune
    if gum spin --title "Fetching origin..." -- git fetch --prune; then
      _gm_success "Fetch complete"
    else
      _gm_error "Fetch failed"
      return 1
    fi
  else
    _gm_cmd fetch --all --prune
    if gum spin --title "Fetching all remotes..." -- git fetch --all --prune; then
      _gm_success "Fetch complete"
    else
      _gm_error "Fetch failed"
      return 1
    fi
  fi
}

_gm_pull() {
  _gm_require_repo || return

  local mode="$1"
  if [[ -z "$mode" ]]; then
    mode=$(gum choose --header "Pull:" \
      " Rebase|Rebase" " Merge|Merge" " Back|← Back")
  fi
  [[ -z "$mode" || "${mode:l}" == "← back" || "${mode:l}" == "back" ]] && return

  local tmpout out
  tmpout=$(mktemp)

  if [[ "${mode:l}" == "rebase" ]]; then
    _gm_cmd pull --rebase
    if gum spin --title "Pulling (rebase)..." -- zsh -c "git pull --rebase > '$tmpout' 2>&1"; then
      out=$(<"$tmpout"); rm -f "$tmpout"
      [[ -n "$out" ]] && echo "$out"
      if echo "$out" | grep -qi "already up to date"; then
        _gm_info "Already up to date."
      else
        _gm_success "Pull complete"
      fi
    else
      out=$(<"$tmpout"); rm -f "$tmpout"
      [[ -n "$out" ]] && echo "$out"
      _gm_error "Pull failed — resolve conflicts or 'git rebase --abort'"
      return 1
    fi
  else
    _gm_cmd pull
    if gum spin --title "Pulling (merge)..." -- zsh -c "git pull > '$tmpout' 2>&1"; then
      out=$(<"$tmpout"); rm -f "$tmpout"
      [[ -n "$out" ]] && echo "$out"
      if echo "$out" | grep -qi "already up to date"; then
        _gm_info "Already up to date."
      else
        _gm_success "Pull complete"
      fi
    else
      out=$(<"$tmpout"); rm -f "$tmpout"
      [[ -n "$out" ]] && echo "$out"
      _gm_error "Pull failed — resolve conflicts or 'git merge --abort'"
      return 1
    fi
  fi

  # A rebase/merge pull can leave local commits ahead of the remote — offer
  # to push them now.
  local ahead
  ahead=$(git rev-list @{u}..HEAD 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$ahead" -gt 0 ]]; then
    echo ""
    if gum confirm "$ahead local commit(s) ahead of remote. Push now?"; then
      _gm_push
    else
      _gm_info "Not pushed."
    fi
  fi
}

_gm_push() {
  _gm_require_repo || return

  local mode="$1" branch
  local -a push_target
  if [[ -z "$mode" ]]; then
    mode=$(gum choose --header "Push:" \
      " Push|Push" " Force With Lease|Force With Lease" " Back|← Back")
  fi
  [[ -z "$mode" || "${mode:l}" == "← back" || "${mode:l}" == "back" ]] && return

  _gm_prefer_main_branch || return 1
  branch=$(_gm_current_branch)
  if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} &>/dev/null 2>&1; then
    _gm_ensure_origin || return
    push_target=( -u origin "$branch" )
  fi

  if [[ "${mode:l}" != "force with lease" && "${mode:l}" != "force" ]]; then
    _gm_cmd push "${push_target[@]}"
    if gum spin --title "Pushing..." -- git push "${push_target[@]}"; then
      _gm_success "Push complete"
    else
      _gm_error "Push failed"
      return 1
    fi
  else
    gum confirm "Force push with lease? This rewrites remote history." || return
    _gm_cmd push --force-with-lease "${push_target[@]}"
    if gum spin --title "Force pushing..." -- git push --force-with-lease "${push_target[@]}"; then
      _gm_success "Push complete"
    else
      _gm_error "Force push failed (lease rejected — remote moved, fetch and retry)"
      return 1
    fi
  fi
}

# ─────────────────────────────────────────────
# Integrate  (Merge / Rebase in one menu)
# ─────────────────────────────────────────────

_gm_integrate() {
  _gm_require_repo || return

  local choice
  while true; do
    choice=$(gum choose --header "Sync:" \
      " Fetch|Fetch" \
      " Pull|Pull" \
      " Push|Push" \
      " Merge|Merge" \
      " Rebase|Rebase" \
      " Back|← Back")
    [[ -z "$choice" || "${choice:l}" == "← back" || "${choice:l}" == "back" ]] && return

    case "$choice" in
      Fetch)  _gm_fetch ;;
      Pull)   _gm_pull ;;
      Push)   _gm_push ;;
      Merge)  _gm_merge ;;
      Rebase) _gm_rebase ;;
    esac
  done
}

# ─────────────────────────────────────────────
# Merge  (merge another branch into the current one)
# ─────────────────────────────────────────────

_gm_merge() {
  _gm_require_repo || return

  local current source="$1" scope mode
  current=$(_gm_current_branch)
  _gm_header "Merge into $current"
  echo ""

  if [[ -z "$source" ]]; then
    scope=$(gum choose --header "Merge from:" \
      " Local|Local" " Remote|Remote" " All|All" " Back|← Back")
    [[ -z "$scope" || "${scope:l}" == "← back" || "${scope:l}" == "back" ]] && return

    case "${scope:l}" in
      local)
        source=$(git branch --sort=-committerdate \
          | grep -v HEAD | sed 's/^[+* ]*//' \
          | grep -vx "$current" \
          | _gm_filter --placeholder "Search branch to merge into $current...") ;;
      remote)
        source=$(git branch -r --sort=-committerdate \
          | grep -v HEAD | sed 's|^[[:space:]]*origin/||' \
          | grep -vx "$current" \
          | _gm_filter --placeholder "Search remote branch to merge into $current...") ;;
      all)
        source=$(git branch --all --sort=-committerdate \
          | grep -v HEAD | sed 's/^[+* ]*//' | sed 's|remotes/origin/||' \
          | grep -vx "$current" | awk '!seen[$0]++' \
          | _gm_filter --placeholder "Search branch to merge into $current...") ;;
    esac
  fi
  [[ -z "$source" ]] && return

  mode=$(gum choose --header "Merge mode:" \
    " Default|Default" " No-FF|No-FF" " Squash|Squash" " Back|← Back")
  [[ -z "$mode" || "${mode:l}" == "← back" || "${mode:l}" == "back" ]] && return

  echo ""
  _gm_block "$_GM_BLOCK_HEX" \
    "Merge: $source → $current
Mode:  $mode"
  echo ""
  gum confirm "Merge '$source' into '$current'?" || return

  _gm_run_merge "$mode" "$source" "$current"
}

# Run the merge in <mode> and handle every outcome. Extra args (e.g.
# --allow-unrelated-histories) are passed straight to git merge, which is how
# the unrelated-histories retry re-enters without duplicating the mode logic.
_gm_run_merge() {
  local mode="$1" source="$2" current="$3"; shift 3
  local out rc

  case "${mode:l}" in
    no-ff)  _gm_cmd merge --no-ff "$@" "$source"; out=$(git merge --no-ff "$@" "$source" 2>&1); rc=$? ;;
    squash) _gm_cmd merge --squash "$@" "$source"; out=$(git merge --squash "$@" "$source" 2>&1); rc=$? ;;
    *)      _gm_cmd merge "$@" "$source"; out=$(git merge "$@" "$source" 2>&1); rc=$? ;;
  esac
  [[ -n "$out" ]] && echo "$out"

  if [[ $rc -eq 0 ]]; then
    if echo "$out" | grep -qi "already up to date"; then
      _gm_info "'$current' is already up to date with '$source' — nothing to merge."
    elif [[ "${mode:l}" == "squash" ]]; then
      _gm_info "Squashed '$source' — changes staged, commit when ready."
    else
      _gm_success "Merged $source into $current"
      echo ""
      if gum confirm "Push merged branch to remote now?"; then
        _gm_push
      else
        _gm_info "Merged but not pushed."
      fi
    fi
    return 0
  fi

  # A real conflict leaves a merge in progress (MERGE_HEAD / unmerged files);
  # only then can the user abort or resolve. Anything else (e.g. unrelated
  # histories) failed before the merge started — there is nothing to abort.
  if git rev-parse -q --verify MERGE_HEAD &>/dev/null 2>&1 || [[ -n "$(git ls-files -u 2>/dev/null)" ]]; then
    _gm_error "Merge hit conflicts."
    if gum confirm "Abort the merge?"; then
      _gm_run merge --abort
      _gm_warn "Merge aborted."
    else
      _gm_info "Resolve conflicts, then commit to finish the merge."
    fi
    return 1
  fi

  if echo "$out" | grep -qi "unrelated histories"; then
    _gm_warn "'$source' and '$current' have unrelated histories (no common commit)."
    if gum confirm "Merge anyway with --allow-unrelated-histories?"; then
      _gm_run_merge "$mode" "$source" "$current" --allow-unrelated-histories
      return $?
    fi
    _gm_info "Merge cancelled."
    return 1
  fi

  _gm_error "Merge failed — see output above."
  return 1
}

# ─────────────────────────────────────────────
# Rebase  (rebase the current branch onto another)
# ─────────────────────────────────────────────

_gm_rebase() {
  _gm_require_repo || return

  local current onto="$1" scope
  current=$(_gm_current_branch)
  _gm_header "Rebase $current"
  echo ""

  if [[ -z "$onto" ]]; then
    scope=$(gum choose --header "Rebase onto:" \
      " Local|Local" " Remote|Remote" " All|All" " Back|← Back")
    [[ -z "$scope" || "${scope:l}" == "← back" || "${scope:l}" == "back" ]] && return

    case "${scope:l}" in
      local)
        onto=$(git branch --sort=-committerdate \
          | grep -v HEAD | sed 's/^[+* ]*//' \
          | grep -vx "$current" \
          | _gm_filter --placeholder "Rebase $current onto...") ;;
      remote)
        onto=$(git branch -r --sort=-committerdate \
          | grep -v HEAD | sed 's|^[[:space:]]*origin/||' \
          | grep -vx "$current" \
          | _gm_filter --placeholder "Rebase $current onto...") ;;
      all)
        onto=$(git branch --all --sort=-committerdate \
          | grep -v HEAD | sed 's/^[+* ]*//' | sed 's|remotes/origin/||' \
          | grep -vx "$current" | awk '!seen[$0]++' \
          | _gm_filter --placeholder "Rebase $current onto...") ;;
    esac
  fi
  [[ -z "$onto" ]] && return

  echo ""
  _gm_block "$_GM_BLOCK_HEX" \
    "Rebase: $current onto $onto"
  echo ""
  gum confirm "Rebase '$current' onto '$onto'?" || return

  local out rc
  _gm_cmd rebase "$onto"
  out=$(git rebase "$onto" 2>&1); rc=$?
  [[ -n "$out" ]] && echo "$out"

  if [[ $rc -eq 0 ]]; then
    if echo "$out" | grep -qi "up to date"; then
      _gm_info "'$current' is already up to date with '$onto' — nothing to rebase."
    else
      _gm_success "Rebased $current onto $onto"
      echo ""
      if gum confirm "Push rebased branch to remote now?"; then
        _gm_push
      else
        _gm_info "Rebased but not pushed."
      fi
    fi
  else
    _gm_error "Rebase hit conflicts."
    if gum confirm "Abort the rebase?"; then
      _gm_run rebase --abort
      _gm_warn "Rebase aborted."
    else
      _gm_info "Resolve conflicts, then 'git rebase --continue' to finish."
    fi
  fi
}

# ─────────────────────────────────────────────
# Stage + Commit  (add . → commit, no push)
# ─────────────────────────────────────────────

_gm_stage_commit() {
  _gm_require_repo || return

  local action
  while true; do
    action=$(gum choose \
      --header "Changes:" \
      " Add|Add" \
      " Remove from stage|Unstage" \
      " Commit|Commit" \
      " Push|Push" \
      " Status|Status" \
      " Back|← Back")
    [[ -z "$action" || "$action" == "← Back" ]] && return

    case "$action" in
      Add)
        _gm_add
        ;;
      Unstage)
        _gm_unstage
        ;;
      Commit)
        _gm_commit_menu
        ;;
      Push)
        _gm_push
        ;;
      Status)
        _gm_status
        ;;
    esac
  done
}

_gm_add() {
  local scope staged selected

  scope=$(gum choose --header "Add:" \
    " All (stage every change)|All" \
    " Select files|Select" \
    " Back|← Back")
  [[ -z "$scope" || "$scope" == "← Back" ]] && return

  if [[ "$scope" == "All" ]]; then
    _gm_run add -A
  else
    local files
    files=$(git status --porcelain 2>/dev/null | cut -c4-)
    if [[ -z "$files" ]]; then
      _gm_warn "Nothing to stage — working tree clean."
      return
    fi
    selected=$(echo "$files" | gum filter --no-limit --placeholder "Select files to stage (TAB to multi-select)...")
    [[ -z "$selected" ]] && return
    _gm_cmd add "$selected"
    echo "$selected" | xargs git add
  fi

  staged=$(git diff --cached --name-only | wc -l | tr -d ' ')
  if [[ "$staged" -eq 0 ]]; then
    _gm_warn "Nothing to stage — working tree clean."
  else
    _gm_success "Staged $staged file(s)"
  fi
}

_gm_commit_menu() {
  local action
  action=$(gum choose --header "Commit:" \
    " Commit (staged files only)|Commit" \
    " Undo Last Commit|Undo" \
    " Back|← Back")
  [[ -z "$action" || "$action" == "← Back" ]] && return

  case "$action" in
    Commit) _gm_commit ;;
    Undo)   _gm_undo_commit ;;
  esac
}

_gm_unstage() {
  local files selected

  files=$(git diff --cached --name-only 2>/dev/null)
  if [[ -z "$files" ]]; then
    _gm_warn "Nothing is staged."
    return 1
  fi

  selected=$(echo "$files" | gum filter --no-limit --placeholder "Select files to unstage (TAB to multi-select)...")
  [[ -z "$selected" ]] && return

  _gm_cmd restore --staged "$selected"
  echo "$selected" | xargs git restore --staged
  _gm_success "Unstaged selected file(s)"
}

_gm_undo_commit() {
  local last mode

  last=$(git log -1 --oneline 2>/dev/null)
  if [[ -z "$last" ]]; then
    _gm_warn "No commits to undo."
    return 1
  fi

  _gm_block "$_GM_BLOCK_WARN_HEX" "Last commit: $last"
  echo ""

  mode=$(gum choose \
    --header "Undo mode:" \
    " Soft (keep changes staged)|soft" \
    " Mixed (keep changes unstaged)|mixed" \
    " Hard (discard all changes)|hard")
  [[ -z "$mode" ]] && return

  if [[ "$mode" == "hard" ]]; then
    gum confirm "Hard reset will permanently discard all changes from this commit. Continue?" || return
  fi

  _gm_run reset --"$mode" HEAD~1
  _gm_success "Undid last commit ($mode)"
}

# ─────────────────────────────────────────────
# History  (Log / Reset / Restore)
# ─────────────────────────────────────────────

_gm_history() {
  _gm_require_repo || return

  local action
  while true; do
    action=$(gum choose \
      --header "History:" \
      " Log (follow a file)|Log" \
      " Reset (to any commit)|Reset" \
      " Restore (file from commit)|Restore" \
      " Back|← Back")
    [[ -z "$action" || "$action" == "← Back" ]] && return

    case "$action" in
      Log)     _gm_log_follow ;;
      Reset)   _gm_reset_to ;;
      Restore) _gm_restore_file ;;
    esac
  done
}

_gm_log_follow() {
  local file
  file=$(git ls-files | _gm_filter --placeholder "Select file to follow...")
  [[ -z "$file" ]] && return
  git log --follow --oneline -- "$file" | gum pager
}

_gm_reset_to() {
  local commit mode

  commit=$(git log --oneline -50 | _gm_filter --placeholder "Select commit to reset to...")
  [[ -z "$commit" ]] && return
  commit=$(echo "$commit" | awk '{print $1}')

  _gm_block "$_GM_BLOCK_WARN_HEX" \
    "Reset HEAD to: $(git log -1 --oneline "$commit")"
  echo ""

  mode=$(gum choose --header "Reset mode:" \
    " Soft (keep changes staged)|soft" \
    " Mixed (keep changes unstaged)|mixed" \
    " Hard (discard all changes)|hard")
  [[ -z "$mode" ]] && return

  if [[ "$mode" == "hard" ]]; then
    gum confirm "Hard reset will permanently discard everything after this commit. Continue?" || return
  fi

  if _gm_run reset --"$mode" "$commit"; then
    _gm_success "Reset to $commit ($mode)"
  else
    _gm_error "Reset failed"
  fi
}

_gm_restore_file() {
  local commit files selected

  commit=$(git log --oneline -50 | _gm_filter --placeholder "Select commit to restore files from...")
  [[ -z "$commit" ]] && return
  commit=$(echo "$commit" | awk '{print $1}')

  files=$(git ls-tree -r --name-only "$commit")
  [[ -z "$files" ]] && { _gm_warn "No files in that commit."; return; }

  selected=$(echo "$files" | gum filter --no-limit --placeholder "Select files to restore from $commit (TAB to multi-select)...")
  [[ -z "$selected" ]] && return

  _gm_cmd restore --source "$commit" -- "$selected"
  echo "$selected" | xargs git restore --source "$commit" --
  _gm_success "Restored selected file(s) from $commit"
}

# ─────────────────────────────────────────────
# Ship  (add . → commit → push)
# ─────────────────────────────────────────────

_gm_ship() {
  _gm_require_repo || return

  local staged
  _gm_run add -A
  staged=$(git diff --cached --name-only | wc -l | tr -d ' ')
  if [[ "$staged" -eq 0 ]]; then
    _gm_warn "Nothing to commit — working tree clean."
    return
  fi
  _gm_info "Staged $staged file(s)"
  echo ""

  _gm_commit || { _gm_warn "Ship aborted — nothing pushed."; return; }
  echo ""
  local mode
  mode=$(gum choose --header "Push:" \
    " Push|Push" " Force With Lease|Force With Lease" " Skip|Skip")
  [[ -z "$mode" || "${mode:l}" == "skip" ]] && { _gm_info "Committed but not pushed."; return; }
  _gm_push "$mode"
}

# ─────────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────────

# Rounded banner: user · branch · cleanliness · ahead/behind.
_gm_banner() {
  local branch user dirty ahead behind state counts
  branch=$(_gm_current_branch)
  user=$(git config user.name); [[ -z "$user" ]] && user="git"
  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  ahead=$(git rev-list @{u}..HEAD 2>/dev/null | wc -l | tr -d ' ')
  behind=$(git rev-list HEAD..@{u} 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$dirty" -eq 0 ]]; then
    state=$(gum style --foreground $_GM_SUCCESS " clean")
  else
    state=$(gum style --foreground $_GM_WARN " ${dirty} changed")
  fi
  counts=$(gum style --foreground $_GM_MUTED "↑${ahead} ↓${behind}")

  gum style \
    --border rounded \
    --border-foreground $_GM_PRIMARY \
    --padding "0 2" \
    "$(gum style --foreground $_GM_PRIMARY --bold "🌿 ${user}")    $(gum style --foreground $_GM_SECONDARY --bold " ${branch}")    ${state}    ${counts}"
}

# Print available subcommands.
_gm_usage() {
  gum style --foreground $_GM_SECONDARY --bold "git-gusto (gg) — commands"
  echo ""
  gum style --foreground $_GM_MUTED "Run 'gg' with no argument for the interactive menu, or:"
  echo ""
  gum style \
    "  gg ship                      add . → commit → push
  gg commit                    Stage all + conventional commit (no push)
  gg push     [push|force]
  gg refs                      Branch / Tag / Worktree / Search menu
  gg branch   [list [local|remote|all]|switch|create|rename|delete]
  gg tag      [list|create|delete]
  gg worktree [create|delete|open|list]
  gg search   [commits|branches|tags]
  gg status                    Repo status (also under Changes)
  gg fetch    [origin|all]
  gg pull     [rebase|merge]
  gg sync                      Merge / Rebase menu
  gg history                   Log / Reset / Restore menu
  gg merge    [<branch>]       Merge a branch into current
  gg rebase   [<branch>]       Rebase current onto a branch
  gg init                      Initialize git here
  gg clone                     Clone a repository
  gg remote   [list|set|remove]   Manage remotes (origin/upstream/…)
  gg theme    [light|dark|auto]   Set terminal color theme for this terminal/IDE
  gg help                      Show this help"
}

# Map a CLI argument to the matching menu. Extra args select a sub-action,
# e.g. 'gg branch create' or 'gg push force'.
_gm_dispatch() {
  local cmd="$1"; shift
  case "${cmd:l}" in
    ship)               _gm_ship ;;
    commit|c|ci)        _gm_stage_commit ;;
    refs|r)             _gm_refs ;;
    branch|b|br)        _gm_branch "$@" ;;
    tag|t)              _gm_tag "$@" ;;
    worktree|wt|w)      _gm_worktree "$@" ;;
    search|s)           _gm_search "$@" ;;
    status|st)          _gm_status ;;
    fetch|f)            _gm_fetch "$@" ;;
    pull)               _gm_pull "$@" ;;
    push|p)             _gm_push "$@" ;;
    sync|integrate|i)   _gm_integrate ;;
    history|hist)       _gm_history ;;
    merge|m)            _gm_merge "$@" ;;
    rebase|rb)          _gm_rebase "$@" ;;
    init)               _gm_init_repo ;;
    clone|cl)           _gm_clone ;;
    remote|origin)      _gm_remote "$@" ;;
    theme)              _gm_theme_cmd "$@" ;;
    help|-h|--help|h)   _gm_usage ;;
    *) _gm_error "Unknown command: $cmd"; echo ""; _gm_usage; return 1 ;;
  esac
}

gg() {
  setopt localtraps
  _gm_require_gum || return
  _gm_apply_theme_pref
  _gm_theme
  _gm_require_git || return

  _gm_term_theme_start
  trap '_gm_term_theme_reset' EXIT INT TERM

  # Direct subcommand mode: 'gg <command> [sub-action]'.
  if [[ -n "$1" ]]; then
    case "${1:l}" in
      init|clone|cl|remote|origin|theme|help|-h|--help|h) ;;
      *) _gm_repo_setup_if_needed || return ;;
    esac
    _gm_dispatch "$@"
    return
  fi

  _gm_repo_setup_if_needed || return

  local choice

  while true; do
    echo ""
    _gm_banner
    echo ""

    choice=$(gum choose \
      --header "What do you want to do?" \
      " Fetch|Fetch" \
      " Ship (add → commit → push)|Ship" \
      " Changes|Changes" \
      " Refs|Refs" \
      " Sync|Sync" \
      " History|History" \
      " Remote|Remote" \
      " Quit|Quit")
    # Empty (Esc) or Quit exits the manager.
    if [[ -z "$choice" || "$choice" == "Quit" ]]; then
      echo ""
      gum style --foreground $_GM_PRIMARY --bold "Ciao! 👋"
      echo ""
      return
    fi

    case "$choice" in
      Fetch)    _gm_fetch ;;
      Ship)     _gm_ship ;;
      Changes)  _gm_stage_commit ;;
      Refs)     _gm_refs ;;
      Sync)     _gm_integrate ;;
      History)  _gm_history ;;
      Remote)   _gm_remote ;;
    esac
  done
}

# Run gg directly when executed as a script (not when sourced).
if [[ "$zsh_eval_context" == "toplevel" ]]; then
  gg "$@"
fi
