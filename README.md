# g — git utilities

`g` is a single command that wraps everyday git operations so they are quicker
to type and easier to read. It is a companion to `d` (Docker) and `k`
(Kubernetes).

## Install

```bash
./install.sh           # symlinks g into ~/bin (default)
./install.sh ~/bin     # or choose another directory on PATH
```

The installer creates the target directory, verifies the installed command
runs, and warns if the directory is not on `PATH`.

## Usage

```bash
g help
g version
```

| Command | Description |
| --- | --- |
| `g help` | Show usage |
| `g version` | Show the version |
| `g worktree`, `g wt` | List worktrees and open or create one for a branch |

Utilities from `~/bitbucket/pftylr/utils/git` are ported one at a time; each
one appears in `g help` and in the table above as it lands.

## `g worktree` (alias `g wt`)

Manages git worktrees by branch name — ported from the `worktree` script in
`~/bitbucket/pftylr/utils/git`.

```bash
g wt                       # list the active worktrees
g wt feature/login         # open that branch's worktree, creating it if needed
g wt login                 # ...or choose from the branches that match
g wt feature/new-thing     # offer to create the branch and its worktree
g wt -s                    # what is merged, orphaned or missing
g wt -r feature/login      # remove the worktree
g wt -rf feature/login     # ...even with uncommitted changes
g wt -b feature/login      # fetch from origin, then create
```

| Option | Meaning |
| --- | --- |
| `-b, --branch BRANCH...` | Fetch `BRANCH` from `origin` and create its worktree |
| `-r, --remove BRANCH...` | Remove the worktree for `BRANCH` |
| `-f, --force` | With `-r`, remove even when files are modified or untracked |
| `-s, --status` | Report worktrees whose remote branch is gone, or whose branch is merged |
| `-h, --help` | Show the command's help |

Worktrees are created beside the main checkout as `<repo>--<branch>`, with `/`
in the branch name replaced by `-`. A pattern opens the worktree for the
matching branch; several matches open a picker, and a `SECTION/NAME` pattern
that matches nothing offers to create the branch.

The listing has three columns — `BRANCH`, `PATH` (relative to where you are)
and `NOTE`:

| NOTE | Meaning |
| --- | --- |
| `current` | the worktree your shell is in |
| `detached` | the worktree has no branch |
| `locked` / `locked: <reason>` | protected by `git worktree lock`; `-r` will refuse until it is unlocked |
| `missing directory` | the registration points at a directory that no longer exists |

Notes combine, so a locked worktree whose directory was deleted reads
`missing directory, locked: kept for review`. Rows are coloured green when
current, yellow when detached or locked, and red when the directory is missing.

`-s` checks `develop`/`dev`/`main`/`master`, locally and on `origin`, and
recognises both merge commits and squash merges. Run `git fetch --prune` first
for up-to-date remote state.

Only the worktree path is written to stdout, so this works:

```bash
cd "$(g wt feature/login)"
```

`-s/--status` is this repository's rename of the original `-c/--check`.

## Presentation

On a terminal `g` uses colour and text effects to separate sections and
highlight results. When output is piped or redirected the same text is emitted
without escape codes and with the same alignment, so it stays readable and
greppable.

Colour is turned off when `NO_COLOR` is set, when `TERM=dumb`, or with
`--no-color`.

## Licence

MIT — see [LICENSE](LICENSE).
