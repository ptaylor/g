# Ideas

Things worth doing in `g`, in the order I would argue for them. Nothing here is
a commitment — it is a list to argue with. Commands not yet ported live in
`TO-PORT.txt` instead.

## Before anything else

### A test script

There are no automated checks. Every verification so far has been run by hand in
throwaway repositories, and the bugs that got through — a repository in the
middle of a merge being committed anyway, "1 of 2 repositories were not synced" —
were caught by the order the tests happened to run in.

A plain `t/smoke` in bash, with no new dependencies: build a temporary
repository, run a command, assert its output and its exit status. One case per
command for the happy path, one for each refusal, and one for the difference
between a terminal and a pipe. Then `./t/smoke` before `git commit` becomes the
habit.

## Fixes worth making

### Page the other long outputs

`g log` and `g branch-log` page through `$G_PAGER` when they write to a terminal.
`contributors`, `untracked`, `branches` and `grep` across repositories can all
run past a screen and do not. It is one shared wrapper; the work is deciding
which commands opt in.

### Right-aligning a table column is a foot-gun

Numeric columns are right-aligned by the caller pre-padding the cell
(`printf '%7s' "$count"`), because `table_flush` measures whatever text it is
given. Any command that forgets misaligns silently. A `table_add_right` helper
would make it impossible to get wrong.

### `section` measures its rule in bytes

Under a UTF-8 locale the underline matches the title; under a C locale an em dash
counts as three characters, so `g log — the whole history…` gets a rule four
characters too long. Invisible on a normal terminal, visible to anyone with
`LANG` unset — which is what a test harness looks like.

### `g branches` forks four to six times per branch

`merge-base`, two counts, two dates, ahead and behind, once per branch. That is
the pattern that cost `untracked` 20 seconds over 2,000 files: fine at ten
branches, painful at two hundred. Measure on a synthetic repository before
optimising; `for-each-ref`'s ahead-behind atom would collapse most of it, but it
needs git 2.41.

## Polish

### `g repos --prune`

Missing entries accumulate forever. Now that `g sync` resolves names from the
cache, a stale entry produces "it has gone from the disk" noise. `--prune` should
drop them, and the same pass could reconcile the duplicate paths recorded before
`pwd -P` was applied.

### Show size and age for untracked files in `g sync`

The report lists names only. `g untracked` already computes both through
`_ut_human_bytes`, and `notes.txt  1.2K  3 days` says at a glance whether it is
the scratch file you expected.

### Warn when syncing on the base branch

`g sync` will commit straight onto `main`. Everything else in the tool asks
first, so a note — "you are on main; commit anyway?" — would fit, with `-y` to
force it.

## Commands

### `g status`

The command typed most often has no `g` equivalent. One screen: staged, unstaged
and untracked grouped and counted, a diffstat, ahead and behind against the base,
and the worktree it is happening in. `git status` is a wall of hints; this would
be the report.

### `g pick PATTERN`

`git log -S`, for when a string appeared or vanished. The other half of `grep`:
`grep` is where it is now, `pick` is when it got there.

### `g dirty`, `g unpushed`

From the `repos` cache: every repository with uncommitted work, and every branch
ahead of its upstream. The mirror of `g repos`, and the list you want on a
Friday.
