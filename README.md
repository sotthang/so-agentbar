<p align="center">
  <img src="docs/logo.png" alt="AgentBar" width="128" height="128">
</p>

<h1 align="center">AgentBar</h1>

<p align="center">
  macOS menu bar app that monitors your active Claude Code agent sessions in real-time
</p>

<p align="center">
  <a href="https://github.com/sotthang/so-agentbar/releases/latest">Download</a> · <a href="https://sotthang.github.io/so-agentbar/">Website</a>
</p>

## Features

- **Real-time Session Monitoring** — Automatically detects and tracks all running Claude Code sessions (CLI & Xcode)
- **Token & Quota Tracking** — Monitor input/output tokens and API quota usage with 5-hour/weekly utilization
- **Smart Notifications** — Get notified on task completion, errors, quota threshold, and quota refill
- **Statistics Dashboard** — Daily summary, 7-day chart, and top project rankings
- **Global Hotkey** — Toggle the session panel from anywhere (default: ⌥⇧S)
- **Custom Emoji** — Assign unique emoji icons to each project for quick identification
- **Editor Integration** — Open projects directly in VSCode, Cursor, Terminal, or Finder
- **Bilingual UI** — Korean and English support
- **Launch at Login** — Auto-start with macOS via ServiceManagement

## Requirements

- macOS 14.0 (Sonoma) or later
- Active [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions

## Install

1. Download `AgentBar.dmg` from [Releases](https://github.com/sotthang/so-agentbar/releases/latest)
2. Drag `AgentBar.app` to Applications
3. Launch — AgentBar appears in your menu bar

### Build from Source

```bash
git clone https://github.com/sotthang/so-agentbar.git
cd so-agentbar
open AgentBar.xcodeproj
```

Build and run with Xcode (⌘R).

## How It Works

AgentBar monitors Claude Code session logs via FSEvents:

- **CLI sessions** — `~/.claude/projects/`
- **Xcode sessions** — `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects/`

Session status is determined by parsing JSONL log events. Quota usage is fetched from Anthropic's OAuth API using the token stored in Keychain.

## Settings

| Setting | Description |
|---|---|
| Language | Korean / English |
| Menu Bar Style | Emoji, Emoji + Count, Count Only |
| Editor | VSCode, Cursor, Terminal, Finder |
| Notifications | Completion, Error, Quota Threshold (50-95%), Refill |
| Global Hotkey | Customizable keyboard shortcut |
| Poll Interval | 10s / 30s / 60s fallback polling |
| Idle Sessions | Show or hide idle sessions |
| Launch at Login | Auto-start with macOS |

## License

[MIT](LICENSE)
