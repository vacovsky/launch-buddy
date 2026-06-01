# llmlaunch

macOS tray app that toggles a script on/off with a single click.

## Features

- **Toggle switch** in the menu bar to start/stop your script
- **Brain icon** — hollow when off, filled when running
- **Script output viewer** — live tail with selectable/copyable text, pin to follow or scroll freely
- **Configurable script path** — browse or type any executable path
- **Launch at login** — optional, via system login items
- **Child process cleanup** — script dies when the app quits (process group kill)

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
Sources/llmlaunch/AppSettings.swift
Sources/llmlaunch/Info.plist
Sources/llmlaunch/llmlaunchApp.swift
Sources/llmlaunch/MenuBarControl.swift
Sources/llmlaunch/OutputView.swift
Sources/llmlaunch/ProcessManager.swift
Sources/llmlaunch/SettingsView.swift
Sources/llmlaunch/Test.swift
```

## Notes

- Scripts with `.sh`, `.bash`, `.zsh` extensions are run via `/bin/zsh`
- Non-executable scripts are auto-chmod'd on launch
- Last 1000 lines of output are kept in memory
- Child processes are killed via process group on app quit
