<p align="center">
  <img src="logo.svg" alt="g" width="112">
</p>

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
| `g branches` | List local branches with their state |
| `g branch-summary` | Summarise the current branch against its base |
| `g grep` | `git grep` here, or across every indexed repository |
| `g log` | The whole history, commit by commit |
| `g branch-log` | The commits this branch adds, with their changes |
| `g repos` | List the repositories g has been run in |
| `g untracked` | List untracked files with size and age |
| `g gc` | Reclaim space in the repository |
| `g worktree`, `g wt` | List worktrees and open or create one for a branch |

Utilities from `~/bitbucket/pftylr/utils/git` are ported one at a time; each
one appears in `g help` and in the table above as it lands.

## `g log`

The whole history, in the blocks `g branch-log` prints — hash, subject, author,
age, message and the files each commit changed. Nothing stops the walk at a
base, so it runs back through the entire history.

```bash
g log            # the last 20 commits
g log -n 0       # all of them
g log -n 5 -s    # five commits, with per-file line counts
```

```
Commits
────────
Branch           feature/x
Commits          3 (last 2 minutes ago)
Author           Paul Taylor

  77e0b52  Add a file
           2026-10-27  Paul Taylor <pt@example.com>, 2 minutes ago

           A  added.txt
```

There is no `Base` or `Diff` row, because there is nothing to measure against.
Everything else — the options, the colours, the merge annotation, `--no-body` —
is shared with `g branch-log`, which is the same code behind a range that stops.

## `g branch-log`

What your branch adds, commit by commit — ported from `git-log` in
`~/bitbucket/pftylr/utils/git`. The original printed
`git log MERGE_BASE..HEAD --name-status` against a hardcoded `origin/main`;
this finds the base the way the other commands do and gives every commit a
block of its own.

```bash
g branch-log                 # everything on this branch that the base lacks
g branch-log -s              # ...with added and removed line counts per file
g branch-log -n 5            # the last five only
g branch-log develop         # ...against something else
g branch-log --no-body       # subjects and files, without message bodies
```

```
Commits
────────
Branch           feature/nicer-log
Base             main (forked at 7a9fd48)
Commits          3 (last 12 minutes ago)
Author           Paul Taylor
Diff             4 files changed, 3 insertions(+)

  5e3eb93  Add a new file, a soon-deleted file and a binary
           2026-10-27  Paul Taylor <pt@example.com>, 12 minutes ago

           This body is indented under the commit, and blank lines between
           paragraphs are kept.

           A  added.txt
           A  willgo.txt

  8b8c4fa  Rename keep.txt, drop willgo.txt, extend base again
           2026-10-27  Paul Taylor <pt@example.com>, 12 minutes ago

           M  base.txt
           R  keep.txt → renamed.txt
           D  willgo.txt
```

A is green, M yellow, D red and R cyan, and a rename shows both paths with an
arrow between them. With `-s` each file is followed by its line counts, `-`
standing in for a binary. A merge commit has no file list — git does not
diff one — so the block says `merge of 2 parents` instead of looking empty.

**The base** is `main`, `master` or `develop` when the current branch already
contains one of them, local before origin; failing that, the nearest ancestor
branch. This is deliberately not `g branch-summary`'s rule, which always takes
the nearest ancestor: a sibling branch merged back in is nearer by commit
count but makes a useless range. Name a `BASE` to overrule it. Standing on the
base itself, the range becomes the commits you have not pushed yet, and a
repository with no base at all says so and points at `g log`.

`g log` is the same report without the stopping point, and `g branch-summary`
is the aggregated view of the same range.

## `g grep`

Search one repository, or all of them — ported from the `git-grep-all` script
in `~/bitbucket/pftylr/utils/git`.

**Inside a repository** it is `git grep`, with every option passed straight
through, so `-i`, `-n`, `-l`, `-w`, `-E`, `--` and pathspecs behave exactly as
git's, colours included:

```bash
g grep -n TODO src/          # git grep, unchanged
```

**Outside a repository** it searches every repository in an index, naming each
repository and its branch, and prefixing each hit with the repository path so
the result is still something you can open from where you are:

```bash
g grep quick
```

```
alpha (main)
alpha/content.txt:the quick brown fox

gamma/deep (main)
gamma/deep/content.txt:quick silver fox

3 matches in 3 of 4 repositories.
```

| Option | Meaning |
| --- | --- |
| `--refresh` | Rebuild the index before searching |
| `--max-age WHEN` | Rebuild if the index is older than `30m`, `12h`, `7d` or a number of seconds; default `1d` |
| `--root DIR` | Index `DIR` instead of the current directory |
| `--all` | Search every indexed repository even when inside one |
| `--list` | Show the indexed repositories and exit |

### The index and its root

The index is `.g-repos` in the directory it describes, found the way `.git` is
found — nearest ancestor first:

```
~/github/.g-repos        lists the repositories under ~/github
~/github/g/              a repository; uses the index above
```

It is a plain list of absolute paths, one per line, behind two `#` header lines
recording the root it was built from and when. Its mtime *is* its age, so there
is no second file to fall out of step, and it can be edited by hand.

| Situation | Index | Scanned |
| --- | --- | --- |
| No `.g-repos` here or above | created here | the current directory |
| Found here or above | that file | only when stale: the directory holding it |
| `--refresh` | as above | as above |
| `--root DIR` | `DIR/.g-repos` | `DIR` |
| `G_REPOS_FILE=FILE` | `FILE` | the current directory |

Repositories are found with `find` from the scanned directory to a maximum
depth of 10, never descending into a `.git`.

Because the index lives with the tree it describes, a rebuild cannot narrow it
by accident: `--refresh` from inside `~/github/g` rebuilds `~/github/.g-repos`
by scanning `~/github`, and `--all` from inside that repository searches all of
them. `g grep --list` prints the `Index`, `Root` and `Built` in force, so there
is never a question of which file answered.

Two consequences worth knowing: `--root DIR` writes `DIR/.g-repos`; and if you
first run `g grep` from inside a repository that has no index above it, the file
it creates is untracked — add `.g-repos` to `.gitignore`, or run from the parent
directory.

## `g repos`

Every g command run from inside a repository records it, so the list builds
itself as you work.

```bash
g repos            # everything g has been run in
g repos fin        # only paths containing "fin", ignoring case
g repos --clear    # forget them all
```

```
Repositories
────────────
REPO         PATH                                   NOTE
───────────  ─────────────────────────────────────  -------
ClientApi    /Users/paul/work/ClientApi
finsean      /Users/paul/github/pftylr/finsean
g            /Users/paul/github/pftylr/g             current
other        /Users/paul/oss/other                  missing

Repositories     4
Missing          1
```

The match is a case-insensitive substring of the whole path, so `g repos fin`
and `g repos pftylr/fin` both work, and the table is sorted by repository name
rather than by path.

The cache is `~/.cache/g/repos` — `XDG_CACHE_HOME` is honoured and
`G_CACHE_DIR` overrides both. It is one absolute path per line, deduplicated as
it is written and sorted when read, so it can be edited by hand. Recording is
best effort: an unwritable cache directory never stops a command, and
`g help` and `g version` do not record.

`g repos --clear` deletes the cache and reports how many entries it held. It
does not ask first: the list is only a record of use, and it fills itself in
again the next time you run something.

Entries whose directory has gone are shown as `missing` rather than dropped, in
case the path is on an unmounted volume.

## `g untracked`

Untracked files by age and size — ported from the `git-untracked` script in
`~/bitbucket/pftylr/utils/git`.

```bash
g untracked        # untracked files, newest first
g untracked -a     # include ignored files, each marked (ignored)
```

```
Untracked and ignored files
───────────────────────────
MODIFIED               SIZE  FILE
────────────────  ---------  ─────────────────────────────
2026-10-24 15:02    1.9 MiB  build/huge.bin  (ignored)
2026-10-24 15:01        2 B  src/a.txt
2026-10-24 14:59    4.8 KiB  logs/run.log  (ignored)

Files            3 files, 2 ignored
Total            1.9 MiB
```

The list covers the whole repository, newest first, with ties holding
alphabetical order so repeat runs agree. Paths are shown relative to the
directory you run it from — the original stripped the repository root, which
printed full paths whenever you were in a subdirectory. Ignored files are dim
with a yellow `(ignored)` marker, and sizes use the same KiB/MiB/GiB units as
`g gc`.

Timestamps and sizes come from one batched `stat` rather than two processes per
file: 2,000 untracked files list in about three seconds, against twenty for the
per-file version.

## `g branches`

An overview of local branches — ported from the `git-branch-list` script in
`~/bitbucket/pftylr/utils/git`.

```bash
g branches        # your own branches, newest first
g branches -a     # include branches by other authors
g branches -m     # only what is safe to delete
```

```
Branches
────────
BRANCH          AUTHOR        CMTS  FIRST       LAST                         STATUS
──────────────  ────────────  ────  ──────────  ───────────────────────────  ─────────────────
main            Paul Taylor      4  2026-10-10  2026-10-24 (2 minutes ago)  current
feature/ahead   Paul Taylor      2  2026-10-20  2026-10-23 (1 day ago)      +2/-1
feature/merged  Paul Taylor      0  -           2026-10-22 (2 days ago)     merged (deletable)

Base             main
User             Paul Taylor
Showing          3 branches, 1 merged (safe to delete)

Delete one with: git branch -d NAME
```

`CMTS` counts only the branch's own work, from the merge-base with the base, so
a branch that is already merged shows `0`; `+ahead/-behind` is relative to the
base. Rows are cyan for the branch you are on and green for one that is merged
and safe to delete.

The base is the first of `main`, `master`, `develop` that exists, local before
origin — a branch merged here is deletable here whether or not the merge has
been pushed. `g wt -s` looks at origin's copy instead, because it answers a
different question: whether the branch has been merged upstream.

`-m` leaves out the base branch and the branch you are on, since neither can be
deleted.

## `g branch-summary`

What the current branch is worth — ported from the `git-branch-summary` script
in `~/bitbucket/pftylr/utils/git`.

```bash
g branch-summary            # against the detected base
g branch-summary main       # against a named base
g branch-summary -v         # include the commit log
```

```
Branch summary
──────────────
Branch           feature/work
Base             main
Created          2026-10-26 (2 hours ago)
Commits          5 (last 20 minutes ago)
Authors          Other Person, Paul Taylor
Changes          +1 added, ~1 modified, -1 deleted, >1 renamed
Diff             4 files changed, 2 insertions(+), 1 deletion(-)

Added
  + fresh.txt

Modified
  ~ keep.txt

Deleted
  - old.txt

Renamed
  > orig.txt → renamed.txt
```

The base is the nearest ancestor branch: the one HEAD already contains that
leaves the fewest commits behind. A branch created from another feature
therefore reports that feature rather than `main`, and on a tie
`main`/`master`/`develop` wins. The original took the nearest branch by commit
distance without checking that HEAD contained it, so a sibling sharing the fork
point could be named as the base — the right diff under the wrong label.

A branch with no changes prints `No changes against <base>.`; names and counts
come from one `git diff --name-status` pass, so renames appear as
`old → new` rather than as an add plus a delete.

## `g gc`

Reclaims space in the current repository — ported from the `git-gc-repo` script
in `~/bitbucket/pftylr/utils/git`.

```bash
g gc              # prune stale remote-tracking refs, then collect
g gc -n           # what it would do, and the current size
g gc -a           # aggressive repack (slow, rarely worth it)
g gc -m           # follow maintenance.strategy instead of plain gc
g gc -p           # also expire the reflog and drop unreachable objects now
```

| Option | Meaning |
| --- | --- |
| `-n, --dry-run` | Report the size and the commands, change nothing |
| `-a, --aggressive` | Pass `--aggressive` to `git gc` |
| `-m, --maintenance` | Run `git maintenance run` instead of `git gc` |
| `-p, --prune-now` | Expire the reflog and drop unreachable objects now |
| `-y, --yes` | Skip the confirmation that `-p` asks for |

The size measured is the git directory, not the working tree, and it comes from
`du` plus `git count-objects`, so the report shows what actually shrank:

```
Git repository cleanup
──────────────────────
Repository       /Users/paul/project
Before           652 KiB  (0 packs, 129 loose objects)

  ✓ pruned 1 stale remote-tracking ref from origin
  ✓ garbage collection complete

After            148 KiB  (1 pack, 0 loose objects)
Reclaimed        504 KiB
```

`git gc` already repacks, prunes packed objects, rewrites the commit-graph,
expires reflog entries, drops unreachable objects older than two weeks and
prunes worktree registrations missing for three months; `g gc` does not repeat
any of that, and only the two steps it adds are opt-in.

Unlike the original script, `g gc` never expires the reflog and never repacks
aggressively unless asked — the first is irreversible, the second rarely pays
for itself. Destructive cleanup (`git clean -fdx`, `git worktree remove`) and
scheduled upkeep (`git maintenance start`) are deliberately left to git.

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
