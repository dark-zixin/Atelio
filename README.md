[English](README.md) | [繁體中文](README.zh-TW.md)

# Atelio

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![macOS 26.4+](https://img.shields.io/badge/macOS-26.4%2B-brightgreen)

A macOS container for running multiple AI CLIs (Claude Code, Codex, Gemini, …) as workers in terminal windows, driven by your main AI through a simple `atelio` command line. Orchestrate many AI workers in parallel — like a PM dispatching tasks.

**[Download Latest Release](https://github.com/dark-zixin/Atelio/releases/latest)**

<!-- hero image / demo: TBD -->

## The Problem

You want several AI CLIs working at once — one reviewing code, one writing tests, one researching — but each lives in its own terminal:

- **No unified control** — you manually switch windows, watch for completion, copy-paste between them
- **No "turn done" signal** — a terminal multiplexer (tmux) can tile windows but doesn't understand when an AI CLI has *finished a turn*, so you can't programmatically collect results
- **One orchestrator, many workers** — there's no clean way for a single main AI to dispatch to, observe, and coordinate other AI workers

## How It Works

1. Atelio runs each AI CLI as a **worker** inside a terminal session
2. Your main AI drives them through the `atelio` CLI — `open` / `dispatch` / `wait` / `screen`
3. Atelio detects when each worker **finishes a turn** (via hook, or a screen-stability heuristic) and returns the de-noised output of just that turn

Your main AI acts as the orchestrator (PM); Atelio manages the terminals, relays text, and reports status — it never routes or decides for you.

## Screenshots

<!-- screenshots: TBD -->

## Features

- **Multi-session terminal container** with automatic layout (1 fullscreen / 2 side-by-side / 2×2 grid)
- **CLI-driven orchestration** — `open` / `dispatch` / `wait` / `screen` / `send-keys` / `reset` / `close`
- **Turn-completion detection** — precise hook notifications, with a screen-stability fallback
- **Owner binding** — sessions you open are yours to drive; others are read-only
- **Approval handling** — `send-keys` operates the worker's TUI menus (approval prompts)
- **Output de-noising + turn slicing** — returns only the current turn's clean output
- **Any AI CLI** — built-in allowlist for `claude` / `codex` / `gemini` / `aider`, extensible via config
- **No special permissions** — no Accessibility / Screen Recording; local Unix socket, no network

## System Requirements

- macOS 26.4 or later
- The AI CLIs you want as workers, installed yourself (e.g. `claude` / `codex` / `gemini`)

## Installation

1. Download the latest `Atelio.dmg` from [Releases](../../releases)
2. Open the DMG and drag **Atelio** to **Applications**
3. Launch from Launchpad / Applications

On first launch Atelio sets up `~/.atelio/` (config, log, socket, CLI symlink, skill mirror) automatically.

> If macOS blocks the app, right-click > Open once. (Notarized builds open directly.)

## First-Time Setup: Teach Your AI About Atelio

Atelio ships an operation manual (a skill), mirrored to `~/.atelio/skills/atelio/` on launch. The last step is linking it into your main AI's skill search path:

- **Easiest** — open Atelio's **Help** window and copy the prompt into your AI; it links the skill based on its own environment
- **Manual** — symlink `~/.atelio/skills/atelio` into your AI's skill directory (symlink recommended, so app updates flow through). Common locations: Claude Code `~/.claude/skills/`, Codex / Gemini `~/.agents/skills/`

Then just tell your main AI in natural language: "open a codex worker in /repo and do X."

## Usage

Day-to-day operation goes through your main AI via the skill; you just keep Atelio running. The underlying CLI lives at the fixed path `~/.atelio/bin/atelio`:

| Command | Purpose |
|---|---|
| `atelio open <name> --cmd <cli> --dir <path>` | Open a worker session |
| `atelio dispatch <name> "<task>"` | Dispatch a task and wait for completion |
| `atelio wait <name>` | Wait for an in-progress turn |
| `atelio screen <name>` | View the current screen (read-only, any session) |
| `atelio list` / `atelio status <name>` | Inspect session state |
| `atelio send-keys <name> <key>` | Send a keystroke to the TUI (approval menus) |
| `atelio reset <name>` | Force-end a stuck turn |
| `atelio close <name>` | Close a session |

Full commands, result codes, and workflows are in [`skill/atelio/SKILL.md`](skill/atelio/SKILL.md). The in-app Help window has a quick reference and shortcuts.

### Keyboard Shortcuts

`⌘=` zoom in · `⌘-` zoom out · `⌘0` reset · `⌘W` close window (app keeps running) · `⌘Q` quit

## Trust Model

Atelio is a local desktop app running as your regular user:

- The workers it spawns are **AI CLIs you installed yourself**, run in your shell environment
- IPC uses a local Unix domain socket (`~/.atelio/atelio.sock`) — **no network connections of its own**
- All data lives under `~/.atelio/`
- **No** Accessibility, Screen Recording, or Full Disk Access required

## Uninstall

1. Delete `/Applications/Atelio.app` and `~/.atelio/`
2. Remove the `atelio` symlink from your AI's skill directory (e.g. `~/.claude/skills/atelio`)
3. If you installed completion hooks, remove the entries pointing to `~/.atelio/notify.sh` from your AI CLIs' configs

## Building from Source

1. Clone the repository
2. Open `Atelio/Atelio.xcodeproj` in Xcode
3. Select the **Atelio** scheme and run (requires macOS 26.4+ SDK)

SwiftTerm is resolved automatically via Swift Package Manager; the embedded AtelioCLI and AtelioShared.framework are handled by the build.

## Contributing

Issues and pull requests are welcome. For bug reports, please include your macOS version and which AI CLI you were running as a worker.

## License

[MIT License](LICENSE) © 2026 dark-zixin
