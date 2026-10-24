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

# paint COLOUR TEXT — TEXT wrapped in COLOUR for stdout. Plain mode emits the
# text alone, so callers never have to branch on whether colour is on.
# Escape bytes count towards a cell's width, so only use this on the last
# column of a table.
paint() {
  local colour="$1"
  shift
  printf '%s%s%s' "$colour" "$*" "$C_RESET"
}

# muted TEXT — dim secondary text on stdout.
muted() {
  printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"
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

table_flush() {
  local n=${#G_TABLE_ROWS[@]}
  if (( n == 0 )); then
    return 0
  fi

  local i c len row cell style line pad
  local -a cells
  local -a widths
  local maxcols=0

  for (( i = 0; i < n; i++ )); do
    IFS=$'\x1f' read -r -a cells <<<"${G_TABLE_ROWS[$i]}"
    if (( ${#cells[@]} > maxcols )); then
      maxcols=${#cells[@]}
    fi
    for (( c = 0; c < ${#cells[@]}; c++ )); do
      len=${#cells[c]}
      if (( len > ${widths[c]:-0} )); then
        widths[c]=$len
      fi
    done
  done

  for (( i = 0; i < n; i++ )); do
    IFS=$'\x1f' read -r -a cells <<<"${G_TABLE_ROWS[$i]}"
    style="${G_TABLE_STYLES[$i]:-}"
    if (( i == 0 )); then
      style="${C_BOLD}${style}"
    fi

    line=''
    for (( c = 0; c < maxcols; c++ )); do
      cell="${cells[c]:-}"
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

# Print TARGET relative to $PWD. Uses the physical working directory because
# git reports physical paths — on macOS /tmp is a symlink to /private/tmp.
_wt_relpath() {
  local target="$1" from out=''
  local -a tparts
  local -a fparts
  local i=0 common=0 nt nf

  from=$(pwd -P)

  if [[ "$target" == "$from" ]]; then
    printf '.\n'
    return 0
  fi

  IFS='/' read -r -a tparts <<<"${target#/}"
  IFS='/' read -r -a fparts <<<"${from#/}"
  nt=${#tparts[@]}
  nf=${#fparts[@]}

  while (( i < nt && i < nf )); do
    if [[ "${tparts[$i]}" != "${fparts[$i]}" ]]; then
      break
    fi
    i=$(( i + 1 ))
  done
  common=$i

  for (( i = common; i < nf; i++ )); do
    out+='../'
  done
  for (( i = common; i < nt; i++ )); do
    out+="${tparts[$i]}"
    if (( i < nt - 1 )); then
      out+='/'
    fi
  done

  if [[ -z "$out" ]]; then
    out='.'
  fi
  printf '%s\n' "$out"
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
    path=$(_wt_relpath "${WT_PATHS[$i]}")
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
    die "directory already exists: $(_wt_relpath "$wpath")"
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
  _wt_relpath "$wpath"
}

_wt_handle_branch() {
  local pattern="$1"
  local branch existing i n nlocal nremote
  local -a all=()

  # An exact local branch needs no search.
  if git show-ref --verify --quiet "refs/heads/${pattern}"; then
    existing=$(_wt_usable_for_branch "$pattern")
    if [[ -n "$existing" ]]; then
      _wt_relpath "$existing"
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
      _wt_relpath "$existing"
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
    _wt_relpath "$existing"
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

  info "removing worktree for '${branch}' at $(_wt_relpath "$wt_path")"

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
    detail "$(_wt_relpath "$wt_path") holds changes that are not committed anywhere."
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
    detail "$(_wt_relpath "$wt_path") is locked, so git will not remove it."
    printf '\n' >&2
    detail 'Unlock it first, then remove it again:'
    printf '\n%s    %s%s%s\n' "$G_INDENT" "$E_BOLD" \
      "git worktree unlock $(_wt_relpath "$wt_path")" "$E_RESET" >&2
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
    _wt_relpath "$existing"
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
  run_cmd "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
