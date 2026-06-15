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
  git add -A
  if [[ -z "$(git diff --cached --name-only)" ]]; then
    _gm_warn "Nothing to commit yet — add files before pushing."
    return 1
  fi

  msg=$(gum input --placeholder "Initial commit message..." --value "Initial commit" --width 60)
  [[ -z "$msg" ]] && return 1

  if git commit -m "$msg"; then
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
    git remote set-url "$name" "$remote" || return 1
    _gm_success "Updated $name: $remote"
  else
    git remote add "$name" "$remote" || return 1
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
  git remote remove "$name" && _gm_success "Removed remote: $name"
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
  gum style --border rounded --padding "0 1" --border-foreground $_GM_PRIMARY \
    "Clone: $remote
Into:  $dest"
  echo ""
  gum confirm "Clone this repository?" || return 1

  if ! gum spin --title "Cloning..." -- git clone "$remote" "$dest"; then
    _gm_error "Clone failed"
    return 1
  fi
  _gm_success "Cloned into $dest"

  target=$(cd "$dest" 2>/dev/null && pwd) || return 0
  local action
  action=$(gum choose --header "Open clone in:" \
    " Kiro|Kiro" " Shell|Shell" " Skip|Skip")

  case "$action" in
    Kiro)  kiro "$target" ;;
    Shell) cd "$target" && exec $SHELL ;;
    Skip)  ;;
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
    git branch -m main || return 1
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
      gum spin --title "Pushing..." -- git push -u origin "$branch"
      _gm_success "Pushed $branch to origin"
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
_GM_PRIMARY=212    # magenta — cursor, selected, accents
_GM_SECONDARY=141  # purple  — headers, prompts
_GM_SUCCESS=84     # green
_GM_WARN=215       # orange
_GM_ERROR=203      # red
_GM_MUTED=245      # gray

# Theme every gum component once via its env vars. Called at the top of gg().
_gm_theme() {
  # choose
  export GUM_CHOOSE_CURSOR="❯ "
  export GUM_CHOOSE_CURSOR_FOREGROUND=$_GM_PRIMARY
  export GUM_CHOOSE_HEADER_FOREGROUND=$_GM_SECONDARY
  export GUM_CHOOSE_SELECTED_FOREGROUND=$_GM_PRIMARY
  export GUM_CHOOSE_HEIGHT=12
  export GUM_CHOOSE_LABEL_DELIMITER="|"   # items as "label|value"

  # filter
  export GUM_FILTER_INDICATOR="❯"
  export GUM_FILTER_INDICATOR_FOREGROUND=$_GM_PRIMARY
  export GUM_FILTER_PROMPT="❯ "
  export GUM_FILTER_PROMPT_FOREGROUND=$_GM_SECONDARY
  export GUM_FILTER_MATCH_FOREGROUND=$_GM_PRIMARY
  export GUM_FILTER_HEADER_FOREGROUND=$_GM_SECONDARY
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
# within <width> columns. Usage: _gm_columnize <width>
_gm_columnize() {
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

# Render refs (branches/tags) read from stdin as one full-width box per prefix
# group (split on the first <delim>); refs without <delim> go in a "•" box.
# Each box: bold group title + the full ref names laid out in dynamic columns.
# Usage: _gm_group_boxes <delim> <color> <width>
_gm_group_boxes() {
  local delim="$1" color="${2:-$_GM_PRIMARY}" width="${3:-120}"
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

  local inner=$(( width - 4 ))   # account for border (2) + padding (2)
  (( inner < 10 )) && inner=10

  for key in "${order[@]}"; do
    gum style \
      --border rounded --border-foreground "$color" --padding "0 1" \
      "$(gum style --foreground "$color" --bold "$key")
$(echo "${members[$key]%$'\n'}" | _gm_columnize "$inner")"
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

  local branch type msg full_msg

  branch=$(_gm_current_branch)
  _gm_header "Commit — $branch"
  echo ""

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
  gum style --border rounded --padding "0 1" --border-foreground $_GM_PRIMARY "$full_msg"
  echo ""

  gum confirm "Commit with this message?" || return 1

  if git commit -m "$full_msg"; then
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
  if [[ -z "$action" ]]; then
    action=$(gum choose \
      --header "Branch:" \
      " List|List" " Switch|Switch" " Create|Create" " Rename|Rename" " Delete|Delete" " Back|← Back")
  fi
  [[ -z "$action" ]] && return

  case "${action:l}" in
    list)     _gm_branch_list "$@" ;;
    switch)   _gm_branch_switch ;;
    create)   _gm_branch_create ;;
    rename)   _gm_branch_rename ;;
    delete)   _gm_branch_delete ;;
    "← back"|back) return ;;
    *) _gm_error "Unknown branch action: $action" ;;
  esac
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
      gum spin --title "Stashing..." -- git stash push -u -m "gg: switch to $branch" && stashed=1
    fi
  fi

  if ! git checkout "$branch"; then
    _gm_error "Checkout failed"
    [[ -n "$stashed" ]] && _gm_info "Your changes are stashed — 'git stash pop' to restore."
    return 1
  fi
  _gm_success "Switched to $branch"

  # Bring the stashed changes back onto the new branch if wanted.
  if [[ -n "$stashed" ]] && gum confirm "Restore your stashed changes here (stash pop)?"; then
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
    git checkout -b "$name" "$base"
    _gm_success "Created branch: $name (from $base)"
  else
    git checkout -b "$name"
    _gm_success "Created branch: $name (from $current)"
  fi

  if gum confirm "Push branch to remote?"; then
    gum spin --title "Pushing..." -- git push -u origin "$name"
    _gm_success "Pushed $name to origin"
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

  git branch -m "$old" "$new" || { _gm_error "Rename failed"; return 1; }
  _gm_success "Renamed branch: $old → $new"

  # Remote branches can't be renamed in place — push the new name and drop the
  # old one, then re-track upstream.
  if [[ -n "$had_upstream" ]] && gum confirm "Update remote: push '$new' and delete '$old' on origin?"; then
    gum spin --title "Pushing $new..." -- git push -u origin "$new"
    gum spin --title "Deleting old remote branch..." -- git push origin --delete "$old"
    _gm_success "Remote updated: origin/$old → origin/$new"
  fi
}

_gm_branch_delete() {
  local branch
  branch=$(git branch \
    | grep -v '^\*' \
    | sed 's/^[+* ]*//' \
    | _gm_filter --placeholder "Select branch to delete...")
  [[ -z "$branch" ]] && return

  gum confirm "Delete local branch '$branch'?" || return

  git branch -d "$branch"
  _gm_success "Deleted local branch: $branch"

  if gum confirm "Delete remote branch '$branch' too?"; then
    gum spin --title "Deleting remote..." -- git push origin --delete "$branch"
    _gm_success "Deleted remote branch: $branch"
  fi
}

_gm_branch_list() {
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
      echo "$local_branches" | _gm_filter_group "/" "$group" | _gm_group_boxes "/" $_GM_PRIMARY $width
    fi

    [[ -n "$local_branches" && -n "$remote_branches" ]] && echo ""

    if [[ -n "$remote_branches" ]]; then
      gum style --foreground $_GM_SECONDARY --bold " REMOTE (origin)"
      echo ""
      echo "$remote_branches" | _gm_filter_group "/" "$group" | _gm_group_boxes "/" $_GM_SECONDARY $width
    fi
  } | gum pager
}

# ─────────────────────────────────────────────
# Tag
# ─────────────────────────────────────────────

_gm_tag() {
  _gm_require_repo || return

  local action="$1"
  if [[ -z "$action" ]]; then
    action=$(gum choose \
      --header "Tag:" \
      " List|List" " Add|Add" " Remove|Remove" " Back|← Back")
  fi
  [[ -z "$action" ]] && return

  case "${action:l}" in
    list)            _gm_tag_list ;;
    add|create)      _gm_tag_create ;;
    remove|delete)   _gm_tag_delete ;;
    "← back"|back) return ;;
    *) _gm_error "Unknown tag action: $action" ;;
  esac
}

_gm_tag_create() {
  local tag
  tag=$(gum input --placeholder "Tag name (e.g. v1.2.3 or prod=711.4.3)" --width 50)
  [[ -z "$tag" ]] && return

  echo ""
  gum style --border rounded --padding "0 1" --border-foreground $_GM_PRIMARY "Tag: $tag"
  echo ""
  gum confirm "Create tag '$tag'?" || return

  git tag "$tag"
  _gm_success "Created tag: $tag"

  if gum confirm "Push tag to remote?"; then
    gum spin --title "Pushing tag..." -- git push origin "$tag"
    _gm_success "Pushed tag: $tag"
  fi
}

_gm_tag_delete() {
  local tag
  tag=$(git tag --sort=-v:refname | _gm_filter --no-fuzzy-sort --placeholder "Select tag to delete...")
  [[ -z "$tag" ]] && return

  gum confirm "Delete local tag '$tag'?" || return

  git tag -d "$tag"
  _gm_success "Deleted local tag: $tag"

  if gum confirm "Delete remote tag '$tag' too?"; then
    gum spin --title "Deleting remote tag..." -- git push origin --delete "$tag"
    _gm_success "Deleted remote tag: $tag"
  fi
}

_gm_tag_list() {
  local tags width group
  tags=$(git tag --sort=-v:refname)

  width=${COLUMNS:-0}; (( width < 20 )) && width=$(tput cols 2>/dev/null || echo 120)

  # Offer a group (e.g. prod=, stage=) when tags span more than one prefix.
  group=$(echo "$tags" | _gm_pick_group "=") || return

  {
    gum style --foreground $_GM_PRIMARY --bold " TAGS"
    echo ""
    echo "$tags" | _gm_filter_group "=" "$group" | _gm_group_boxes "=" $_GM_PRIMARY $width
  } | gum pager
}

# ─────────────────────────────────────────────
# Worktree
# ─────────────────────────────────────────────

_gm_worktree() {
  _gm_require_repo || return

  local action="$1"
  if [[ -z "$action" ]]; then
    action=$(gum choose \
      --header "Worktree:" \
      " List|List" " Add|Add" " Remove|Remove" " Open|Open" " Back|← Back")
  fi
  [[ -z "$action" ]] && return

  case "${action:l}" in
    add|create)      _gm_worktree_create ;;
    remove|delete)   _gm_worktree_delete ;;
    open)     _gm_worktree_open ;;
    list)     _gm_worktree_list ;;
    "← back"|back) return ;;
    *) _gm_error "Unknown worktree action: $action" ;;
  esac
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
  gum style --border rounded --padding "0 1" --border-foreground $_GM_PRIMARY \
    "Branch: $branch
Name:   $name
Path:   $wt_path"
  echo ""

  gum confirm "Create worktree?" || return

  # Existing local branch → check it out; remote-only → create a tracking
  # local branch; otherwise create a fresh branch.
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git worktree add "$wt_path" "$branch"
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git worktree add "$wt_path" -b "$branch" "origin/$branch"
  else
    git worktree add "$wt_path" -b "$branch"
  fi
  _gm_success "Worktree created at $wt_path"

  local open_action
  open_action=$(gum choose --header "Open worktree in:" \
    " Kiro|Kiro" " Shell|Shell" " Skip|Skip")

  case "$open_action" in
    Kiro)  kiro "$wt_path" ;;
    Shell) cd "$wt_path" && exec $SHELL ;;
    Skip)  ;;
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
  gum style --border rounded --padding "0 1" --border-foreground $_GM_ERROR \
    "Branch: $branch
Path:   $wt_path"
  echo ""

  gum confirm "Remove worktree at '$wt_path'?" || return

  git worktree remove "$wt_path"
  _gm_success "Removed worktree: $wt_path"
}

_gm_worktree_open() {
  local selected wt_path branch action worktrees

  worktrees=$(git worktree list | tail -n +2)
  [[ -z "$worktrees" ]] && { _gm_warn "No additional worktrees."; return; }

  selected=$(echo "$worktrees" | _gm_filter --placeholder "Select worktree to open...")
  [[ -z "$selected" ]] && return

  wt_path=$(echo "$selected" | awk '{print $1}')
  branch=$(echo "$selected" | awk '{print $3}' | tr -d '[]')

  action=$(gum choose \
    --header "Open '$branch' in:" \
    " Kiro|Kiro" " Shell|Shell" " Copy Path|Copy Path")

  case "$action" in
    Kiro)       kiro "$wt_path" ;;
    Shell)      cd "$wt_path" && exec $SHELL ;;
    "Copy Path") echo -n "$wt_path" | pbcopy && _gm_success "Path copied to clipboard" ;;
  esac
}

_gm_worktree_list() {
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
      " Branch|Branch" " Tag|Tag" " Worktree|Worktree" " Back|← Back")
    [[ -z "$choice" || "${choice:l}" == "← back" || "${choice:l}" == "back" ]] && return

    case "$choice" in
      Branch)   _gm_branch ;;
      Tag)      _gm_tag ;;
      Worktree) _gm_worktree ;;
    esac
  done
}

# ─────────────────────────────────────────────
# Search
# ─────────────────────────────────────────────

_gm_search() {
  _gm_require_repo || return

  local scope="$1"
  if [[ -z "$scope" ]]; then
    scope=$(gum choose --header "Search:" \
      " Commits|Commits" " Branches|Branches" " Tags|Tags" " Back|← Back")
  fi
  [[ -z "$scope" ]] && return

  case "${scope:l}" in
    commits)  _gm_search_commits ;;
    branches) _gm_search_branches ;;
    tags)     _gm_search_tags ;;
    "← back"|back) return ;;
    *) _gm_error "Unknown search scope: $scope" ;;
  esac
}

_gm_search_commits() {
  local selected hash action

  selected=$(git log --oneline --all | _gm_filter --placeholder "Search commits...")
  [[ -z "$selected" ]] && return

  hash=$(echo "$selected" | awk '{print $1}')

  action=$(gum choose --header "Action for $hash:" \
    " Show Diff|Show Diff" " Show Files|Show Files" " Copy Hash|Copy Hash")

  case "$action" in
    "Show Diff")  git show "$hash" | gum pager ;;
    "Show Files") git show --name-only "$hash" | gum pager ;;
    "Copy Hash")  echo -n "$hash" | pbcopy && _gm_success "Hash copied: $hash" ;;
  esac
}

_gm_search_branches() {
  local branch action

  branch=$(git branch -a \
    | sed 's/^[+* ]*//' \
    | _gm_filter --placeholder "Search branches...")
  [[ -z "$branch" ]] && return

  action=$(gum choose --header "Action for '$branch':" \
    " Checkout|Checkout" " Show Commits|Show Commits" " Copy Name|Copy Name")

  case "$action" in
    Checkout)       git checkout "${branch#remotes/origin/}" ;;
    "Show Commits") git log --oneline "$branch" | gum pager ;;
    "Copy Name")    echo -n "$branch" | pbcopy && _gm_success "Copied: $branch" ;;
  esac
}

_gm_search_tags() {
  local tag action

  tag=$(git tag --sort=-v:refname | _gm_filter --no-fuzzy-sort --placeholder "Search tags...")
  [[ -z "$tag" ]] && return

  action=$(gum choose --header "Action for '$tag':" \
    " Show Details|Show Details" " Checkout|Checkout" " Copy Name|Copy Name")

  case "$action" in
    "Show Details") git show "$tag" | gum pager ;;
    Checkout)       git checkout "$tag" ;;
    "Copy Name")    echo -n "$tag" | pbcopy && _gm_success "Copied: $tag" ;;
  esac
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
    gum spin --title "Fetching origin..." -- git fetch --prune
  else
    gum spin --title "Fetching all remotes..." -- git fetch --all --prune
  fi
  _gm_success "Fetch complete"
}

_gm_pull() {
  _gm_require_repo || return

  local mode="$1"
  if [[ -z "$mode" ]]; then
    mode=$(gum choose --header "Pull:" \
      " Rebase|Rebase" " Merge|Merge" " Back|← Back")
  fi
  [[ -z "$mode" || "${mode:l}" == "← back" || "${mode:l}" == "back" ]] && return

  if [[ "${mode:l}" == "rebase" ]]; then
    gum spin --title "Pulling (rebase)..." -- git pull --rebase
  else
    gum spin --title "Pulling (merge)..." -- git pull
  fi
  _gm_success "Pull complete"

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
    gum spin --title "Pushing..." -- git push "${push_target[@]}"
  else
    gum confirm "Force push with lease? This rewrites remote history." || return
    gum spin --title "Force pushing..." -- git push --force-with-lease "${push_target[@]}"
  fi
  _gm_success "Push complete"
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
        source=$(git branch \
          | grep -v HEAD | sed 's/^[+* ]*//' \
          | grep -vx "$current" \
          | _gm_filter --placeholder "Search branch to merge into $current...") ;;
      remote)
        source=$(git branch -r \
          | grep -v HEAD | sed 's|^[[:space:]]*origin/||' \
          | sort -u | grep -vx "$current" \
          | _gm_filter --placeholder "Search remote branch to merge into $current...") ;;
      all)
        source=$(git branch --all \
          | grep -v HEAD | sed 's/^[+* ]*//' | sed 's|remotes/origin/||' \
          | sort -u | grep -vx "$current" \
          | _gm_filter --placeholder "Search branch to merge into $current...") ;;
    esac
  fi
  [[ -z "$source" ]] && return

  mode=$(gum choose --header "Merge mode:" \
    " Default|Default" " No-FF|No-FF" " Squash|Squash" " Back|← Back")
  [[ -z "$mode" || "${mode:l}" == "← back" || "${mode:l}" == "back" ]] && return

  echo ""
  gum style --border rounded --padding "0 1" --border-foreground $_GM_PRIMARY \
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
    no-ff)  out=$(git merge --no-ff "$@" "$source" 2>&1); rc=$? ;;
    squash) out=$(git merge --squash "$@" "$source" 2>&1); rc=$? ;;
    *)      out=$(git merge "$@" "$source" 2>&1); rc=$? ;;
  esac
  [[ -n "$out" ]] && echo "$out"

  if [[ $rc -eq 0 ]]; then
    if [[ "${mode:l}" == "squash" ]]; then
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
      git merge --abort
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
        onto=$(git branch \
          | grep -v HEAD | sed 's/^[+* ]*//' \
          | grep -vx "$current" \
          | _gm_filter --placeholder "Rebase $current onto...") ;;
      remote)
        onto=$(git branch -r \
          | grep -v HEAD | sed 's|^[[:space:]]*origin/||' \
          | sort -u | grep -vx "$current" \
          | _gm_filter --placeholder "Rebase $current onto...") ;;
      all)
        onto=$(git branch --all \
          | grep -v HEAD | sed 's/^[+* ]*//' | sed 's|remotes/origin/||' \
          | sort -u | grep -vx "$current" \
          | _gm_filter --placeholder "Rebase $current onto...") ;;
    esac
  fi
  [[ -z "$onto" ]] && return

  echo ""
  gum style --border rounded --padding "0 1" --border-foreground $_GM_PRIMARY \
    "Rebase: $current onto $onto"
  echo ""
  gum confirm "Rebase '$current' onto '$onto'?" || return

  if git rebase "$onto"; then
    _gm_success "Rebased $current onto $onto"
    echo ""
    if gum confirm "Push rebased branch to remote now?"; then
      _gm_push
    else
      _gm_info "Rebased but not pushed."
    fi
  else
    _gm_error "Rebase hit conflicts."
    if gum confirm "Abort the rebase?"; then
      git rebase --abort
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

  local action staged
  while true; do
    action=$(gum choose \
      --header "Changes:" \
      " Add (stage all files)|Add" \
      " Remove from stage|Unstage" \
      " Commit (staged files only)|Commit" \
      " Undo Last Commit|Undo" \
      " Push|Push" \
      " Back|← Back")
    [[ -z "$action" || "$action" == "← Back" ]] && return

    case "$action" in
      Add)
        git add -A
        staged=$(git diff --cached --name-only | wc -l | tr -d ' ')
        if [[ "$staged" -eq 0 ]]; then
          _gm_warn "Nothing to stage — working tree clean."
        else
          _gm_success "Staged $staged file(s)"
        fi
        ;;
      Unstage)
        _gm_unstage
        ;;
      Commit)
        _gm_commit
        ;;
      Undo)
        _gm_undo_commit
        ;;
      Push)
        _gm_push
        ;;
    esac
  done
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

  gum style --border rounded --padding "0 1" --border-foreground $_GM_WARN "Last commit: $last"
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

  git reset --"$mode" HEAD~1
  _gm_success "Undid last commit ($mode)"
}

# ─────────────────────────────────────────────
# Ship  (add . → commit → push)
# ─────────────────────────────────────────────

_gm_ship() {
  _gm_require_repo || return

  local staged
  git add -A
  staged=$(git diff --cached --name-only | wc -l | tr -d ' ')
  if [[ "$staged" -eq 0 ]]; then
    _gm_warn "Nothing to commit — working tree clean."
    return
  fi
  _gm_info "Staged $staged file(s)"
  echo ""

  _gm_commit || { _gm_warn "Ship aborted — nothing pushed."; return; }
  echo ""
  gum confirm "Push to remote now?" || { _gm_info "Committed but not pushed."; return; }
  _gm_push
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
  gg refs                      Branch / Tag / Worktree menu
  gg branch   [list [local|remote|all]|switch|create|rename|delete]
  gg tag      [list|create|delete]
  gg worktree [create|delete|open|list]
  gg search   [commits|branches|tags]
  gg status                    Repo status
  gg fetch    [origin|all]
  gg pull     [rebase|merge]
  gg sync                      Merge / Rebase menu
  gg merge    [<branch>]       Merge a branch into current
  gg rebase   [<branch>]       Rebase current onto a branch
  gg init                      Initialize git here
  gg clone                     Clone a repository
  gg remote   [list|set|remove]   Manage remotes (origin/upstream/…)
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
    merge|m)            _gm_merge "$@" ;;
    rebase|rb)          _gm_rebase "$@" ;;
    init)               _gm_init_repo ;;
    clone|cl)           _gm_clone ;;
    remote|origin)      _gm_remote "$@" ;;
    help|-h|--help|h)   _gm_usage ;;
    *) _gm_error "Unknown command: $cmd"; echo ""; _gm_usage; return 1 ;;
  esac
}

gg() {
  _gm_require_gum || return
  _gm_theme
  _gm_require_git || return

  # Direct subcommand mode: 'gg <command> [sub-action]'.
  if [[ -n "$1" ]]; then
    case "${1:l}" in
      init|clone|cl|remote|origin|help|-h|--help|h) ;;
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
      " Search|Search" \
      " Refs|Refs" \
      " Sync|Sync" \
      " Status|Status" \
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
      Search)   _gm_search ;;
      Sync)     _gm_integrate ;;
      Status)   _gm_status ;;
      Remote)   _gm_remote ;;
    esac
  done
}

# Run gg directly when executed as a script (not when sourced).
if [[ "$zsh_eval_context" == "toplevel" ]]; then
  gg "$@"
fi
