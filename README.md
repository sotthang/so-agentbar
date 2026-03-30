<p align="center">
  <img src="docs/logo.png" alt="so-agentbar" width="128" height="128">
</p>

<h1 align="center">so-agentbar</h1>

<p align="center">
  macOS menu bar app that monitors your active Claude Code agent sessions in real-time
</p>

<p align="center">
  <a href="https://github.com/sotthang/so-agentbar/releases/latest">Download</a> · <a href="https://sotthang.github.io/so-agentbar/">Website</a>
</p>

## Screenshots

<p align="center">
  <img src="docs/1.png" alt="Menu bar with session dropdown" width="400">
  <br><em>Menu bar icon and active session panel</em>
</p>

<p align="center">
  <img src="docs/2.png" alt="Settings — language and notifications" width="360">
  &nbsp;&nbsp;
  <img src="docs/3.png" alt="Settings — quota and display options" width="360">
  <br><em>Settings: language, notifications, quota threshold, and display options</em>
</p>

## Features

- **Real-time Session Monitoring** — Automatically detects and tracks all running Claude Code sessions (CLI & Xcode)
- **Token & Quota Tracking** — Monitor input/output tokens and API quota usage with 5-hour/weekly utilization
- **Smart Notifications** — Get notified on task completion, errors, approval requests, quota threshold, and quota refill. Tap a notification to open the project directly in your editor
- **Human-in-the-loop Detection** — Automatically detects when an agent is waiting for your approval and sends an alert
- **Statistics Dashboard** — Daily summary, 7-day chart, and top project rankings
- **Global Hotkey** — Toggle the session panel from anywhere (default: ⌥⇧S)
- **Custom Emoji** — Assign unique emoji icons to each project for quick identification
- **Editor Integration** — Open projects directly in VSCode, Cursor, Antigravity, Terminal, or Finder
- **Auto Update** — Built-in updater via Sparkle keeps the app up to date automatically
- **Bilingual UI** — Korean and English support
- **Launch at Login** — Auto-start with macOS via ServiceManagement

## Requirements

- macOS 14.0 (Sonoma) or later
- Active [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions

## Install

1. Download `so-agentbar.dmg` from [Releases](https://github.com/sotthang/so-agentbar/releases/latest)
2. Drag `so-agentbar.app` to Applications
3. Launch — so-agentbar appears in your menu bar

### Build from Source

```bash
git clone https://github.com/sotthang/so-agentbar.git
cd so-agentbar
open AgentBar.xcodeproj
```

Build and run with Xcode (⌘R).

## How It Works

so-agentbar monitors Claude Code session logs via FSEvents:

- **CLI sessions** — `~/.claude/projects/`
- **Xcode sessions** — `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects/`

Session status is determined by parsing JSONL log events. Quota usage is fetched from Anthropic's OAuth API using the token stored in Keychain.

## Settings

| Setting | Description |
|---|---|
| Language | Korean / English |
| Menu Bar Style | Emoji, Emoji + Count, Count Only |
| Editor | VSCode, Cursor, Antigravity, Terminal, Finder |
| Notifications | Completion, Approval Required, Error, Quota Threshold (50-95%), Refill |
| Global Hotkey | Customizable keyboard shortcut |
| Poll Interval | 10s / 30s / 60s fallback polling |
| Idle Sessions | Show or hide idle sessions |
| Launch at Login | Auto-start with macOS |
| Auto Update | Check for updates automatically via Sparkle |

## License

[MIT](LICENSE)
