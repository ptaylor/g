# AGENTS.md

Instructions for any human or AI agent working in this repository.

## Summary

`g` is a single-file command that wraps everyday git operations so they are
quicker to type and easier to read. It is the git counterpart to `d` (Docker)
and `k` (Kubernetes): one command, a small set of sub-commands, and output that
is pleasant on a terminal and clean in a pipe.

## Status

WIP. The dispatch skeleton, the presentation layer, and the first ported
command — `worktree` (alias `wt`) — are in place. Further commands are ported
one at a time from `~/bitbucket/pftylr/utils/git` and must not be assumed to
exist until they appear in `g help`.

## Commands

```bash
./install.sh                  # symlink g into ~/bin
./install.sh /usr/local/bin   # or another directory on PATH

./g help                      # usage
./g version                   # version
./g wt                        # list worktrees
./g wt -s                     # worktree status report

./g help | cat                # verify plain (piped) mode
./g wt | cat                  # same, for a table
shellcheck g install.sh       # lint, when shellcheck is installed
bash -n g                     # syntax check
```

## Layout

| Path | What it is |
| --- | --- |
| `g` | The tool: presentation layer, guards, dispatch, sub-commands. |
| `install.sh` | Idempotent installer; symlinks `g` into `~/bin` by default. |
| `README.md` | User-facing documentation. |
| `AGENTS.md` | This file. |
| `LICENSE` | MIT. |
| `.gitignore` | Ignored local artefacts, grouped by reason. |

## Technology Stack

### Bash

- **Role**: implementation language of `g` and `install.sh`.
- **Version**: 3.2 or newer. `/bin/bash` on macOS is still 3.2, so avoid
  associative arrays, `${var^^}`/`${var,,}`, `mapfile`/`readarray`,
  `local -n`, and `EPOCHSECONDS`.
- **Best Practices**:
  - `#!/usr/bin/env bash` plus `set -euo pipefail`.
  - Quote expansions; write `if` instead of `[[ ... ]] && cmd` as the last
    command of a function or script, because a false test under `set -e` exits.
  - Prefer `git` plumbing (`for-each-ref`, `rev-parse`, `rev-list`) over
    parsing porcelain meant for people.
  - Use `printf`, not `echo`, for anything a user or script will read.
- **Docs**: <https://www.gnu.org/software/bash/manual/>

### git

- **Role**: everything the tool wraps.
- **Version**: any reasonably current git (2.x).
- **Best Practices**:
  - Read-only by default; anything destructive (`branch -D`, `push --force`,
    `reset --hard`, `clean`) confirms interactively first and refuses when
    stdout is not a terminal unless given an explicit force flag.
  - Never rewrite history that has been pushed without saying so in the output.
  - Resolve the base branch rather than hard-coding `main`: check the current
    branch, then `develop`, `main`, `master`, locally and on `origin`.
- **Docs**: <https://git-scm.com/docs>

### ShellCheck

- **Role**: optional linting of the shell scripts.
- **Version**: whatever `brew install shellcheck` provides.
- **Best Practices**:
  - Fix findings or suppress with a comment that explains why.
- **Docs**: <https://www.shellcheck.net/wiki/>

## Keeping `.gitignore` current — required

`.gitignore` is part of a change, never a follow-up to it. When a change creates
files that should not be committed, the patterns go in **the same commit**.

Keep current, at minimum:

- **Tool and dependency output**: build directories, caches, downloaded
  artefacts, generated indexes.
- **Local state**: `*.env`/`.env.local`, log files, anything naming this machine
  or a user's home directory.
- **Editor and OS metadata**: `.DS_Store`, local `.vscode/` state, `*.swp`.

Rules:

- Prefer the official patterns published for the tool over invented ones.
- Group patterns by reason, each under a comment naming the tool or platform.
- Do not ignore editor tooling by reflex: ignore the specific local artefacts
  (`.vscode/*` with `!.vscode/extensions.json`) rather than the whole directory.
- **Never commit secrets** — ignore the file that holds them, and say so in the
  commit that removes one that slipped in.

## Project rules

- **One dispatch table.** Add a sub-command as a `case` branch in `run_cmd()`,
  and extend `usage()` and the command table in `README.md` in the same commit.
  A command that is not in `g help` does not exist. Give each command its own
  `COMMAND --help`.
- **All output goes through the presentation layer.** Use `section`, `kv`,
  `muted`, `detail`, `paint`, `table_begin`/`table_add`/`table_add_styled`/
  `table_flush`, and `ok`/`warn`/`err`/`info`/`die`/`ask_yes_no`. Never
  hard-code an escape sequence inside a sub-command.
- **Two style sets.** `C_*` decorate stdout and `E_*` decorate stderr; the
  colour decision is made per stream. Report helpers (`section`, `kv`, `muted`,
  tables) write to stdout and use `C_*`; status lines and prompts write to
  stderr and use `E_*`. A command must never colour a stream by asking about the
  other one.
- **Data on stdout, decoration on stderr.** Status lines go to stderr so
  `g <command> > out.txt` captures the result and nothing else. `worktree`
  follows this strictly: the worktree path is the only thing on stdout, so
  `cd "$(g wt branch)"` works.
- **Plain mode is a first-class citizen.** Colour only when the stream is a
  terminal; honour `NO_COLOR`, `TERM=dumb`, `--no-color` and `--color=never`.
  Piped output must keep its alignment and stay greppable; box-drawing
  characters are replaced by ASCII outside a UTF-8 locale.
- **Style rows, not cells.** Column widths are measured on plain cells, so
  `table_add_styled` applies a style to a whole row after padding. An escape
  code inside a cell would count towards its width — if a single cell must be
  coloured, make it the last column and accept that it is never padded.
- **Port with parity, prove it.** A ported command keeps the behaviour and exit
  codes of the original script in `~/bitbucket/pftylr/utils/git`; record any
  intentional deviation in the commit body and in the command's help. Known
  deviation: `worktree -c/--check` is `g wt -s/--status`.
- **Separate blocks, end with a blank line.** Human-facing output leaves a
  blank line between the result and the hints that follow it, between a prompt
  and whatever comes next, and at the very end. A blank line that only exists
  for the terminal goes to stderr, so it never lands in a captured value:
  `_wt_create` prints the separator on stderr and the path alone on stdout,
  which keeps `cd "$(g wt branch)"` exact.
- **Indent what is subordinate.** Lines that explain or elaborate on the line
  above are indented: `detail` for prose, `relay` for output piped from git.
  When a failure is reported under a message the command already printed, raise
  `G_INDENT` for the block so the whole explanation — including its `error:`
  line — sits one level in, and restore it afterwards.
- **Confirm before destroying.** Destructive commands prompt for confirmation
  and never act on "all matches" silently.
- **No new dependencies** unless a task cannot be done well without one. Bash,
  git and coreutils/BSD tools are the budget — `worktree` replaces the
  original's `python3` relative-path call with pure bash.

## Commit conventions

- Imperative sentences, no conventional-commit prefix: "Extract keyframes with a
  scene-change threshold".
- The subject says what changed; the body says **why**, and records the trap that
  was avoided or the measurement that justified the choice.
- One logical change per commit.

## AI attribution — required

Any commit produced with an AI coding assistant — for the code, the docs, the
artwork, or the commit message itself — must end with a trailer naming the
assistant **and** the exact model and version:

```
Assisted-by: <assistant> (<model> <version>)
```

```
Assisted-by: GitHub Copilot (DeepSeek V4 Flash)
```

Rules:

- Name the model you were actually running, and its version when it has one.
  "AI", "Copilot", "an LLM" or a bare tool name is not attribution.
- One trailer per assistant: two assistants on one commit means two
  `Assisted-by:` trailers.
- Use `git commit --trailer "Assisted-by=GitHub Copilot (DeepSeek V4 Flash)"`
  rather than hand-placing the line, so it lands in the trailer block.
- No trailer means the work was written by hand. Never add one for a change you
  did not make.

### Elsewhere, not only in commits

- **Documents and prose** substantially written by an assistant — this file,
  `README.md`, design notes — carry the assistant, model and version, either as
  a note in the document or in a short "AI contributions" list.
- **Release notes, changelogs, tags and pull-request descriptions** written with
  an assistant end with the same `Assisted-by:` trailer.
- **Generated artefacts** that are committed record which tooling produced them,
  so the result can be reproduced.

When in doubt, attribute. An unnecessary trailer costs a line; a missing one
misrepresents who wrote the work.

## General house rules

- **License**: every repository ships a `LICENSE`. This one is MIT.
- **README**: every repository has a README that says what the project is, how
  to install it, and how to use it.
- **Install**: command-line tools install via an idempotent `install.sh` that
  symlinks into `$HOME/bin`, and warn when `$HOME/bin` is not on `PATH` (zsh).
- **Prefer self-contained, low-dependency tooling**: single-file scripts over
  directory trees of sourced fragments.
- **Verify before claiming done**: run the syntax check, the linter, and the
  command in both terminal and piped mode, and record the outcome in the commit
  body.
- **Keep this file current**: when a change introduces a language, library, or
  dependency, update `AGENTS.md` in the same commit — with rationale, a Best
  Practices block, and docs links — and add the matching `.gitignore` patterns
  in that same commit.
