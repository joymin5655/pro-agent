# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
