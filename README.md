# Launch Buddy

macOS tray app that toggles a script on/off with a single click.

## Features

- **Toggle switch** in the menu bar to start/stop your script
- **Brain icon** — hollow when off, filled when running
- **Script output viewer** — live tail with selectable/copyable text, pin to follow or scroll freely
- **Configurable script path** — browse or type any executable path
- **Launch at login** — optional, via system login items
- **Child process cleanup** — the script and its child processes die when the app quits or is terminated (process-group kill on quit, SIGTERM, and SIGINT)

## Requirements

- macOS 14+
- Swift 5.9+

## Build & Run

```bash
./run.sh
```

This builds the project and launches the `.app` bundle.

## Usage

1. Click the 🧠 icon in your menu bar
2. Open **Settings…** and enter your script path
3. Toggle the switch to start/stop the script
4. Click **View Output** to see live stdout/stderr
5. Toggle **Launch at login** if desired

## Project Structure

```
Sources/LaunchBuddy/AppSettings.swift
Sources/LaunchBuddy/Info.plist
Sources/LaunchBuddy/LaunchBuddyApp.swift
Sources/LaunchBuddy/MenuBarControl.swift
Sources/LaunchBuddy/NSTextViewWrapper.swift
Sources/LaunchBuddy/OutputView.swift
Sources/LaunchBuddy/ProcessManager.swift
Sources/LaunchBuddy/SettingsView.swift
```

## Notes

- If `/usr/bin/stdbuf` is available, scripts run through it to force unbuffered stdout/stderr; on older systems they execute directly
- Scripts with `.sh`, `.bash`, `.zsh` extensions are run via `/bin/zsh`
- Non-executable scripts are auto-chmod'd on launch
- Last 1000 lines of output are kept in memory
- The script's process group is killed when the app quits or receives SIGTERM/SIGINT (covers logout, shutdown, and `kill`); a `kill -9` of the app is uncatchable, so its children may survive until they exit on their own
