#!/usr/bin/env bash
#
# g — make everyday git work easier.
#
# A single-file wrapper around git. Utilities are ported one at a time from the
# standalone scripts in ~/bitbucket/pftylr/utils/git.
#
# Output rules:
#   * Results — data that is meant to be read, piped or diffed — go to stdout.
#   * Status, progress and errors go to stderr.
#   * Colour and effects appear only on a terminal. Piped or redirected output
#     carries no escape codes but keeps the same alignment.
#
# Bash 3.2 compatible on purpose: /bin/bash on macOS is still 3.2.

set -euo pipefail

G_PROG="g"
G_VERSION="0.1.0"

# ── Presentation layer ──────────────────────────────────────────────────────
# Every user-facing string goes through these helpers, so a command never has
# to know whether it is talking to a terminal.

G_COLOR=0
G_COLOR_ERR=0
G_UNICODE=0
# Indent applied by the status and detail helpers. Empty at top level; a
# command that explains a failure under its own message raises it while it
# prints the explanation, so the block reads as subordinate.
G_INDENT=''
C_RESET='' C_BOLD='' C_DIM='' C_ITALIC='' C_UNDERLINE='' C_REVERSE=''
C_BLACK='' C_RED='' C_GREEN='' C_YELLOW=''
C_BLUE='' C_MAGENTA='' C_CYAN='' C_WHITE=''
E_RESET='' E_BOLD='' E_DIM='' E_REVERSE='' E_RED='' E_GREEN='' E_YELLOW='' E_CYAN=''

# _init_style [auto|always|never]
#
# Colour is decided per stream: C_* decorate stdout, E_* decorate stderr. A
# command whose result goes to stdout can therefore keep coloured progress
# messages — `cd "$(g wt foo)"` still looks right — while a redirected report
# stays free of escape codes even though the terminal is right there.
_init_style() {
  local mode="${1:-auto}" out_tty=0 err_tty=0

  if [[ -t 1 ]]; then
    out_tty=1
  fi
  if [[ -t 2 ]]; then
    err_tty=1
  fi

  case "$mode" in
    always)
      out_tty=1
      err_tty=1
      ;;
    never)
      out_tty=0
      err_tty=0
      ;;
  esac

  # An explicit NO_COLOR (https://no-color.org) or a dumb terminal wins over
  # autodetection, but not over --color=always.
  if [[ "$mode" != "always" ]]; then
    if [[ -n "${NO_COLOR-}" ]]; then
      out_tty=0
      err_tty=0
    fi
    if [[ "${TERM-}" == "dumb" ]]; then
      out_tty=0
      err_tty=0
    fi
  fi
  G_COLOR=$out_tty
  G_COLOR_ERR=$err_tty

  if (( G_COLOR )); then
    C_RESET=$'\033[0m'   C_BOLD=$'\033[1m'      C_DIM=$'\033[2m'
    C_ITALIC=$'\033[3m'  C_UNDERLINE=$'\033[4m' C_REVERSE=$'\033[7m'
    C_BLACK=$'\033[30m'  C_RED=$'\033[31m'      C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m' C_BLUE=$'\033[34m'     C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'   C_WHITE=$'\033[37m'
  fi

  if (( G_COLOR_ERR )); then
    E_RESET=$'\033[0m'   E_BOLD=$'\033[1m'      E_DIM=$'\033[2m'
    E_REVERSE=$'\033[7m'
    E_RED=$'\033[31m'    E_GREEN=$'\033[32m'    E_YELLOW=$'\033[33m'
    E_CYAN=$'\033[36m'
  fi

  # Box drawing only when the locale can render it.
  case "${LC_ALL:-${LC_CTYPE:-${LANG-}}}" in
    *[Uu][Tt][Ff]*) G_UNICODE=1 ;;
  esac

  return 0
}

# Repeat a single character N times.
_repeat() {
  local ch="$1" n="$2" out=''
  if (( n <= 0 )); then
    return 0
  fi
  printf -v out '%*s' "$n" ''
  printf '%s' "${out// /$ch}"
}

# _plural N ONE MANY — the word that agrees with N.
_plural() {
  if (( $1 == 1 )); then
    printf '%s' "$2"
  else
    printf '%s' "$3"
  fi
}

# relpath_into VARIABLE TARGET — store TARGET relative to $PWD in VARIABLE.
# Uses the physical working directory because git reports physical paths — on
# macOS /tmp is a symlink to /private/tmp. Assigns rather than prints, and
# splits paths with string operations rather than `read -a` on a herestring,
# so a loop over thousands of files does not fork or touch the disk per file.
_REL_CACHE_PWD=''
_REL_CACHE_FROM=''

relpath_into() {
  local __rp_name="$1" __rp_target="$2"
  local __rp_from __rp_out='' __rp_t __rp_f __rp_tc __rp_fc
  local __rp_ups __rp_rest __rp_i

  if [[ -z "$_REL_CACHE_FROM" || "$_REL_CACHE_PWD" != "$PWD" ]]; then
    _REL_CACHE_FROM=$(pwd -P)
    _REL_CACHE_PWD="$PWD"
  fi
  __rp_from="$_REL_CACHE_FROM"

  if [[ "$__rp_target" == "$__rp_from" ]]; then
    printf -v "$__rp_name" '%s' '.'
    return 0
  fi

  __rp_t="${__rp_target#/}"
  __rp_f="${__rp_from#/}"
  while [[ -n "$__rp_t" && -n "$__rp_f" ]]; do
    __rp_tc="${__rp_t%%/*}"
    __rp_fc="${__rp_f%%/*}"
    if [[ "$__rp_tc" != "$__rp_fc" ]]; then
      break
    fi
    if [[ "$__rp_t" == */* ]]; then
      __rp_t="${__rp_t#*/}"
    else
      __rp_t=''
    fi
    if [[ "$__rp_f" == */* ]]; then
      __rp_f="${__rp_f#*/}"
    else
      __rp_f=''
    fi
  done

  __rp_ups=0
  if [[ -n "$__rp_f" ]]; then
    __rp_ups=1
    __rp_rest="$__rp_f"
    while [[ "$__rp_rest" == */* ]]; do
      __rp_rest="${__rp_rest#*/}"
      __rp_ups=$(( __rp_ups + 1 ))
    done
  fi

  for (( __rp_i = 0; __rp_i < __rp_ups; __rp_i++ )); do
    __rp_out+='../'
  done
  __rp_out+="$__rp_t"

  if [[ -z "$__rp_out" ]]; then
    __rp_out='.'
  fi
  printf -v "$__rp_name" '%s' "$__rp_out"
}

# relpath TARGET — print TARGET relative to $PWD.
relpath() {
  local __rp_path
  relpath_into __rp_path "$1"
  printf '%s\n' "$__rp_path"
}

_rule() {
  local ch='-'
  if (( G_UNICODE )); then
    ch='─'
  fi
  _repeat "$ch" "${1:-72}"
}

# section TITLE — a heading with a rule of matching width.
section() {
  local title="$*"
  printf '\n%s%s%s\n' "$C_BOLD" "$title" "$C_RESET"
  printf '%s%s%s\n' "$C_DIM" "$(_rule "${#title}")" "$C_RESET"
}

# hr — a full-width dim rule.
hr() {
  local width="${COLUMNS:-72}"
  if (( width > 100 )); then
    width=100
  fi
  printf '%s%s%s\n' "$C_DIM" "$(_rule "$width")" "$C_RESET"
}

# kv LABEL VALUE — an aligned label/value pair.
kv() {
  printf '%s%-*s%s %s\n' "$C_DIM" "${G_LABEL_WIDTH:-16}" "$1" "$C_RESET" "${2-}"
}

# paint_into VARIABLE COLOUR TEXT — as paint, but assigns instead of printing,
# for loops where a fork per row would be felt.
paint_into() {
  local __p_name="$1" __p_colour="$2"
  shift 2
  printf -v "$__p_name" '%s%s%s' "$__p_colour" "$*" "$C_RESET"
}

# paint COLOUR TEXT — TEXT wrapped in COLOUR for stdout. Plain mode emits the
# text alone, so callers never have to branch on whether colour is on.
# Escape bytes count towards a cell's width, so only use this on the last
# column of a table.
paint() {
  local __p_out
  paint_into __p_out "$@"
  printf '%s' "$__p_out"
}

# muted TEXT — dim secondary text on stdout.
muted() {
  printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"
}

# item COLOUR MARKER TEXT — one bullet in a report, with a coloured marker.
item() {
  local colour="$1" marker="$2"
  shift 2
  printf '  %s%s%s %s\n' "$colour" "$marker" "$C_RESET" "$*"
}

# step TEXT — one completed step of a report, on stdout.
step() {
  local glyph='+'
  if (( G_UNICODE )); then
    glyph='✓'
  fi
  printf '  %s%s%s %s\n' "$C_GREEN" "$glyph" "$C_RESET" "$*"
}

# detail TEXT... — an indented continuation line on stderr, for the second and
# later lines of a message that needs more than one. Nests under G_INDENT.
detail() {
  printf '%s  %s%s%s\n' "$G_INDENT" "$E_DIM" "$*" "$E_RESET" >&2
}

# relay — copy stdin to stderr, indented, for output that comes from git.
# git's own chatter then reads as a detail of the message above it instead of
# as another message from g.
relay() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s  %s\n' "$G_INDENT" "$line" >&2
  done
}

# Status lines. In colour mode the glyph carries the meaning as well as the
# colour, so the output still reads correctly for colour-blind users.
_status() {
  local colour="$1" glyph_utf="$2" glyph_ascii="$3" label="$4"
  shift 4

  if (( G_COLOR_ERR )); then
    local glyph="$glyph_ascii"
    if (( G_UNICODE )); then
      glyph="$glyph_utf"
    fi
    printf '%s%s%s%s %s\n' "$G_INDENT" "$colour" "$glyph" "$E_RESET" "$*" >&2
  else
    printf '%s%s%s\n' "$G_INDENT" "$label" "$*" >&2
  fi
}

ok()   { _status "$E_GREEN"  "✓" "+" "ok: "      "$@"; }
warn() { _status "$E_YELLOW" "!" "!" "warning: " "$@"; }
err()  { _status "$E_RED"    "✗" "x" "error: "   "$@"; }
info() { _status "$E_CYAN"   "•" "-" "note: "    "$@"; }

# die TEXT — report a fatal error and leave the terminal on a blank line.
die() {
  err "$@"
  printf '\n' >&2
  exit 1
}

# ask_yes_no PROMPT — a y/N question on the terminal; true means yes.
ask_yes_no() {
  local reply=''
  if ! have_tty; then
    return 1
  fi
  printf '%s?%s %s [y/N] ' "$E_YELLOW" "$E_RESET" "$*" >&2
  if ! IFS= read -r reply < /dev/tty; then
    printf '\n' >&2
    return 1
  fi
  [[ "$reply" == [Yy]* ]]
}

# Tables. Rows are added first, then flushed once the column widths are known.
#   table_begin
#   table_add "BRANCH" "AUTHOR" "STATUS"
#   table_add_styled "$C_RED" "broken" "Paul" "remote deleted"
#   table_flush
# Row 0 is the header and is printed bold. Widths are measured on the plain
# cells, so a whole row can be styled without breaking the alignment. An escape
# code inside a cell would count towards its width — colour the row instead.
G_TABLE_ROWS=()
G_TABLE_STYLES=()

table_begin() {
  G_TABLE_ROWS=()
  G_TABLE_STYLES=()
}

table_add() {
  local IFS=$'\x1f'
  G_TABLE_ROWS[${#G_TABLE_ROWS[@]}]="$*"
  G_TABLE_STYLES[${#G_TABLE_STYLES[@]}]=''
}

table_add_styled() {
  local style="$1" idx
  shift
  table_add "$@"
  idx=$(( ${#G_TABLE_ROWS[@]} - 1 ))
  G_TABLE_STYLES[$idx]="$style"
}

# _split_cells ROW — split ROW on the unit separator into _CELLS. Pure string
# operations, because a herestring per row costs a temporary file and a table of
# a few thousand rows turns that into seconds.
_CELLS=()

_split_cells() {
  local rest="$1" cell
  _CELLS=()
  while true; do
    if [[ "$rest" == *$'\x1f'* ]]; then
      cell="${rest%%$'\x1f'*}"
      _CELLS[${#_CELLS[@]}]="$cell"
      rest="${rest#*$'\x1f'}"
    else
      _CELLS[${#_CELLS[@]}]="$rest"
      break
    fi
  done
}

table_flush() {
  local n=${#G_TABLE_ROWS[@]}
  if (( n == 0 )); then
    return 0
  fi

  local i c len row cell style line pad
  local -a widths
  local maxcols=0

  for (( i = 0; i < n; i++ )); do
    _split_cells "${G_TABLE_ROWS[$i]}"
    if (( ${#_CELLS[@]} > maxcols )); then
      maxcols=${#_CELLS[@]}
    fi
    for (( c = 0; c < ${#_CELLS[@]}; c++ )); do
      len=${#_CELLS[$c]}
      if (( len > ${widths[c]:-0} )); then
        widths[c]=$len
      fi
    done
  done

  for (( i = 0; i < n; i++ )); do
    _split_cells "${G_TABLE_ROWS[$i]}"
    style="${G_TABLE_STYLES[$i]:-}"
    if (( i == 0 )); then
      style="${C_BOLD}${style}"
    fi

    line=''
    for (( c = 0; c < maxcols; c++ )); do
      cell="${_CELLS[$c]:-}"
      if (( c == maxcols - 1 )); then
        line+="$cell"
      else
        printf -v pad '%-*s  ' "${widths[c]:-0}" "$cell"
        line+="$pad"
      fi
    done
    # Drop the padding of a trailing empty column.
    while [[ "$line" == *' ' ]]; do
      line="${line% }"
    done

    if [[ -n "$style" ]]; then
      printf '%s%s%s\n' "$style" "$line" "$C_RESET"
    else
      printf '%s\n' "$line"
    fi

    if (( i == 0 )); then
      printf '%s' "$C_DIM"
      for (( c = 0; c < maxcols; c++ )); do
        _rule "${widths[c]:-0}"
        if (( c < maxcols - 1 )); then
          printf '  '
        fi
      done
      printf '%s\n' "$C_RESET"
    fi
  done
}

# ── Guards ──────────────────────────────────────────────────────────────────

require_git() {
  if ! command -v git >/dev/null 2>&1; then
    die "git is not installed or not on PATH"
  fi
}

require_repo() {
  require_git
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "not inside a git repository"
  fi
}

# True when a controlling terminal can be opened for a prompt. Opening the
# device is the only reliable test: /dev/tty exists and looks readable even
# when there is no terminal behind it, and the failed open would print bash's
# own "Device not configured" error.
have_tty() {
  { : </dev/tty; } 2>/dev/null
}

# ── g worktree ──────────────────────────────────────────────────────────────
# Ported from ~/bitbucket/pftylr/utils/git/worktree.
#
# Stream contract: the worktree path, or the report for the listing and status
# modes, goes to stdout. Progress and warnings go to stderr, so
# `cd "$(g wt feature/thing)"` works and a redirected report stays clean.

WT_MODE=''
WT_FORCE=false
WT_REPO_ROOT=''
WT_REPO_NAME=''
WT_PARENT_DIR=''
WT_BASE_REFS=()
WT_PATHS=()
WT_BRANCHES=()
WT_PRUNABLE=()
WT_LOCKED=()
WT_LOCK_REASON=()
WT_LOCAL_MATCHES=()
WT_REMOTE_MATCHES=()
WT_REMOTE_TRUNCATED=0
WT_HAS_ORIGIN=false

_wt_require_repo() {
  require_repo
  # New worktrees are created beside the main worktree, not beside whichever
  # one happens to contain the current directory.
  WT_REPO_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
  WT_REPO_NAME=$(basename "$WT_REPO_ROOT")
  WT_PARENT_DIR=$(dirname "$WT_REPO_ROOT")

  WT_HAS_ORIGIN=false
  if git remote | grep -qx origin; then
    WT_HAS_ORIGIN=true
  fi
}

_wt_validate_branch_name() {
  local name="$1"
  if [[ "$name" != */* || "$name" == */*/* ]]; then
    die "branch name must be in the format SECTION/NAME (e.g. feature/my-thing)"
  fi
}

_wt_branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1" ||
    git show-ref --verify --quiet "refs/remotes/origin/$1"
}

_wt_path_for_branch() {
  printf '%s\n' "${WT_PARENT_DIR}/${WT_REPO_NAME}--${1//\//-}"
}

_wt_existing_for_branch() {
  git worktree list --porcelain | awk -v branch="$1" '
    /^worktree / { path = substr($0, 10) }
    /^branch refs\/heads\// {
      b = substr($0, 19)
      if (b == branch) print path
    }
  '
}

# Like _wt_existing_for_branch, but forgets registrations whose directory has
# been deleted — printing a path that no longer exists helps nobody.
_wt_usable_for_branch() {
  local path
  path=$(_wt_existing_for_branch "$1")
  if [[ -n "$path" && ! -d "$path" ]]; then
    info "pruning stale worktree entry for '$1'"
    git worktree prune
    path=''
  fi
  printf '%s\n' "$path"
}

# Parse `git worktree list --porcelain` into WT_PATHS / WT_BRANCHES /
# WT_PRUNABLE / WT_LOCKED (+ WT_LOCK_REASON), one entry per worktree in the
# order git reports them.
_wt_scan() {
  local line wt_path='' wt_branch='' wt_prunable='' wt_locked='' wt_reason=''

  WT_PATHS=()
  WT_BRANCHES=()
  WT_PRUNABLE=()
  WT_LOCKED=()
  WT_LOCK_REASON=()

  while IFS= read -r line; do
    if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
      wt_path="${BASH_REMATCH[1]}"
      wt_branch=''
      wt_prunable=''
      wt_locked=''
      wt_reason=''
    elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
      wt_branch="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^prunable ]]; then
      wt_prunable=1
    elif [[ "$line" =~ ^locked( (.*))?$ ]]; then
      # `locked` alone, or `locked <reason>` written by git worktree lock.
      wt_locked=1
      wt_reason="${BASH_REMATCH[2]:-}"
    elif [[ -z "$line" && -n "$wt_path" ]]; then
      # git never reports a locked entry as prunable, so a locked worktree
      # whose directory has been deleted looks healthy in the porcelain
      # output. Check the directory too: either way the entry is stale.
      local stale="$wt_prunable"
      if [[ -z "$stale" && ! -d "$wt_path" ]]; then
        stale=1
      fi

      WT_PATHS[${#WT_PATHS[@]}]="$wt_path"
      WT_BRANCHES[${#WT_BRANCHES[@]}]="${wt_branch:-(detached)}"
      WT_PRUNABLE[${#WT_PRUNABLE[@]}]="$stale"
      WT_LOCKED[${#WT_LOCKED[@]}]="$wt_locked"
      WT_LOCK_REASON[${#WT_LOCK_REASON[@]}]="$wt_reason"
      wt_path=''
      wt_branch=''
      wt_prunable=''
      wt_locked=''
      wt_reason=''
    fi
  done < <(git worktree list --porcelain; printf '\n')
}

_wt_list() {
  local current branch path note style i k n
  local -a notes=()

  _wt_scan
  current=$(git rev-parse --show-toplevel 2>/dev/null) || current=''

  section "Worktrees"

  table_begin
  table_add "BRANCH" "PATH" "NOTE"
  n=${#WT_PATHS[@]}
  for (( i = 0; i < n; i++ )); do
    branch="${WT_BRANCHES[$i]}"
    path=$(relpath "${WT_PATHS[$i]}")
    notes=()
    style=''

    if [[ -n "${WT_PRUNABLE[$i]}" ]]; then
      notes[${#notes[@]}]='missing directory'
      style="$C_RED"
    fi

    if [[ -n "${WT_LOCKED[$i]}" ]]; then
      if [[ -n "${WT_LOCK_REASON[$i]}" ]]; then
        notes[${#notes[@]}]="locked: ${WT_LOCK_REASON[$i]}"
      else
        notes[${#notes[@]}]='locked'
      fi
      if [[ -z "$style" ]]; then
        style="$C_YELLOW"
      fi
    fi

    if [[ "$branch" == '(detached)' ]]; then
      notes[${#notes[@]}]='detached'
      if [[ -z "$style" ]]; then
        style="$C_YELLOW"
      fi
    fi

    if [[ -n "$current" && "${WT_PATHS[$i]}" == "$current" ]]; then
      notes[${#notes[@]}]='current'
      style="$C_GREEN"
    fi

    note=''
    for (( k = 0; k < ${#notes[@]}; k++ )); do
      if [[ -n "$note" ]]; then
        note+=', '
      fi
      note+="${notes[$k]}"
    done

    table_add_styled "$style" "$branch" "$path" "$note"
  done
  table_flush

  printf '\n'
  muted "g worktree PATTERN opens or creates one; g worktree -r BRANCH removes it."
  printf '\n'
}

_wt_base_refs() {
  local b
  WT_BASE_REFS=()
  for b in develop dev main master; do
    if git show-ref --verify --quiet "refs/remotes/origin/$b"; then
      WT_BASE_REFS[${#WT_BASE_REFS[@]}]="origin/$b"
    elif git show-ref --verify --quiet "refs/heads/$b"; then
      WT_BASE_REFS[${#WT_BASE_REFS[@]}]="$b"
    fi
  done
}

# True if BRANCH's changes already appear in BASE as a single commit (squash
# merge). Builds a throwaway commit of BRANCH's tree on top of the merge-base
# and asks git cherry whether BASE has an equivalent patch.
_wt_squash_merged() {
  local branch="$1" base="$2" mb tree tmp out
  mb=$(git merge-base "$base" "$branch" 2>/dev/null) || return 1
  tree=$(git rev-parse "$branch^{tree}") || return 1
  tmp=$(git commit-tree "$tree" -p "$mb" -m _) || return 1
  out=$(git cherry "$base" "$tmp")
  [[ "$out" == -* ]]
}

_wt_merge_status() {
  local branch="$1" ref i n

  n=${#WT_BASE_REFS[@]}
  for (( i = 0; i < n; i++ )); do
    ref="${WT_BASE_REFS[$i]}"
    if [[ "$(git rev-parse "$branch")" == "$(git rev-parse "$ref")" ]]; then
      printf 'no new commits vs %s\n' "${ref#origin/}"
      return 0
    fi
    if git merge-base --is-ancestor "$branch" "$ref"; then
      printf 'merged into %s\n' "${ref#origin/}"
      return 0
    fi
  done
  for (( i = 0; i < n; i++ )); do
    ref="${WT_BASE_REFS[$i]}"
    if _wt_squash_merged "$branch" "$ref"; then
      printf 'squash-merged into %s\n' "${ref#origin/}"
      return 0
    fi
  done
  return 0
}

_wt_branch_status() {
  local branch="$1" prunable="$2"
  local -a status=()
  local b upstream track merged out i n

  if [[ -n "$prunable" ]]; then
    status[${#status[@]}]='directory missing'
  fi

  local is_base=false
  n=${#WT_BASE_REFS[@]}
  for (( i = 0; i < n; i++ )); do
    b="${WT_BASE_REFS[$i]}"
    if [[ "${b#origin/}" == "$branch" ]]; then
      is_base=true
      break
    fi
  done

  if [[ "$is_base" == "true" ]]; then
    status[${#status[@]}]='base branch'
  else
    upstream=''
    track=''
    IFS='|' read -r upstream track < <(git for-each-ref \
      --format='%(upstream:short)|%(upstream:track)' "refs/heads/$branch") || true
    if [[ "$track" == '[gone]' ]]; then
      status[${#status[@]}]='remote deleted'
    elif [[ "$WT_HAS_ORIGIN" == "true" ]] &&
      ! git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      status[${#status[@]}]='not on origin'
    fi

    merged=$(_wt_merge_status "$branch")
    if [[ -n "$merged" ]]; then
      status[${#status[@]}]="$merged"
    fi
  fi

  if (( ${#status[@]} == 0 )); then
    printf '%s\n' '-'
    return 0
  fi

  out="${status[0]}"
  for (( i = 1; i < ${#status[@]}; i++ )); do
    out+=", ${status[$i]}"
  done
  printf '%s\n' "$out"
}

_wt_status_style() {
  case "$1" in
    *'directory missing'*)            printf '%s' "$C_RED" ;;
    *'remote deleted'*|*'detached'*)  printf '%s' "$C_YELLOW" ;;
    *merged*|*'no new commits'*)      printf '%s' "$C_GREEN" ;;
    'base branch'|'-')                printf '%s' "$C_DIM" ;;
    *)                                printf '' ;;
  esac
}

_wt_status() {
  local branch st style i n

  _wt_base_refs
  if (( ${#WT_BASE_REFS[@]} == 0 )); then
    die "no base branch found (develop/dev/main/master)"
  fi

  _wt_scan
  section "Worktree status"

  table_begin
  table_add "BRANCH" "STATUS"
  n=${#WT_PATHS[@]}
  for (( i = 0; i < n; i++ )); do
    branch="${WT_BRANCHES[$i]}"
    if [[ "$branch" == '(detached)' ]]; then
      st='detached'
    else
      st=$(_wt_branch_status "$branch" "${WT_PRUNABLE[$i]}")
    fi
    style=$(_wt_status_style "$st")
    table_add_styled "$style" "$branch" "$st"
  done
  table_flush

  printf '\n'
  muted "Checked against: ${WT_BASE_REFS[*]}"
  if [[ "$WT_HAS_ORIGIN" == "true" ]]; then
    muted "Run 'git fetch --prune' first for an up-to-date remote state."
  fi
  printf '\n'
}

_wt_resolve_base_branch() {
  local current c x dup i n
  local -a proposed=()
  local -a candidates=()

  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || current=''

  if [[ -n "$current" && "$current" != 'HEAD' ]]; then
    proposed[${#proposed[@]}]="$current"
  fi
  for c in develop dev main master; do
    if _wt_branch_exists "$c"; then
      proposed[${#proposed[@]}]="$c"
    fi
  done

  n=${#proposed[@]}
  for (( i = 0; i < n; i++ )); do
    dup=false
    for (( x = 0; x < ${#candidates[@]}; x++ )); do
      if [[ "${candidates[$x]}" == "${proposed[$i]}" ]]; then
        dup=true
        break
      fi
    done
    if [[ "$dup" == "false" ]]; then
      candidates[${#candidates[@]}]="${proposed[$i]}"
    fi
  done

  if (( ${#candidates[@]} == 0 )); then
    die "no base branch found"
  fi
  if (( ${#candidates[@]} == 1 )); then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi

  info "select the source branch"
  local idx
  idx=$(_wt_select 1 0 "${candidates[@]}")
  printf '%s\n' "${candidates[$idx]}"
}

_wt_find_matches() {
  local pattern="$1" branch lb is_local count i n

  WT_LOCAL_MATCHES=()
  WT_REMOTE_MATCHES=()
  WT_REMOTE_TRUNCATED=0

  while IFS= read -r branch; do
    if [[ -n "$branch" ]]; then
      WT_LOCAL_MATCHES[${#WT_LOCAL_MATCHES[@]}]="$branch"
    fi
  done < <(git branch --list "*${pattern}*" --format='%(refname:short)' |
    grep -v '^HEAD$' || true)

  count=0
  while IFS= read -r branch; do
    if [[ -z "$branch" ]]; then
      continue
    fi
    branch="${branch#origin/}"
    is_local=false
    n=${#WT_LOCAL_MATCHES[@]}
    for (( i = 0; i < n; i++ )); do
      lb="${WT_LOCAL_MATCHES[$i]}"
      if [[ "$lb" == "$branch" ]]; then
        is_local=true
        break
      fi
    done
    if [[ "$is_local" == "true" ]]; then
      continue
    fi
    if (( count >= 10 )); then
      WT_REMOTE_TRUNCATED=$(( WT_REMOTE_TRUNCATED + 1 ))
      continue
    fi
    WT_REMOTE_MATCHES[${#WT_REMOTE_MATCHES[@]}]="$branch"
    count=$(( count + 1 ))
  done < <(git branch -r --list "*${pattern}*" --format='%(refname:short)' |
    grep -v -e '^HEAD$' -e '^origin/HEAD$' || true)
}

# _wt_select START_NUM INITIAL ITEM... — arrow keys or a number to choose;
# echoes the chosen index to stdout. The menu itself is drawn on stderr.
_wt_select() {
  local start_num="$1" initial="$2"
  shift 2
  local -a items=("$@")
  local count=${#items[@]}
  local selected=$initial
  local key='' seq='' idx num i interrupted=false

  _wt_select_cleanup() {
    printf '\033[?25h' >&2
    stty echo 2>/dev/null || true
  }
  trap '_wt_select_cleanup' EXIT
  trap 'interrupted=true' INT TERM

  printf '\033[?25l' >&2

  for (( i = 0; i < count; i++ )); do
    num=$(( start_num + i ))
    if (( i == selected )); then
      printf '%s%s > [%d] %s %s\n' "$E_REVERSE" "$E_BOLD" "$num" "${items[$i]}" "$E_RESET" >&2
    else
      printf '   [%d] %s\n' "$num" "${items[$i]}" >&2
    fi
  done

  while true; do
    IFS= read -rsn1 key 2>/dev/null || true
    if [[ "$interrupted" == "true" ]]; then
      printf '\n' >&2
      exit 1
    fi
    case "$key" in
      $'\x1b')
        IFS= read -rsn2 -t 1 seq 2>/dev/null || true
        if [[ -z "$seq" ]]; then
          printf '\n' >&2
          exit 1
        fi
        case "$seq" in
          '[A')
            if (( selected > 0 )); then
              selected=$(( selected - 1 ))
            fi
            ;;
          '[B')
            if (( selected < count - 1 )); then
              selected=$(( selected + 1 ))
            fi
            ;;
        esac
        ;;
      '')
        break
        ;;
      [0-9])
        idx=$(( key - start_num ))
        if (( idx >= 0 && idx < count )); then
          selected=$idx
          break
        fi
        ;;
      q|Q)
        printf '\n' >&2
        exit 1
        ;;
    esac

    printf '\033[%dA' "$count" >&2
    for (( i = 0; i < count; i++ )); do
      num=$(( start_num + i ))
      if (( i == selected )); then
        printf '\033[2K%s%s > [%d] %s %s\n' "$E_REVERSE" "$E_BOLD" "$num" \
          "${items[$i]}" "$E_RESET" >&2
      else
        printf '\033[2K   [%d] %s\n' "$num" "${items[$i]}" >&2
      fi
    done
  done

  printf '\033[?25h' >&2
  printf '\n' >&2
  trap - EXIT INT TERM
  printf '%s\n' "$selected"
}

_wt_create() {
  local branch="$1" is_new="${2:-false}" wpath base

  wpath=$(_wt_path_for_branch "$branch")

  if [[ -d "$wpath" ]]; then
    die "directory already exists: $(relpath "$wpath")"
  fi

  if [[ "$is_new" == "true" ]]; then
    base=$(_wt_resolve_base_branch)
    info "creating worktree with new branch '${branch}' from ${base}"
    git worktree add -b "$branch" "$wpath" "$base" 2>&1 | relay
  elif git show-ref --verify --quiet "refs/heads/$branch"; then
    info "creating worktree for '${branch}'"
    git worktree add "$wpath" "$branch" 2>&1 | relay
  else
    info "creating worktree tracking 'origin/${branch}'"
    git worktree add --track -b "$branch" "$wpath" "origin/$branch" 2>&1 | relay
  fi

  printf '\n' >&2
  relpath "$wpath"
}

_wt_handle_branch() {
  local pattern="$1"
  local branch existing i n nlocal nremote
  local -a all=()

  # An exact local branch needs no search.
  if git show-ref --verify --quiet "refs/heads/${pattern}"; then
    existing=$(_wt_usable_for_branch "$pattern")
    if [[ -n "$existing" ]]; then
      relpath "$existing"
      return 0
    fi
    _wt_create "$pattern"
    return 0
  fi

  _wt_find_matches "$pattern"
  nlocal=${#WT_LOCAL_MATCHES[@]}
  nremote=${#WT_REMOTE_MATCHES[@]}
  all=()
  for (( i = 0; i < nlocal; i++ )); do
    all[${#all[@]}]="${WT_LOCAL_MATCHES[$i]}"
  done
  for (( i = 0; i < nremote; i++ )); do
    all[${#all[@]}]="${WT_REMOTE_MATCHES[$i]}"
  done
  n=${#all[@]}

  if (( n == 0 )); then
    _wt_validate_branch_name "$pattern"
    info "no branches match '${pattern}'"
    printf '\n' >&2
    if ! have_tty; then
      die "no terminal is available to ask whether to create '${pattern}'"
    fi
    if ! ask_yes_no "Create new branch '${pattern}'?"; then
      printf '\n' >&2
      die 'aborted'
    fi
    _wt_create "$pattern" true
    return 0
  fi

  if (( n == 1 )); then
    branch="${all[0]}"
    existing=$(_wt_usable_for_branch "$branch")
    if [[ -n "$existing" ]]; then
      relpath "$existing"
      return 0
    fi
    _wt_create "$branch"
    return 0
  fi

  # Several matches: only a terminal can ask which one.
  if [[ ! -t 2 ]]; then
    err "${n} branches match '${pattern}' and no terminal is available to choose from"
    for (( i = 0; i < n; i++ )); do
      detail "  ${all[$i]}"
    done
    printf '\n' >&2
    detail 'Run this in a terminal to pick one, or pass a more specific pattern.'
    printf '\n' >&2
    return 1
  fi

  local -a display=()
  local has_create=false start_num=1 initial=0 selected_idx

  if [[ "$pattern" == */* ]]; then
    has_create=true
    start_num=0
    initial=1
    display[${#display[@]}]="+ Create new branch '${pattern}'"
  fi

  for (( i = 0; i < n; i++ )); do
    branch="${all[$i]}"
    if (( i < nlocal )); then
      existing=$(_wt_existing_for_branch "$branch")
      if [[ -n "$existing" && ! -d "$existing" ]]; then
        display[${#display[@]}]="${branch} (stale)"
      elif [[ -n "$existing" ]]; then
        display[${#display[@]}]="${branch} (active)"
      else
        display[${#display[@]}]="$branch"
      fi
    else
      display[${#display[@]}]="${branch} (remote)"
    fi
  done

  if (( WT_REMOTE_TRUNCATED > 0 )); then
    info "${WT_REMOTE_TRUNCATED} more remote branches not shown"
  fi

  info "branches matching '*${pattern}*'"
  selected_idx=$(_wt_select "$start_num" "$initial" "${display[@]}")

  if [[ "$has_create" == "true" ]]; then
    if (( selected_idx == 0 )); then
      _wt_validate_branch_name "$pattern"
      _wt_create "$pattern" true
      return 0
    fi
    selected_idx=$(( selected_idx - 1 ))
  fi

  branch="${all[$selected_idx]}"
  existing=$(_wt_usable_for_branch "$branch")
  if [[ -n "$existing" ]]; then
    relpath "$existing"
    return 0
  fi
  _wt_create "$branch"
}

_wt_remove() {
  local branch="$1" wt_path out line

  wt_path=$(_wt_existing_for_branch "$branch")
  if [[ -z "$wt_path" ]]; then
    die "no worktree found for branch '${branch}'"
  fi

  info "removing worktree for '${branch}' at $(relpath "$wt_path")"

  if [[ "$WT_FORCE" == "true" ]]; then
    set -- remove --force "$wt_path"
  else
    set -- remove "$wt_path"
  fi

  if out=$(git worktree "$@" 2>&1); then
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out" | relay
    fi
    printf '\n' >&2
    return 0
  fi

  printf '\n' >&2

  # Everything below explains the failure above it, so it is set in one level.
  local saved_indent="$G_INDENT"
  G_INDENT='  '

  if [[ "$out" == *'contains modified or untracked files'* ]] ||
    [[ "$out" == *'use --force'* ]]; then
    err "cannot remove the worktree for '${branch}'"
    detail "$(relpath "$wt_path") holds changes that are not committed anywhere."
    printf '\n' >&2

    if git -C "$wt_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      detail 'Uncommitted files:'
      while IFS= read -r line; do
        if [[ -n "$line" ]]; then
          detail "  ${line}"
        fi
      done < <(git -C "$wt_path" status --short --untracked-files=all 2>/dev/null)
      printf '\n' >&2
    fi

    detail 'Removing the worktree would discard them, so git refuses. Commit or'
    detail 'stash the changes first, or discard them and remove it anyway with:'
    printf '\n%s    %s%s%s\n' "$G_INDENT" "$E_BOLD" "g wt -rf ${branch}" "$E_RESET" >&2
  elif [[ "$out" == *'locked working tree'* ]]; then
    err "cannot remove the worktree for '${branch}'"
    detail "$(relpath "$wt_path") is locked, so git will not remove it."
    printf '\n' >&2
    detail 'Unlock it first, then remove it again:'
    printf '\n%s    %s%s%s\n' "$G_INDENT" "$E_BOLD" \
      "git worktree unlock $(relpath "$wt_path")" "$E_RESET" >&2
  else
    printf '%s\n' "$out" | relay
  fi

  G_INDENT="$saved_indent"
  printf '\n' >&2
  return 1
}

_wt_fetch() {
  local branch="$1" existing out

  info "fetching '${branch}' from origin"
  if ! out=$(git fetch origin "$branch" 2>&1); then
    printf '\n' >&2
    err "failed to fetch '${branch}' from origin"
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out" | relay
    fi
    printf '\n' >&2
    return 1
  fi
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out" | relay
    printf '\n' >&2
  fi

  if ! git show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
    die "branch '${branch}' does not exist on origin"
  fi

  existing=$(_wt_usable_for_branch "$branch")
  if [[ -n "$existing" ]]; then
    relpath "$existing"
    return 0
  fi

  _wt_create "$branch"
}

wt_usage() {
  section "g worktree — worktrees by branch name"

  cat <<'EOF'
Usage:
  g worktree [options] [BRANCH-PATTERN]
  g wt       [options] [BRANCH-PATTERN]

With no arguments, lists the active worktrees. With a pattern, opens the
worktree for the matching branch, creating it if needed. Several matches open
an interactive picker, and a SECTION/NAME pattern that matches nothing offers
to create the branch.

Options:
  -b, --branch BRANCH...   Fetch BRANCH from origin and create its worktree
  -r, --remove BRANCH...   Remove the worktree for BRANCH
  -f, --force              With -r, remove even when the worktree has modified
                           or untracked files (-rf is shorthand for -r --force)
  -s, --status             Report worktrees whose remote branch is gone, or
                           whose branch is merged — including squash merges —
                           into develop/dev/main/master
  -h, --help               Show this help

The worktree path is printed on stdout and everything else on stderr, so
`cd "$(g wt feature/thing)"` works.
EOF

  printf '\n'
}

# ── g branches ──────────────────────────────────────────────────────────────
# Ported from ~/bitbucket/pftylr/utils/git/git-branch-list. The integration
# branch is looked up in the same order the worktree command uses, so both
# commands name the same base in a given repository.

BR_SHOW_ALL=false
BR_MERGED_ONLY=false

# base_ref — the integration branch for `g branches`: the first of main,
# master, develop that exists, local before origin. A branch merged here is
# deletable here whether or not the merge has been pushed. (`g wt -s` asks a
# different question — is it merged upstream yet — so it prefers origin's copy.)
base_ref() {
  local b
  for b in main master develop; do
    if git rev-parse --verify --quiet "$b" >/dev/null 2>&1; then
      printf '%s\n' "$b"
      return 0
    fi
    if git rev-parse --verify --quiet "origin/$b" >/dev/null 2>&1; then
      printf 'origin/%s\n' "$b"
      return 0
    fi
  done
  return 0
}

br_usage() {
  section "g branches — local branches at a glance"

  cat <<'EOF'
Usage:
  g branches [options]

Lists local branches with their author, commit count, first and last commit,
and whether the branch is safe to delete.

Options:
  -a, --all      Include branches by other authors (the default shows yours)
  -m, --merged   Only show branches already merged into the base branch,
                 leaving out the base and the branch you are on
  -h, --help     Show this help

The base branch is the first of main, master, develop that exists, local
before origin. Commits are counted from the merge-base with the base, so a
branch's own work is what gets measured, and STATUS reads `current`,
`merged (deletable)` or `+ahead/-behind`.

`g wt -s` looks at origin's copy of the base instead, because it answers a
different question: whether the branch has been merged upstream.
EOF

  printf '\n'
}

cmd_branches() {
  BR_SHOW_ALL=false
  BR_MERGED_ONLY=false

  while (( $# )); do
    case "$1" in
      -h|--help)
        br_usage
        return 0
        ;;
      -a|--all)    BR_SHOW_ALL=true;    shift ;;
      -m|--merged) BR_MERGED_ONLY=true; shift ;;
      -[!-]?*)
        local flags="${1#-}"
        local -a split=()
        shift
        while [[ -n "$flags" ]]; do
          split[${#split[@]}]="-${flags:0:1}"
          flags="${flags:1}"
        done
        set -- "${split[@]}" "$@"
        ;;
      -*) die "unknown option: $1" ;;
      *)  die 'usage: g branches [-a] [-m]' ;;
    esac
  done

  require_repo

  local me base current
  me=$(git config user.name || true)
  if [[ -z "$me" ]]; then
    die 'git user.name is not configured'
  fi

  base=$(base_ref)
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || current=''

  local -a merged_branches=()
  local b
  if [[ -n "$base" ]]; then
    while IFS= read -r b; do
      if [[ -n "$b" ]]; then
        merged_branches[${#merged_branches[@]}]="$b"
      fi
    done < <(git branch --merged "$base" --format='%(refname:short)' 2>/dev/null || true)
  fi

  local branch author created marker range mb count first last_date last_rel
  local ahead behind status style display_last is_merged
  local total=0 merged_shown=0 k n_merged

  n_merged=${#merged_branches[@]}
  local -a branches=()
  local -a authors=()
  local -a counts=()
  local -a firsts=()
  local -a lasts=()
  local -a statuses=()
  local -a styles=()

  while IFS='|' read -r branch author created; do
    if [[ -z "$branch" ]]; then
      continue
    fi

    if [[ "$BR_SHOW_ALL" != "true" && "$author" != "$me" ]]; then
      continue
    fi

    is_merged=false
    for (( k = 0; k < n_merged; k++ )); do
      if [[ "${merged_branches[$k]}" == "$branch" ]]; then
        is_merged=true
        break
      fi
    done

    if [[ "$BR_MERGED_ONLY" == "true" ]]; then
      if [[ "$is_merged" != "true" ]]; then
        continue
      fi
      # The base branch and the one you are on are not deletion candidates.
      if [[ "$branch" == "$current" || "$branch" == "$base" ||
        "$branch" == "${base#origin/}" ]]; then
        continue
      fi
    fi

    # Count only this branch's own work, not the base's history.
    range="$branch"
    if [[ -n "$base" && "$branch" != "$base" && "$branch" != "${base#origin/}" ]]; then
      mb=$(git merge-base "$base" "$branch" 2>/dev/null) || mb=''
      if [[ -n "$mb" ]]; then
        range="${mb}..${branch}"
      fi
    fi

    count=$(git rev-list --count "$range" 2>/dev/null) || count='?'
    first=$(git log "$range" --format='%cs' --reverse 2>/dev/null | head -1) || true
    if [[ -z "$first" ]]; then
      first='-'
    fi

    # The tip's date, taken from the branch itself: for a merged branch the
    # merge-base range is empty, and two dashes said less than the real date.
    last_date=''
    last_rel=''
    IFS='|' read -r last_date last_rel < <(
      git log -1 --format='%cs|%cr' "$branch" 2>/dev/null || true
    ) || true
    if [[ -z "$last_date" ]]; then
      last_date='-'
      display_last='-'
    elif [[ -n "$last_rel" ]]; then
      display_last="${last_date} (${last_rel})"
    else
      display_last="$last_date"
    fi

    status=''
    style=''
    if [[ "$branch" == "$current" ]]; then
      status='current'
      style="$C_CYAN"
    elif [[ "$is_merged" == "true" ]]; then
      status='merged (deletable)'
      style="$C_GREEN"
      merged_shown=$(( merged_shown + 1 ))
    elif [[ -n "$base" ]]; then
      ahead=$(git rev-list --count "${base}..${branch}" 2>/dev/null) || ahead=0
      behind=$(git rev-list --count "${branch}..${base}" 2>/dev/null) || behind=0
      status="+${ahead}/-${behind}"
    fi

    marker=''
    if [[ "$BR_SHOW_ALL" == "true" && "$author" == "$me" ]]; then
      marker=' (me)'
    fi

    branches[${#branches[@]}]="$branch"
    authors[${#authors[@]}]="${author}${marker}"
    counts[${#counts[@]}]="$count"
    firsts[${#firsts[@]}]="$first"
    lasts[${#lasts[@]}]="$display_last"
    statuses[${#statuses[@]}]="$status"
    styles[${#styles[@]}]="$style"
    total=$(( total + 1 ))
  done < <(git for-each-ref --format='%(refname:short)|%(authorname)|%(creatordate:short)' \
    refs/heads/ --sort=-committerdate)

  section 'Branches'

  if (( total == 0 )); then
    printf '\n'
    muted 'No branches to show.'
  else
    table_begin
    table_add 'BRANCH' 'AUTHOR' "$(printf '%5s' 'CMTS')" 'FIRST' 'LAST' 'STATUS'
    for (( k = 0; k < total; k++ )); do
      table_add_styled "${styles[$k]}" \
        "${branches[$k]}" "${authors[$k]}" "$(printf '%5s' "${counts[$k]}")" \
        "${firsts[$k]}" "${lasts[$k]}" "${statuses[$k]}"
    done
    table_flush
  fi

  printf '\n'
  if [[ -n "$base" ]]; then
    kv 'Base' "$base"
  else
    kv 'Base' 'none found (develop, dev, main, master)'
  fi
  kv 'User' "$me"
  if (( merged_shown > 0 )); then
    kv 'Showing' "$(_plural "$total" '1 branch' "${total} branches"), ${merged_shown} merged (safe to delete)"
  else
    kv 'Showing' "$(_plural "$total" '1 branch' "${total} branches")"
  fi
  printf '\n'
  if (( merged_shown > 0 )); then
    muted 'Delete one with: git branch -d NAME'
    printf '\n'
  fi
}

# ── g untracked ─────────────────────────────────────────────────────────────
# Ported from ~/bitbucket/pftylr/utils/git/git-untracked.
#
# The original ran stat and date once per file: 200 files cost over three
# seconds here. This asks stat for every file in one batch and formats the
# sizes in bash, so a large tree still lists instantly.

UT_INCLUDE_IGNORED=false

case "$(uname)" in
  Darwin)
    UT_STAT=(-f '%Sm|%m|%z|%N' -t '%Y-%m-%d %H:%M')
    ;;
  *)
    UT_STAT=(-c '%y|%Y|%s|%n')
    ;;
esac

# _ut_human_bytes_into VARIABLE BYTES — format a byte count, without forking.
_ut_human_bytes_into() {
  local __hb_name="$1" b="${2:-0}"
  if (( b >= 1073741824 )); then
    printf -v "$__hb_name" '%d.%d GiB' $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
  elif (( b >= 1048576 )); then
    printf -v "$__hb_name" '%d.%d MiB' $(( b / 1048576 )) $(( (b % 1048576) * 10 / 1048576 ))
  elif (( b >= 1024 )); then
    printf -v "$__hb_name" '%d.%d KiB' $(( b / 1024 )) $(( (b % 1024) * 10 / 1024 ))
  else
    printf -v "$__hb_name" '%d B' "$b"
  fi
}

_ut_human_bytes() {
  local __hb_out
  _ut_human_bytes_into __hb_out "${1:-0}"
  printf '%s' "$__hb_out"
}

ut_usage() {
  section "g untracked — files git is not tracking yet"

  cat <<'EOF'
Usage:
  g untracked [options]

Lists every untracked file in the repository with the date it was last
modified and its size, newest first. Paths are shown relative to the current
directory, and the list covers the whole repository, not just this directory.

Options:
  -a, --all, --ignored   Include ignored files, each marked (ignored)
  -h, --help             Show this help
EOF

  printf '\n'
}

cmd_untracked() {
  UT_INCLUDE_IGNORED=false

  while (( $# )); do
    case "$1" in
      -h|--help)
        ut_usage
        return 0
        ;;
      -a|--all|--ignored)
        UT_INCLUDE_IGNORED=true
        shift
        ;;
      -[!-]?*)
        local flags="${1#-}"
        local -a split=()
        shift
        while [[ -n "$flags" ]]; do
          split[${#split[@]}]="-${flags:0:1}"
          flags="${flags:1}"
        done
        set -- "${split[@]}" "$@"
        ;;
      -*) die "unknown option: $1" ;;
      *)  die 'usage: g untracked [-a]' ;;
    esac
  done

  require_repo

  local root listing
  root=$(git rev-parse --show-toplevel)

  # Each entry is flag|date|epoch|bytes|path: the flag records whether git
  # ignores the file, and stat supplies the rest in one call per batch.
  # A file that vanishes mid-listing makes stat fail, hence the || true.
  listing=$(
    {
      ( cd "$root" && git ls-files -z --others --exclude-standard |
        xargs -0 stat "${UT_STAT[@]}" 2>/dev/null ) | sed 's/^/u|/'
      if [[ "$UT_INCLUDE_IGNORED" == "true" ]]; then
        ( cd "$root" && git ls-files -z --others --ignored --exclude-standard |
          xargs -0 stat "${UT_STAT[@]}" 2>/dev/null ) | sed 's/^/i|/'
      fi
    } | sort -s -t'|' -k3,3 -nr
  ) || true

  local flag date epoch bytes path i ut_size ut_path ut_pad ut_marker cell style
  local total=0 count=0 ignored=0

  # Rows go straight into the table: collecting them in arrays first means
  # walking every file twice, which is measurable at a few thousand files.
  table_begin
  table_add 'MODIFIED' "$(printf '%9s' 'SIZE')" 'FILE'

  while IFS='|' read -r flag date epoch bytes path; do
    if [[ -z "${path-}" ]]; then
      continue
    fi

    _ut_human_bytes_into ut_size "$bytes"
    printf -v ut_pad '%9s' "$ut_size"
    relpath_into ut_path "${root}/${path}"

    cell="$ut_path"
    style=''
    if [[ "$flag" == 'i' ]]; then
      paint_into ut_marker "$C_YELLOW" '  (ignored)'
      cell="${cell}${ut_marker}"
      style="$C_DIM"
    fi

    table_add_styled "$style" "${date:0:16}" "$ut_pad" "$cell"
    total=$(( total + bytes ))
    count=$(( count + 1 ))
    if [[ "$flag" == 'i' ]]; then
      ignored=$(( ignored + 1 ))
    fi
  done <<<"$listing"

  if [[ "$UT_INCLUDE_IGNORED" == "true" ]]; then
    section 'Untracked and ignored files'
  else
    section 'Untracked files'
  fi

  if (( count == 0 )); then
    printf '\n'
    if [[ "$UT_INCLUDE_IGNORED" == "true" ]]; then
      muted 'Nothing untracked and nothing ignored.'
    else
      muted 'No untracked files.'
    fi
    printf '\n'
    return 0
  fi

  table_flush

  printf '\n'
  if (( ignored > 0 )); then
    kv 'Files' "$(_plural "$count" '1 file' "${count} files"), ${ignored} ignored"
  else
    kv 'Files' "$(_plural "$count" '1 file' "${count} files")"
  fi
  kv 'Total' "$(paint "$C_BOLD" "$(_ut_human_bytes "$total")")"
  printf '\n'
}

# ── g branch-summary ────────────────────────────────────────────────────────
# Ported from ~/bitbucket/pftylr/utils/git/git-branch-summary.

BS_VERBOSE=false

# The nearest ancestor branch: the one that leaves the fewest commits behind.
# Only branches HEAD already contains count — a sibling that shares our fork
# point would produce the right diff under the wrong name — and on a tie a
# well-known base branch wins over a feature branch.
_bs_nearest_base() {
  local current branch count rank best='' best_count=0 best_rank=9

  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0

  while IFS= read -r branch; do
    if [[ -z "$branch" || "$branch" == "$current" ]]; then
      continue
    fi
    if ! git merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
      continue
    fi
    count=$(git rev-list --count "${branch}..HEAD" 2>/dev/null) || continue

    rank=1
    case "${branch#origin/}" in
      main|master|develop) rank=0 ;;
    esac

    if [[ -z "$best" ]] || (( count < best_count )) ||
      (( count == best_count && rank < best_rank )); then
      best="$branch"
      best_count=$count
      best_rank=$rank
    fi
  done < <(git branch --format='%(refname:short)' 2>/dev/null)

  printf '%s\n' "$best"
}

_bs_detect_base() {
  local best
  best=$(_bs_nearest_base)
  if [[ -n "$best" ]]; then
    printf '%s\n' "$best"
    return 0
  fi
  base_ref
}

bs_usage() {
  section "g branch-summary — one branch, against its base"

  cat <<'EOF'
Usage:
  g branch-summary [options] [BASE]

Summarises the current branch against BASE: how many commits it is ahead, who
wrote them, when it started, and every file it adds, modifies, deletes or
renames.

Options:
  -v, --verbose   List the commits as well
  -h, --help      Show this help

BASE defaults to the nearest ancestor branch — the one that leaves the fewest
commits behind — falling back to main, master or develop, local before origin.
EOF

  printf '\n'
}

cmd_branch_summary() {
  BS_VERBOSE=false

  while (( $# )); do
    case "$1" in
      -h|--help)
        bs_usage
        return 0
        ;;
      -v|--verbose)
        BS_VERBOSE=true
        shift
        ;;
      -[!-]?*)
        local flags="${1#-}"
        local -a split=()
        shift
        while [[ -n "$flags" ]]; do
          split[${#split[@]}]="-${flags:0:1}"
          flags="${flags:1}"
        done
        set -- "${split[@]}" "$@"
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        break
        ;;
    esac
  done

  if (( $# > 1 )); then
    die 'usage: g branch-summary [-v] [BASE]'
  fi

  require_repo

  local current base mb
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) ||
    die 'cannot read the current branch'

  if (( $# == 1 )); then
    base="$1"
    if ! git rev-parse --verify --quiet "$base" >/dev/null; then
      die "no such branch: ${base}"
    fi
  else
    base=$(_bs_detect_base)
    if [[ -z "$base" ]]; then
      die 'cannot detect a base branch; name one: g branch-summary BASE'
    fi
  fi

  mb=$(git merge-base "$base" HEAD 2>/dev/null) ||
    die "'${base}' and HEAD have no common ancestor"

  local count first_line first_date first_rel last_rel stat
  count=$(git rev-list --count "$mb"..HEAD 2>/dev/null) || count=0

  first_line=''
  first_line=$(git log --reverse --format='%ai|%ar' "$mb"..HEAD 2>/dev/null | head -1) || true
  first_date=''
  first_rel=''
  if [[ -n "$first_line" ]]; then
    first_date="${first_line%%|*}"
    first_date="${first_date%% *}"
    first_rel="${first_line#*|}"
  fi

  last_rel=''
  last_rel=$(git log -1 --format='%ar' "$mb"..HEAD 2>/dev/null) || true

  local -a authors=()
  local a
  while IFS= read -r a; do
    if [[ -n "$a" ]]; then
      authors[${#authors[@]}]="$a"
    fi
  done < <(git log --format='%aN' "$mb"..HEAD 2>/dev/null | sort -u)

  stat=$(git diff --shortstat "$mb"..HEAD 2>/dev/null) || stat=''

  # One pass over --name-status supplies both the counts and the file lists.
  local -a added=()
  local -a modified=()
  local -a deleted=()
  local -a renamed=()
  local st p1 p2

  while IFS=$'\t' read -r st p1 p2; do
    if [[ -z "${st-}" ]]; then
      continue
    fi
    case "${st:0:1}" in
      A) added[${#added[@]}]="$p1" ;;
      D) deleted[${#deleted[@]}]="$p1" ;;
      R)
        if (( G_UNICODE )); then
          renamed[${#renamed[@]}]="${p1} → ${p2-}"
        else
          renamed[${#renamed[@]}]="${p1} -> ${p2-}"
        fi
        ;;
      *) modified[${#modified[@]}]="$p1" ;;
    esac
  done < <(git diff --name-status "$mb"..HEAD 2>/dev/null || true)

  local n_added=${#added[@]} n_modified=${#modified[@]}
  local n_deleted=${#deleted[@]} n_renamed=${#renamed[@]}
  local total=$(( n_added + n_modified + n_deleted + n_renamed ))
  local i joined='' changes pig

  section 'Branch summary'

  if [[ "$current" == 'HEAD' ]]; then
    kv 'Branch' '(detached HEAD)'
  else
    kv 'Branch' "$(paint "$C_BOLD" "$current")"
  fi
  kv 'Base' "$base"

  if [[ -n "$first_date" ]]; then
    kv 'Created' "${first_date} (${first_rel})"
  fi
  if (( count > 0 )); then
    kv 'Commits' "${count} (last ${last_rel})"
  else
    kv 'Commits' 'none'
  fi

  if (( ${#authors[@]} == 1 )); then
    kv 'Author' "${authors[0]}"
  elif (( ${#authors[@]} > 1 )); then
    joined=''
    for (( i = 0; i < ${#authors[@]}; i++ )); do
      if [[ -n "$joined" ]]; then
        joined+=', '
      fi
      joined+="${authors[$i]}"
    done
    kv 'Authors' "$joined"
  fi

  if (( total > 0 )); then
    changes=''
    if (( n_added )); then
      paint_into pig "$C_GREEN" "+${n_added} added"
      changes+="$pig"
    fi
    if (( n_modified )); then
      paint_into pig "$C_YELLOW" "~${n_modified} modified"
      changes+="${changes:+, }$pig"
    fi
    if (( n_deleted )); then
      paint_into pig "$C_RED" "-${n_deleted} deleted"
      changes+="${changes:+, }$pig"
    fi
    if (( n_renamed )); then
      paint_into pig "$C_CYAN" ">${n_renamed} renamed"
      changes+="${changes:+, }$pig"
    fi
    kv 'Changes' "$changes"
    if [[ -n "$stat" ]]; then
      kv 'Diff' "$stat"
    fi
  fi

  if (( total == 0 )); then
    printf '\n'
    muted "No changes against ${base}."
    printf '\n'
  else
    if (( n_added )); then
      printf '\n'
      muted 'Added'
      for (( i = 0; i < n_added; i++ )); do
        item "$C_GREEN" '+' "${added[$i]}"
      done
    fi
    if (( n_modified )); then
      printf '\n'
      muted 'Modified'
      for (( i = 0; i < n_modified; i++ )); do
        item "$C_YELLOW" '~' "${modified[$i]}"
      done
    fi
    if (( n_deleted )); then
      printf '\n'
      muted 'Deleted'
      for (( i = 0; i < n_deleted; i++ )); do
        item "$C_RED" '-' "${deleted[$i]}"
      done
    fi
    if (( n_renamed )); then
      printf '\n'
      muted 'Renamed'
      for (( i = 0; i < n_renamed; i++ )); do
        item "$C_CYAN" '>' "${renamed[$i]}"
      done
    fi
  fi

  if [[ "$BS_VERBOSE" == "true" ]] && (( count > 0 )); then
    printf '\n'
    muted 'Commit log'
    local h s an ar
    while IFS=$'\t' read -r h s an ar; do
      if [[ -z "${h-}" ]]; then
        continue
      fi
      printf '  %s%s%s  %s %s(%s, %s)%s\n' \
        "$C_YELLOW" "$h" "$C_RESET" "$s" "$C_DIM" "$an" "$ar" "$C_RESET"
    done < <(git log --format='%h%x09%s%x09%aN%x09%ar' "$mb"..HEAD 2>/dev/null || true)
  fi

  printf '\n'
}

# ── g log ───────────────────────────────────────────────────────────────────
# Ported from ~/bitbucket/pftylr/utils/git/git-log, which printed
# `git log MERGE_BASE..HEAD --name-status` and assumed origin/main was there.
# The range is the same, but the base is discovered (see _log_detect_base), and
# one machine-separated pass (%x1f between fields, %x1e at the start of each
# commit) is enough to lay every commit out as its own block.

LOG_STAT=false
LOG_WANT_BODY=true
LOG_LIMIT=0
LOG_LIMIT_SET=false
LOG_PRINTED=false
LOG_H='' LOG_DATE='' LOG_WHEN='' LOG_NAME='' LOG_MAIL='' LOG_SUBJECT=''
LOG_PARENTS=''
LOG_FILES=()
LOG_NUM=()
LOG_TEXT=()

# _log_header LINE — split a %x1f-separated commit header into the LOG_*
# globals. `set --` does the splitting, which avoids the herestring — and so the
# temporary file — that would otherwise be paid once per commit.
_log_header() {
  local save_ifs="$IFS"

  IFS=$'\x1f'
  set -f
  # shellcheck disable=SC2086
  set -- $1
  set +f
  IFS="$save_ifs"

  LOG_H="${1-}"
  LOG_DATE="${2-}"
  LOG_WHEN="${3-}"
  LOG_NAME="${4-}"
  LOG_MAIL="${5-}"
  LOG_SUBJECT="${6-}"
  LOG_PARENTS="${7-}"
}

# _log_file LETTER PATHS — record one changed file. PATHS holds two tab-separated
# paths when the change is a rename or a copy.
_log_file() {
  local letter="$1" paths="$2" arrow=' -> '

  if (( G_UNICODE )); then
    arrow=' → '
  fi

  case "${letter:0:1}" in
    R|C) paths="${paths%%$'\t'*}${arrow}${paths#*$'\t'}" ;;
  esac

  LOG_FILES[${#LOG_FILES[@]}]="${letter:0:1}"$'\x1f'"${paths}"
}

_log_reset() {
  LOG_H='' LOG_DATE='' LOG_WHEN='' LOG_NAME='' LOG_MAIL='' LOG_SUBJECT=''
  LOG_PARENTS=''
  LOG_FILES=()
  LOG_NUM=()
  LOG_TEXT=()
}

# _log_emit — print the commit sitting in the LOG_* globals.
_log_emit() {
  local pad i n letter path entry add del colour arrow=' -> '

  if [[ -z "$LOG_H" ]]; then
    return 0
  fi

  if [[ "$LOG_PRINTED" == true ]]; then
    printf '\n'
  fi
  LOG_PRINTED=true

  printf '  %s%s%s  %s%s%s\n' \
    "$C_YELLOW" "$LOG_H" "$C_RESET" "$C_BOLD" "$LOG_SUBJECT" "$C_RESET"

  printf -v pad '%*s' $(( ${#LOG_H} + 4 )) ''

  # Git prints no file list for a merge, so say why the block is short.
  local parents=1 rest_p="$LOG_PARENTS"
  while [[ "$rest_p" == *' '* ]]; do
    rest_p="${rest_p#* }"
    parents=$(( parents + 1 ))
  done

  local extra=''
  if (( parents > 1 )); then
    extra=", merge of ${parents} parents"
  fi

  printf '%s%s%s  %s <%s>, %s%s%s\n' \
    "$pad" "$C_DIM" "$LOG_DATE" "$LOG_NAME" "$LOG_MAIL" "$LOG_WHEN" "$extra"     "$C_RESET"

  # Blank lines are only kept inside the body: leading and trailing ones are
  # git's own spacing between the message and the file list.
  local start=0 end=${#LOG_TEXT[@]}
  while (( start < end )) && [[ -z "${LOG_TEXT[$start]}" ]]; do
    start=$(( start + 1 ))
  done
  while (( end > start )) && [[ -z "${LOG_TEXT[$(( end - 1 ))]}" ]]; do
    end=$(( end - 1 ))
  done

  if (( start < end )); then
    printf '\n'
    for (( i = start; i < end; i++ )); do
      if [[ -n "${LOG_TEXT[$i]}" ]]; then
        printf '%s%s\n' "$pad" "${LOG_TEXT[$i]}"
      else
        printf '\n'
      fi
    done
  fi

  n=${#LOG_FILES[@]}
  if (( n > 0 )); then
    if (( G_UNICODE )); then
      arrow=' → '
    fi
    printf '\n'
    for (( i = 0; i < n; i++ )); do
      entry="${LOG_FILES[$i]}"
      letter="${entry%%$'\x1f'*}"
      path="${entry#*$'\x1f'}"

      colour="$C_YELLOW"
      case "$letter" in
        A) colour="$C_GREEN" ;;
        D) colour="$C_RED" ;;
        R) colour="$C_CYAN" ;;
      esac

      if [[ "$LOG_STAT" == "true" ]] && (( i < ${#LOG_NUM[@]} )); then
        entry="${LOG_NUM[$i]}"
        add="${entry%%$'\x1f'*}"
        del="${entry#*$'\x1f'}"
        if [[ "$add" != '-' ]]; then
          add="+${add}"
        fi
        if [[ "$del" != '-' ]]; then
          del="-${del}"
        fi
        if [[ "$path" == *' => '* ]]; then
          path="${path/ => /$arrow}"
        fi
        printf '%s%s%s%s  %4s %4s  %s\n' \
          "$pad" "$colour" "$letter" "$C_RESET" "$add" "$del" "$path"
      else
        printf '%s%s%s%s  %s\n' "$pad" "$colour" "$letter" "$C_RESET" "$path"
      fi
    done
  fi
}

# _log_detect_base — branch-summary's rule, with one difference: once a
# well-known integration branch is behind HEAD, it wins outright. A sibling
# branch merged back in is nearer by commit count and would make the range
# "everything since that merge", which answers a question nobody asked.
_log_detect_base() {
  local b
  for b in main origin/main master origin/master develop origin/develop; do
    if git rev-parse --verify --quiet "$b" >/dev/null 2>&1 &&
      git merge-base --is-ancestor "$b" HEAD 2>/dev/null; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  _bs_nearest_base
}

log_usage() {
  section "g log — the whole history, one commit at a time"

  cat <<'EOF'
Usage:
  g log [options]

Lists the history of the current branch, newest first, in the same commit
blocks g branch-log uses: hash, subject, author, age, message and changed
files. Nothing stops the walk, so it runs back through the whole history,
showing 20 commits unless -n says otherwise.

Options:
  -n, --limit N   Show at most N commits (0 for all of them; default 20)
  -s, --stat      Add per-file added and removed line counts
      --no-body   Leave out commit message bodies
  -h, --help      Show this help

For just the commits this branch adds, use g branch-log.
EOF

  printf '\n'
}

branch_log_usage() {
  section "g branch-log — the commits this branch adds"

  cat <<'EOF'
Usage:
  g branch-log [options] [BASE]

Lists the commits on the current branch that BASE does not have, newest first,
each with its author, age, message and the files it changed.

Options:
  -n, --limit N   Show at most N commits (default: all of them)
  -s, --stat      Add per-file added and removed line counts
      --no-body   Leave out commit message bodies
  -h, --help      Show this help

BASE defaults to main, master or develop when HEAD already contains one of
them, local before origin, and otherwise to the nearest ancestor branch. On a
base branch itself that leaves the commits you have not pushed yet.

g branch-summary always takes the nearest ancestor; a sibling branch merged
back in is nearer by commit count but makes a useless range. g log shows the
whole history instead, in the same format.
EOF

  printf '\n'
}

cmd_log() {
  _log_main history "$@"
}

cmd_branch_log() {
  _log_main branch "$@"
}

# _log_main MODE [options] [BASE] — the one implementation behind both commands.
# MODE is `branch` for the range up to the base, `history` for the whole of
# HEAD; the range is settled first and everything after it is shared, so the two
# commands cannot drift apart in either behaviour or formatting.
_log_main() {
  local mode="$1" usage_line='g log [-n N] [-s] [--no-body]'
  shift

  LOG_STAT=false
  LOG_WANT_BODY=true
  LOG_LIMIT=0
  LOG_LIMIT_SET=false
  local base_arg=''

  if [[ "$mode" == "branch" ]]; then
    usage_line='g branch-log [-n N] [-s] [--no-body] [BASE]'
  fi

  while (( $# )); do
    case "$1" in
      -h|--help)
        if [[ "$mode" == "branch" ]]; then
          branch_log_usage
        else
          log_usage
        fi
        return 0
        ;;
      -s|--stat)
        LOG_STAT=true
        shift
        ;;
      --no-body)
        LOG_WANT_BODY=false
        shift
        ;;
      -n|--limit)
        if (( $# < 2 )); then
          die "usage: ${usage_line}"
        fi
        LOG_LIMIT="$2"
        LOG_LIMIT_SET=true
        shift 2
        ;;
      -n?*)
        LOG_LIMIT="${1#-n}"
        LOG_LIMIT_SET=true
        shift
        ;;
      --limit=*)
        LOG_LIMIT="${1#*=}"
        LOG_LIMIT_SET=true
        shift
        ;;
      -[!-]?*)
        local flags="${1#-}"
        local -a split=()
        shift
        while [[ -n "$flags" ]]; do
          split[${#split[@]}]="-${flags:0:1}"
          flags="${flags:1}"
        done
        set -- "${split[@]}" "$@"
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ "$mode" != "branch" ]]; then
          die "g log takes no arguments; 'g branch-log $1' is the comparison"
        fi
        if [[ -n "$base_arg" ]]; then
          die "usage: ${usage_line}"
        fi
        base_arg="$1"
        shift
        ;;
    esac
  done

  case "$LOG_LIMIT" in
    ''|*[!0-9]*) die "not a number of commits: ${LOG_LIMIT}" ;;
  esac

  require_repo

  local current base mb range fork='' whole=false
  if ! current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); then
    die 'no commits yet — there is nothing to log'
  fi

  if [[ "$mode" == "branch" ]]; then
    if [[ -n "$base_arg" ]]; then
      base="$base_arg"
      if ! git rev-parse --verify --quiet "$base" >/dev/null; then
        die "no such branch: ${base}"
      fi
    else
      base=$(_log_detect_base)
      # Standing on the base itself, the interesting question is what has not
      # been pushed yet — and with no origin there is nothing to compare with.
      if [[ -n "$base" && "$base" == "$current" ]]; then
        if git rev-parse --verify --quiet "origin/${current}" >/dev/null 2>&1; then
          base="origin/${current}"
        else
          base=''
        fi
      fi
      if [[ -z "$base" ]]; then
        die 'no base branch to compare with; g log shows the whole history'
      fi
    fi

    mb=$(git merge-base "$base" HEAD 2>/dev/null) ||
      die "'${base}' and HEAD have no common ancestor"
    range="${mb}..HEAD"
    fork=$(git rev-parse --short "$mb" 2>/dev/null) || fork=''
    # Only worth naming the fork point when the base has moved past it.
    if [[ "$(git rev-parse "$base" 2>/dev/null)" == "$mb" ]]; then
      fork=''
    fi
  else
    whole=true
    range='HEAD'
  fi

  local total shown limit
  total=$(git rev-list --count "$range" 2>/dev/null) || total=0

  limit=$LOG_LIMIT
  if (( limit == 0 )) && [[ "$whole" == "true" && "$LOG_LIMIT_SET" == "false" ]]; then
    limit=20
  fi
  shown=$total
  if (( limit > 0 && limit < total )); then
    shown=$limit
  fi

  section 'Commits'

  if [[ "$current" == 'HEAD' ]]; then
    kv 'Branch' '(detached HEAD)'
  else
    kv 'Branch' "$(paint "$C_BOLD" "$current")"
  fi

  if [[ "$whole" == "false" ]]; then
    kv 'Base' "${base}${fork:+ (forked at ${fork})}"
  fi

  if (( total == 0 )); then
    printf '\n'
    if [[ "$whole" == "true" ]]; then
      muted 'No commits yet.'
    elif [[ "$current" == "$base" ]]; then
      muted "No commits: you are on ${base}."
    else
      muted "No commits: ${current} is level with ${base}."
    fi
    printf '\n'
    return 0
  fi

  local when count_text
  when=$(git log -1 --format='%ar' "$range" 2>/dev/null) || when=''
  count_text="$shown"
  if (( shown < total )); then
    count_text="${shown} of ${total}"
  fi
  if [[ -n "$when" ]]; then
    count_text="${count_text} (last ${when})"
  fi
  kv 'Commits' "$count_text"

  local -a authors=()
  local a joined=''
  # Always name a limit: bash 3.2 under `set -u` treats "${arr[@]}" on an
  # empty array as unbound, and -n "$total" is a no-op anyway.
  local -a author_args=()
  author_args=(-n "$shown")
  while IFS= read -r a; do
    if [[ -n "$a" ]]; then
      authors[${#authors[@]}]="$a"
    fi
  done < <(git log "${author_args[@]}" --format='%aN' "$range" 2>/dev/null | sort -u)

  if (( ${#authors[@]} == 1 )); then
    kv 'Author' "${authors[0]}"
  elif (( ${#authors[@]} > 1 )); then
    for (( i = 0; i < ${#authors[@]}; i++ )); do
      joined+="${joined:+, }${authors[$i]}"
    done
    kv 'Authors' "$joined"
  fi

  if [[ "$whole" == "false" ]]; then
    local stat
    stat=$(git diff --shortstat "$mb"..HEAD 2>/dev/null) || stat=''
    if [[ -n "$stat" ]]; then
      kv 'Diff' "$stat"
    fi
  fi

  printf '\n'

  local fmt='%x1e%h%x1f%ad%x1f%ar%x1f%an%x1f%ae%x1f%s%x1f%p'
  if [[ "$LOG_WANT_BODY" == "true" ]]; then
    fmt+='%n%b'
  fi

  local -a log_args=("--format=${fmt}" --date=short -M)
  if (( shown < total )); then
    log_args+=(-n "$shown")
  fi
  if [[ "$LOG_STAT" == "true" ]]; then
    log_args+=(--raw --numstat)
  else
    log_args+=(--name-status)
  fi

  local line entry head rest
  LOG_PRINTED=false
  _log_reset

  while IFS= read -r line; do
    case "$line" in
      $'\x1e'*)
        _log_emit
        _log_reset
        _log_header "${line#$'\x1e'}"
        ;;
      :[0-7]*$'\t'*)
        head="${line%%$'\t'*}"
        _log_file "${head##* }" "${line#*$'\t'}"
        ;;
      [0-9-]*$'\t'[0-9-]*$'\t'*)
        rest="${line#*$'\t'}"
        entry="${line%%$'\t'*}"$'\x1f'"${rest%%$'\t'*}"
        LOG_NUM[${#LOG_NUM[@]}]="$entry"
        ;;
      [A-Z]*$'\t'*)
        _log_file "${line%%$'\t'*}" "${line#*$'\t'}"
        ;;
      *)
        LOG_TEXT[${#LOG_TEXT[@]}]="$line"
        ;;
    esac
  done < <(git log "${log_args[@]}" "$range" 2>/dev/null || true)

  _log_emit

  if (( shown < total )); then
    printf '\n'
    muted "$(( total - shown )) more $(_plural "$(( total - shown ))" commit commits), not shown — raise -n to see them."
  fi

  printf '\n'
}

# ── g grep ──────────────────────────────────────────────────────────────────
# Ported from ~/bitbucket/pftylr/utils/git/git-grep-all, reshaped around the
# two ways it gets used: inside a repository it is plain `git grep`; outside it
# searches every repository in an index kept in a dotfile.
#
# The index is a list of absolute paths with a `# root:` header, and its age is
# its mtime — no second metadata file to fall out of step. Each hit is prefixed
# with the repository path, so a result line is still a path you can open from
# where you are standing.

GREP_CACHE_TTL=86400
GREP_MAX_DEPTH=10
GREP_CACHE_NAME='.g-repos'
GREP_REPOS=()
GREP_ROOT=''
GREP_BUILT=''

# The index belongs to the directory it sits in and lists the repositories
# under that directory, so it is found the way .git and .editorconfig are: the
# nearest ancestor wins, and if there is none it is created where you are.
_grep_cache_path() {
  local dir

  if [[ -n "${G_REPOS_FILE-}" ]]; then
    printf '%s\n' "$G_REPOS_FILE"
    return 0
  fi

  dir=$(pwd -P)
  while true; do
    if [[ -f "$dir/$GREP_CACHE_NAME" ]]; then
      printf '%s\n' "$dir/$GREP_CACHE_NAME"
      return 0
    fi
    if [[ "$dir" == '/' ]]; then
      break
    fi
    dir=$(dirname "$dir")
  done

  printf '%s/%s\n' "$(pwd -P)" "$GREP_CACHE_NAME"
}

_grep_mtime() {
  local m=''
  m=$(stat -f '%m' "$1" 2>/dev/null) || m=$(stat -c '%Y' "$1" 2>/dev/null) || m=''
  printf '%s\n' "$m"
}

# _grep_age_seconds DURATION — 30m, 12h, 7d, or plain seconds.
_grep_age_seconds() {
  local v="$1" n=''
  case "$v" in
    *d) n="${v%d}" ;;
    *h) n="${v%h}" ;;
    *m) n="${v%m}" ;;
    *s) n="${v%s}" ;;
    *)  n="$v" ;;
  esac
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  case "$v" in
    *d) printf '%s\n' $(( n * 86400 )) ;;
    *h) printf '%s\n' $(( n * 3600 )) ;;
    *m) printf '%s\n' $(( n * 60 )) ;;
    *)  printf '%s\n' "$n" ;;
  esac
}

_grep_index_stale() {
  local cache="$1" ttl="$2" mtime now
  if [[ ! -f "$cache" ]]; then
    return 0
  fi
  mtime=$(_grep_mtime "$cache")
  if [[ -z "$mtime" ]]; then
    return 0
  fi
  if (( ttl == 0 )); then
    return 0
  fi
  now=$(date +%s)
  (( now - mtime > ttl ))
}

_grep_build_index() {
  local root="$1" cache="$2" tmp count cache_dir

  if [[ ! -d "$root" ]]; then
    die "not a directory: ${root}"
  fi

  # Physical paths: find reports what it was given, and relpath works from
  # `pwd -P`, so an unresolved /tmp against /private/tmp would match nothing.
  root=$(cd "$root" && pwd -P)

  cache_dir=$(dirname "$cache")
  if [[ ! -d "$cache_dir" ]]; then
    mkdir -p "$cache_dir" || die "cannot create ${cache_dir}"
  fi

  info "indexing repositories under ${root}, up to ${GREP_MAX_DEPTH} levels deep"

  tmp="${cache}.$$"
  if ! {
    printf '# root: %s\n' "$root"
    printf '# built: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    find "$root" -maxdepth "$GREP_MAX_DEPTH" -name .git -prune -print 2>/dev/null |
      while IFS= read -r g; do
        dirname "$g"
      done | sort
  } >"$tmp"; then
    rm -f "$tmp"
    die "could not write the index"
  fi

  mv "$tmp" "$cache" || {
    rm -f "$tmp"
    die "cannot write ${cache}"
  }

  count=$(grep -c -v '^#' "$cache" || true)
  info "found $(_plural "$count" '1 repository' "${count} repositories"), cached in ${cache}"
}

_grep_load_index() {
  local line
  GREP_REPOS=()
  GREP_ROOT=''
  GREP_BUILT=''
  while IFS= read -r line; do
    case "$line" in
      '# root: '*)  GREP_ROOT="${line#\# root: }" ;;
      '# built: '*) GREP_BUILT="${line#\# built: }" ;;
      ''|'#'*)      continue ;;
      *)
        if [[ -d "$line" ]]; then
          GREP_REPOS[${#GREP_REPOS[@]}]="$line"
        fi
        ;;
    esac
  done <"$1"
}

_grep_has_colour_flag() {
  local a
  for a in "$@"; do
    case "$a" in
      --color|--color=*|--no-color) return 0 ;;
    esac
  done
  return 1
}

grep_usage() {
  section "g grep — search one repository, or all of them"

  cat <<'EOF'
Usage:
  g grep [git-grep-options] PATTERN [--] [PATHSPEC...]
  g grep --refresh [options] PATTERN   rebuild the index, then search
  g grep --list                        show the indexed repositories

Inside a repository this is `git grep`, with every option passed straight
through, so -i, -n, -l, -w, -E and the rest behave exactly as you expect and
colours are git's own.

Outside a repository it searches every repository in the index, printing the
repository and its branch above each block of hits, and prefixing every hit
with the repository path so the result can be opened from here.

Options:
  --refresh           Rebuild the index before searching
  --max-age WHEN      Rebuild if the index is older than WHEN (30m, 12h, 7d,
                      or seconds). Default 1d
  --root DIR          Use DIR's index (DIR/.g-repos), building it if needed
  --all               Search every indexed repository even when inside one
  --list              Print the indexed repositories and exit
  --help              Show this help

Environment:
  G_REPOS_FILE        Use this index file instead of ./.g-repos

The index is `.g-repos` in the directory it describes, found by walking up from
where you are — so the one in ~/github covers every repository under ~/github,
from whatever subdirectory you run in. It is a plain list of paths, one per
line, so it can be edited by hand.
EOF

  printf '\n'
}

cmd_grep() {
  local refresh=false list_only=false all=false max_age="$GREP_CACHE_TTL" root=''
  local -a grep_args=()
  local -a search_args=()
  local in_repo=false cache scan_root

  while (( $# )); do
    case "$1" in
      --help)
        grep_usage
        return 0
        ;;
      --refresh)  refresh=true;   shift ;;
      --list)     list_only=true; shift ;;
      --all)      all=true;       shift ;;
      --root)
        if [[ -z "${2-}" ]]; then
          die '--root needs a directory'
        fi
        root="$2"
        shift 2
        ;;
      --root=*)
        root="${1#*=}"
        shift
        ;;
      --max-age)
        if [[ -z "${2-}" ]]; then
          die '--max-age needs a duration, for example 12h or 7d'
        fi
        max_age=$(_grep_age_seconds "$2") || die "not a duration: $2"
        shift 2
        ;;
      --max-age=*)
        max_age=$(_grep_age_seconds "${1#*=}") || die "not a duration: ${1#*=}"
        shift
        ;;
      --)
        shift
        while (( $# )); do
          grep_args[${#grep_args[@]}]="$1"
          shift
        done
        ;;
      *)
        grep_args[${#grep_args[@]}]="$1"
        shift
        ;;
    esac
  done

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    in_repo=true
  fi

  # The common case: inside a repository, nothing of ours to do.
  if [[ "$in_repo" == "true" && "$refresh" == "false" && "$list_only" == "false" &&
    "$all" == "false" && -z "$root" ]]; then
    if (( ${#grep_args[@]} )); then
      exec git grep "${grep_args[@]}"
    fi
    exec git grep
  fi

  # The index describes the directory it lives in: an index at ~/github/.g-repos
  # covers ~/github, whichever subdirectory you are standing in when you use it.
  if [[ -n "$root" ]]; then
    if [[ ! -d "$root" ]]; then
      die "not a directory: ${root}"
    fi
    root=$(cd "$root" && pwd -P)
    cache="${root}/${GREP_CACHE_NAME}"
    scan_root="$root"
  else
    cache=$(_grep_cache_path)
    if [[ -n "${G_REPOS_FILE-}" ]]; then
      scan_root=$(pwd -P)
    else
      scan_root=$(dirname "$cache")
    fi
  fi

  # --root names the tree to index, so it always rebuilds.
  if [[ "$refresh" == "true" || -n "$root" ]] ||
    _grep_index_stale "$cache" "$max_age"; then
    _grep_build_index "$scan_root" "$cache"
  fi

  _grep_load_index "$cache"

  local n=${#GREP_REPOS[@]}
  if (( n == 0 )); then
    info "no repositories in ${cache}"
    printf '\n'
    return 1
  fi

  if [[ "$list_only" == "true" ]]; then
    local i rp
    section 'Indexed repositories'
    kv 'Index' "$cache"
    if [[ -n "$GREP_ROOT" ]]; then
      kv 'Root' "$GREP_ROOT"
    fi
    if [[ -n "$GREP_BUILT" ]]; then
      kv 'Built' "$GREP_BUILT"
    fi
    kv 'Repositories' "$n"
    printf '\n'
    for (( i = 0; i < n; i++ )); do
      relpath_into rp "${GREP_REPOS[$i]}"
      item "$C_DIM" '-' "$rp"
    done
    printf '\n'
    return 0
  fi

  if (( ${#grep_args[@]} == 0 )); then
    die 'usage: g grep [options] PATTERN'
  fi

  if (( G_COLOR )) && ! _grep_has_colour_flag "${grep_args[@]}"; then
    search_args[${#search_args[@]}]='--color=always'
  fi
  local k
  for (( k = 0; k < ${#grep_args[@]}; k++ )); do
    search_args[${#search_args[@]}]="${grep_args[$k]}"
  done

  info "searching ${n} $(_plural "$n" 'repository' 'repositories')"

  local i repo rel branch out rc line total=0 hit_repos=0
  for (( i = 0; i < n; i++ )); do
    repo="${GREP_REPOS[$i]}"
    rc=0
    out=$(git -C "$repo" grep "${search_args[@]}" 2>/dev/null) || rc=$?
    if (( rc != 0 )) || [[ -z "$out" ]]; then
      continue
    fi

    relpath_into rel "$repo"
    branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch='?'
    printf '\n%s%s%s %s(%s)%s\n' "$C_BOLD" "$rel" "$C_RESET" "$C_DIM" "$branch" "$C_RESET"
    while IFS= read -r line; do
      printf '%s/%s\n' "$rel" "$line"
    done <<<"$out"

    while IFS= read -r line; do
      total=$(( total + 1 ))
    done <<<"$out"
    hit_repos=$(( hit_repos + 1 ))
  done

  printf '\n'
  if (( total == 0 )); then
    muted "No matches in $(_plural "$n" '1 repository' "${n} repositories")."
    printf '\n'
    return 1
  fi
  muted "${total} $(_plural "$total" match matches) in ${hit_repos} of $(_plural "$n" '1 repository' "${n} repositories")."
  printf '\n'
}

# ── repo cache ──────────────────────────────────────────────────────────────
# Every run of g from inside a repository records it, so `g repos` can list the
# places this tool has been used. The cache is a plain sorted-on-read list of
# absolute paths; writing it is best effort and never speaks.

_cache_dir() {
  if [[ -n "${G_CACHE_DIR-}" ]]; then
    printf '%s\n' "$G_CACHE_DIR"
    return 0
  fi
  printf '%s/g\n' "${XDG_CACHE_HOME:-${HOME:?HOME is not set}/.cache}"
}

_repos_cache_file() {
  printf '%s/repos\n' "$(_cache_dir)"
}

# Record the repository this command is running in. Silent, and never fatal:
# a read-only HOME must not stop `g wt` from working.
_cache_current_repo() {
  local top cache

  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  if [[ -z "$top" ]]; then
    return 0
  fi

  cache=$(_repos_cache_file)
  if [[ -f "$cache" ]] && grep -qxF -e "$top" "$cache" 2>/dev/null; then
    return 0
  fi

  if [[ ! -d "$(_cache_dir)" ]]; then
    mkdir -p "$(_cache_dir)" 2>/dev/null || return 0
  fi
  printf '%s\n' "$top" >>"$cache" 2>/dev/null || return 0
  return 0
}

# Read paths on stdin and emit "name<TAB>path", so the table can be sorted by
# the name it shows rather than by the path behind it.
_repos_named() {
  local path name
  while IFS= read -r path; do
    if [[ -z "$path" ]]; then
      continue
    fi
    name="${path##*/}"
    printf '%s\t%s\n' "$name" "$path"
  done
}

# Forget every cached repository. Nothing here is worth a confirmation: the list
# exists to be rebuilt as you work, so clearing it loses nothing but the record.
_repos_clear() {
  local cache cleared=0
  cache=$(_repos_cache_file)

  if [[ -f "$cache" ]]; then
    cleared=$(grep -c '^.' "$cache" 2>/dev/null) || cleared=0
  fi

  if (( cleared == 0 )); then
    rm -f "$cache" 2>/dev/null || true
    section 'Repo cache'
    printf '\n'
    muted 'Nothing cached yet — run a g command inside a repository.'
    printf '\n'
    return 0
  fi

  if ! rm -f "$cache" 2>/dev/null; then
    die "could not remove ${cache}"
  fi

  section 'Repo cache'
  printf '\n'
  step "Cleared $(_plural "$cleared" '1 repository' "${cleared} repositories")"
  printf '\n'
  kv 'Cache' "$cache"
  printf '\n'
  muted 'The list fills itself in again as you use g.'
  printf '\n'
}

repos_usage() {
  section "g repos — where g has been used"

  cat <<'EOF'
Usage:
  g repos [PATTERN]
  g repos --clear

Lists the repositories g has been run in. Every g command run from inside a
repository records it, so the list builds itself as you work.

PATTERN is matched against the whole path, ignoring case, so both `g repos fin`
and `g repos pftylr/fin` work.

--clear forgets every cached entry. The list fills itself in again as you use
g, so nothing is lost and no confirmation is asked for.

Cached entries whose directory has gone are shown as `missing` rather than
dropped, in case the path is on an unmounted volume.

Environment:
  G_CACHE_DIR         Where the cache lives; default ~/.cache/g
                      (XDG_CACHE_HOME is honoured)
EOF

  printf '\n'
}

cmd_repos() {
  local pattern=''
  local clear=false

  while (( $# )); do
    case "$1" in
      -h|--help)
        repos_usage
        return 0
        ;;
      --clear)
        if [[ -n "$pattern" ]]; then
          die 'usage: g repos [--clear] [PATTERN]'
        fi
        clear=true
        shift
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -n "$pattern" || "$clear" == true ]]; then
          die 'usage: g repos [--clear] [PATTERN]'
        fi
        pattern="$1"
        shift
        ;;
    esac
  done

  if [[ "$clear" == true ]]; then
    _repos_clear
    return 0
  fi

  local cache
  cache=$(_repos_cache_file)

  if [[ ! -f "$cache" ]]; then
    info 'no repositories cached yet — run a g command inside one'
    printf '\n'
    return 0
  fi

  local total
  total=$(wc -l <"$cache" | tr -d ' ')

  local line name
  local -a repos=()
  while IFS=$'\t' read -r name line; do
    if [[ -n "$line" ]]; then
      repos[${#repos[@]}]="$line"
    fi
  done < <(
    if [[ -n "$pattern" ]]; then
      grep -iF -e "$pattern" "$cache" 2>/dev/null
    else
      cat "$cache" 2>/dev/null
    fi |
      _repos_named | sort -f
  )

  local current=''
  current=$(git rev-parse --show-toplevel 2>/dev/null) || current=''

  section 'Repositories'

  local n=${#repos[@]}
  if (( n == 0 )); then
    printf '\n'
    muted "No repository matches '${pattern}'."
    printf '\n'
    return 0
  fi

  local i note style missing=0
  table_begin
  table_add 'REPO' 'PATH' 'NOTE'
  for (( i = 0; i < n; i++ )); do
    line="${repos[$i]}"
    name="${line##*/}"
    note=''
    style=''

    if [[ ! -d "$line" ]]; then
      note='missing'
      style="$C_RED"
      missing=$(( missing + 1 ))
    fi
    if [[ -n "$current" && "$line" == "$current" ]]; then
      note="${note:+$note, }current"
      style="$C_CYAN"
    fi

    table_add_styled "$style" "$name" "$line" "$note"
  done
  table_flush

  printf '\n'
  if [[ -n "$pattern" ]]; then
    kv 'Matching' "$n of $(_plural "$total" '1 repository' "${total} repositories")"
  else
    kv 'Repositories' "$n"
  fi
  if (( missing > 0 )); then
    kv 'Missing' "$missing"
  fi
  printf '\n'
}

# ── Commands ────────────────────────────────────────────────────────────────

cmd_version() {
  printf '%s %s\n' "$G_PROG" "$G_VERSION"
}

# ── g gc ────────────────────────────────────────────────────────────────────
# Ported from ~/bitbucket/pftylr/utils/git/git-gc-repo, with three deliberate
# changes: the space is measured in the git directory rather than the whole
# working tree, `--aggressive` is opt-in, and the reflog is only expired when
# the caller asks for it — that step is the only irreversible one.

GC_DRY_RUN=false
GC_AGGRESSIVE=false
GC_MAINTENANCE=false
GC_PRUNE_NOW=false
GC_YES=false

_gc_human_kb() {
  awk -v kb="${1:-0}" 'BEGIN {
    if (kb >= 1048576) printf "%.1f GiB", kb / 1048576
    else if (kb >= 1024) printf "%.1f MiB", kb / 1024
    else printf "%d KiB", kb
  }'
}

_gc_size_kb() {
  du -sk "$1" 2>/dev/null | awk '{ print $1 }'
}

_gc_counts() {
  git count-objects -v 2>/dev/null | awk '
    /^count:/ { c = $2 }
    /^packs:/ { p = $2 }
    END {
      printf "%d pack%s, %d loose object%s",
        p, (p == 1 ? "" : "s"), c, (c == 1 ? "" : "s")
    }'
}

# _gc_step OK_TEXT FAIL_TEXT COMMAND... — run one cleanup step, reporting the
# outcome. git's own output is relayed under the step when there is any.
_gc_step() {
  local ok_text="$1" fail_text="$2" out
  shift 2

  if out=$("$@" 2>&1); then
    step "$ok_text"
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out" | relay
    fi
    return 0
  fi

  printf '\n' >&2
  err "$fail_text"
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out" | relay
  fi
  printf '\n' >&2
  return 1
}

_gc_prune_remotes() {
  local out n

  if ! git remote | grep -qx origin; then
    step 'no origin remote, nothing to prune'
    return 0
  fi

  if ! out=$(git remote prune origin 2>&1); then
    printf '\n' >&2
    err 'pruning stale remote-tracking branches failed'
    printf '%s\n' "$out" | relay
    printf '\n' >&2
    return 1
  fi

  n=$(printf '%s\n' "$out" | grep -c '\[pruned\]' || true)
  if (( n > 0 )); then
    step "pruned ${n} stale remote-tracking $(_plural "$n" ref refs) from origin"
  else
    step 'no stale remote-tracking refs on origin'
  fi
}

gc_usage() {
  section "g gc — reclaim space in this repository"

  cat <<'EOF'
Usage:
  g gc [options]

Prunes stale remote-tracking refs and runs garbage collection, reporting the
size of the git directory before and after.

Options:
  -n, --dry-run      Report the size and the commands that would run, and
                     change nothing
  -a, --aggressive   Pass --aggressive to git gc: slower, and rarely worth it
  -m, --maintenance  Run `git maintenance run` instead of `git gc`, which
                     follows maintenance.strategy (geometric by default)
  -p, --prune-now    Expire the reflog and drop unreachable objects now.
                     Destructive: objects that only the reflog still reached
                     become unrecoverable
  -y, --yes          Skip the confirmation that -p otherwise asks for
  -h, --help         Show this help

What `git gc` already does, so g does not repeat it:
  repacks, prunes packed objects, rewrites the commit-graph, expires reflog
  entries (90 days, 30 for unreachable ones), drops unreachable objects older
  than two weeks, and prunes worktree registrations missing for three months.

Other cleanup git offers, which g leaves alone:
  git clean -fdx        delete untracked and ignored files in the worktree
  git worktree remove   remove another checkout
  git maintenance start schedule upkeep in the background

The original git-gc-repo always expired the reflog and always repacked
aggressively; both are opt-in here.
EOF

  printf '\n'
}

cmd_gc() {
  GC_DRY_RUN=false
  GC_AGGRESSIVE=false
  GC_MAINTENANCE=false
  GC_PRUNE_NOW=false
  GC_YES=false

  while (( $# )); do
    case "$1" in
      -h|--help)
        gc_usage
        return 0
        ;;
      -n|--dry-run)   GC_DRY_RUN=true;    shift ;;
      -a|--aggressive) GC_AGGRESSIVE=true; shift ;;
      -m|--maintenance) GC_MAINTENANCE=true; shift ;;
      -p|--prune-now) GC_PRUNE_NOW=true;  shift ;;
      -y|--yes)       GC_YES=true;        shift ;;
      -[!-]?*)
        local flags="${1#-}"
        local -a split=()
        shift
        while [[ -n "$flags" ]]; do
          split[${#split[@]}]="-${flags:0:1}"
          flags="${flags:1}"
        done
        set -- "${split[@]}" "$@"
        ;;
      -*) die "unknown option: $1" ;;
      *)  die 'usage: g gc [options]' ;;
    esac
  done

  if [[ "$GC_MAINTENANCE" == "true" &&
    ( "$GC_AGGRESSIVE" == "true" || "$GC_PRUNE_NOW" == "true" ) ]]; then
    die '--maintenance cannot be combined with --aggressive or --prune-now'
  fi

  require_repo

  local git_dir before_kb after_kb delta_kb top desc
  git_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  top=$(git rev-parse --show-toplevel)
  before_kb=$(_gc_size_kb "$git_dir")

  section 'Git repository cleanup'
  kv 'Repository' "$top"
  kv 'Before' "$(paint "$C_BOLD" "$(_gc_human_kb "$before_kb")")  ($(_gc_counts))"

  local -a gc_args=(gc)
  if [[ "$GC_AGGRESSIVE" == "true" ]]; then
    gc_args[${#gc_args[@]}]='--aggressive'
  fi
  if [[ "$GC_PRUNE_NOW" == "true" ]]; then
    gc_args[${#gc_args[@]}]='--prune=now'
  fi

  if [[ "$GC_DRY_RUN" == "true" ]]; then
    printf '\n'
    muted 'Would run'
    if git remote | grep -qx origin; then
      printf '  %s\n' 'git remote prune origin'
    fi
    if [[ "$GC_PRUNE_NOW" == "true" ]]; then
      printf '  %s\n' 'git reflog expire --expire=now --all'
    fi
    if [[ "$GC_MAINTENANCE" == "true" ]]; then
      printf '  %s\n' 'git maintenance run'
    else
      printf '  %s\n' "git ${gc_args[*]}"
    fi
    printf '\n'
    muted 'Nothing was changed.'
    printf '\n'
    return 0
  fi

  if [[ "$GC_PRUNE_NOW" == "true" && "$GC_YES" != "true" ]]; then
    printf '\n' >&2
    warn 'this expires the reflog and drops unreachable objects immediately'
    detail 'Commits that only the reflog still reached cannot be recovered afterwards.'
    printf '\n' >&2
    if ! have_tty; then
      die 'no terminal is available to confirm; pass -y to proceed'
    fi
    if ! ask_yes_no 'Continue with the destructive cleanup?'; then
      printf '\n' >&2
      die 'aborted'
    fi
  fi

  printf '\n'

  _gc_prune_remotes

  if [[ "$GC_PRUNE_NOW" == "true" ]]; then
    _gc_step 'reflog expired' 'expiring the reflog failed' \
      git reflog expire --expire=now --all
  fi

  desc='garbage collection complete'
  if [[ "$GC_AGGRESSIVE" == "true" ]]; then
    desc="aggressive ${desc}"
  fi
  if [[ "$GC_PRUNE_NOW" == "true" ]]; then
    desc="${desc}, unreachable objects dropped"
  fi
  if [[ "$GC_MAINTENANCE" == "true" ]]; then
    _gc_step 'maintenance run complete' 'maintenance run failed' \
      git maintenance run
  else
    _gc_step "$desc" 'garbage collection failed' git "${gc_args[@]}"
  fi

  printf '\n'

  after_kb=$(_gc_size_kb "$git_dir")
  delta_kb=$(( before_kb - after_kb ))

  kv 'After' "$(paint "$C_BOLD" "$(_gc_human_kb "$after_kb")")  ($(_gc_counts))"
  if (( delta_kb > 0 )); then
    kv 'Reclaimed' "$(paint "$C_GREEN" "$(_gc_human_kb "$delta_kb")")"
  elif (( delta_kb < 0 )); then
    kv 'Grew by' "$(paint "$C_RED" "$(_gc_human_kb "$(( -delta_kb ))")")"
  else
    kv 'Reclaimed' 'nothing'
  fi

  printf '\n'
}

cmd_worktree() {
  WT_MODE=''
  WT_FORCE=false

  while (( $# )); do
    case "$1" in
      -h|--help)
        wt_usage
        return 0
        ;;
      -b|--branch)
        WT_MODE=fetch
        shift
        ;;
      -f|--force)
        WT_FORCE=true
        shift
        ;;
      -r|--remove)
        WT_MODE=remove
        shift
        ;;
      -s|--status)
        WT_MODE=status
        shift
        ;;
      -[!-]?*)
        # Split combined short flags: -rf becomes -r -f.
        local flags="${1#-}"
        local -a split=()
        shift
        while [[ -n "$flags" ]]; do
          split[${#split[@]}]="-${flags:0:1}"
          flags="${flags:1}"
        done
        set -- "${split[@]}" "$@"
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ "$WT_FORCE" == "true" && "$WT_MODE" != "remove" ]]; then
    die '--force is only valid with -r'
  fi

  local branch
  case "$WT_MODE" in
    fetch)
      if (( $# < 1 )); then
        die 'usage: g wt -b BRANCH [BRANCH ...]'
      fi
      _wt_require_repo
      for branch in "$@"; do
        _wt_fetch "$branch"
      done
      ;;
    remove)
      if (( $# < 1 )); then
        die 'usage: g wt -r[f] BRANCH [BRANCH ...]'
      fi
      _wt_require_repo
      for branch in "$@"; do
        _wt_remove "$branch"
      done
      ;;
    status)
      if (( $# )); then
        die 'usage: g wt -s'
      fi
      _wt_require_repo
      _wt_status
      ;;
    *)
      _wt_require_repo
      if (( $# == 0 )); then
        _wt_list
      elif (( $# == 1 )); then
        _wt_handle_branch "$1"
      else
        die 'usage: g worktree [BRANCH-PATTERN]'
      fi
      ;;
  esac
}

usage() {
  section "${G_PROG} ${G_VERSION} — git, made easier"

  cat <<EOF
Usage:
  ${G_PROG} <command> [args...]

Commands:
  help                Show this help
  version             Show the version
  branches            List local branches with their state
  branch-summary      Summarise the current branch against its base
  branch-log          The commits this branch adds, with their changes
  grep                git grep here, or across every indexed repository
  log                 The whole history, commit by commit
  repos               List the repositories g has been run in
  untracked           List untracked files with size and age
  gc                  Reclaim space in the repository
  worktree, wt        List worktrees and open or create one for a branch

Utilities are ported one at a time from ~/bitbucket/pftylr/utils/git and appear
here as they land. Run 'g COMMAND --help' for a command's own options.

Global options:
  --color[=WHEN]      WHEN is auto (default), always or never
  --no-color          Same as --color=never
  -h, --help          Show this help
  -V, --version       Show the version

Environment:
  NO_COLOR            Disable colour and effects (https://no-color.org)
EOF

  printf '\n'
}

# Dispatch. Add a case branch here, then extend usage() and the README table in
# the same commit.
run_cmd() {
  local cmd="${1:-help}"
  if (( $# )); then
    shift
  fi

  case "$cmd" in
    help|--help|-h)
      usage
      ;;
    version|--version|-V)
      cmd_version
      ;;
    worktree|wt)
      cmd_worktree "$@"
      ;;
    gc)
      cmd_gc "$@"
      ;;
    branches)
      cmd_branches "$@"
      ;;
    branch-summary)
      cmd_branch_summary "$@"
      ;;
    grep)
      cmd_grep "$@"
      ;;
    log)
      cmd_log "$@"
      ;;
    branch-log)
      cmd_branch_log "$@"
      ;;
    repos)
      cmd_repos "$@"
      ;;
    untracked)
      cmd_untracked "$@"
      ;;
    -*)
      err "unknown option: ${cmd}"
      printf "Run '%s help' for usage.\n" "$G_PROG" >&2
      return 2
      ;;
    *)
      err "unknown command: ${cmd}"
      printf "Run '%s help' for the list of commands.\n" "$G_PROG" >&2
      return 2
      ;;
  esac
}

# ── Entrypoint ──────────────────────────────────────────────────────────────

main() {
  local colour="auto"

  while (( $# )); do
    case "$1" in
      --no-color)  colour="never";  shift ;;
      --color)     colour="always"; shift ;;
      --color=*)   colour="${1#*=}"; shift ;;
      *)           break ;;
    esac
  done

  case "$colour" in
    auto|always|never) ;;
    *)
      printf "error: invalid --color value: %s (expected auto, always or never)\n" \
        "$colour" >&2
      return 2
      ;;
  esac

  _init_style "$colour"

  # Remember where we were run from, before any command decides to exec — but
  # not for `repos --clear`, which would put the current repository straight
  # back into the cache it is about to empty.
  local record=true arg
  case "${1-}" in
    help|--help|-h|version|--version|-V) record=false ;;
    repos)
      for arg in "$@"; do
        if [[ "$arg" == '--clear' ]]; then
          record=false
        fi
      done
      ;;
  esac
  if [[ "$record" == true ]]; then
    _cache_current_repo
  fi

  run_cmd "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
