# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] - 2026-11-07

### Added
- `pdf` skill: puts a PDF into a notes folder (Obsidian vault or plain markdown) as a note with front matter and a page marker plus a link to the same page of the original PDF; the original is copied (or linked in place when it already lives in the vault).
- `skills/pdf/pdf-to-note.sh`: converter wrapper (opendataloader-pdf + Java 11+, finds Homebrew's keg-only Java), name-collision and unsafe-character handling, `--prepare` for Claude-read notes, `--check`, `--info`. Exit code 3 means the converter or Java is missing. Also looks in `~/.local/bin` (uv tool / pipx default) and accepts PDF names starting with `-` (the converter gets an absolute path).
- `ask` skill: keyword search over the notes with scout; every answer cites the note and the page link, and says "not found in notes" instead of guessing.
- `setup` checks for the converter and Java and prints install hints (it installs nothing).
- Tests: `tests/test-pdf-to-note.sh` (stub converter, plus a real conversion when the tool is installed) with a small generated English sample PDF; four more skill-trigger evals (pdf, ask, and two that must not fire).

### Changed
- Converter install instructions use `uv tool install` (the converter needs Python 3.11+, which macOS's system Python lacks).
- Docs: README section on PDF notes, converter comparison, data flow; `docs/how-it-works.md` and `docs/safety.md` updated.

## [0.1.0] - 2026-11-06

### Added
- Subagents: `scout` (Haiku), `reviewer` (Sonnet), `judge` (Opus).
- Seven skills: `plan`, `do`, `check`, `decide`, `research`, `save`, `setup`.
- Operating rules (`rules/operating-rules.md`), injected at session start.
- Hooks: a SessionStart hook that prints the rules and the project's progress note, and a PreToolUse(Bash) guard that denies or asks about risky commands.
- Tests for both hooks and a structure validator, plus five eval cases for skill triggering.
- GitHub Actions workflow: hook tests on Linux and macOS, shellcheck, and `claude plugin validate --strict`.
- README, `docs/how-it-works.md`, `docs/safety.md`.

### Notes
- The plugin is named `pro-agent` because plugin names may not start with `claude-`.
- The Bash guard reads only the `command` string, unescapes it, joins backslash-continued lines and
  judges it in two views: split at every `;`, `&&`, `||`, `&`, `|`, newline and `$(...)` even inside
  quotes (so code in strings such as `bash -c '...'` is judged), and split only at top-level separators
  (so a quoted value or `$(...)` holding `(`, `&` or `;` cannot cut a command off from its later
  options; this view skips comments and here-document bodies, so an apostrophe in them cannot hide
  the commands that follow). Each command has its prefixes stripped (shell keywords, leading redirections, `sudo`,
  `env -S`, `exec -a`, `nice`, `time`, `timeout`, `caffeinate`, `stdbuf`, `ionice`, `setsid`, `bash -c`,
  with their option values) and is judged by name. `dd` to `/dev/null`, `/dev/zero`, `/dev/stdout`,
  `/dev/stderr`, `/dev/tty` or `/dev/fd/*` is allowed; other `of=/dev/...` targets are still denied.
  A download handed to a shell without a pipe (`bash -c "$(curl ...)"`, `bash <(curl ...)`,
  `eval "$(curl ...)"` and similar forms) is asked about too.
