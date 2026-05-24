# ClaudeSwitch

A native macOS menu bar app for switching AI providers on Claude Desktop, with local proxy routing and model discovery support.

Built with Swift + SwiftUI. No external dependencies.

## Features

- **Provider Management** — Add, edit, duplicate, and switch between multiple AI providers
- **Local Proxy** — Lightweight HTTP proxy (NWListener) routes Claude Desktop requests to any Anthropic-compatible API
- **Model Discovery** — Implements Claude Desktop's `/v1/models` endpoint with proper model role mapping (Sonnet / Opus / Haiku)
- **Model Mapping** — Map Claude model roles to upstream models with display name overrides and 1M context declaration
- **Configurable** — Claude Desktop config directory, proxy port, and gateway token all adjustable
- **Auto Config** — Writes 3P profile to Claude Desktop's configLibrary on proxy start, properly manages `_meta.json` entries

## Requirements

- macOS 13.0+ (Ventura)
- Xcode 15+
- Claude Desktop

## Build

```bash
cd ClaudeSwitch
xcodebuild -project ClaudeSwitch.xcodeproj -target ClaudeSwitch -configuration Debug CODE_SIGNING_ALLOWED=NO
open build/Debug/ClaudeSwitch.app
```

## Usage

1. Launch ClaudeSwitch — it appears as a menu bar icon
2. Add a provider via **Providers** tab with your API endpoint and key
3. Configure model routes (map Sonnet/Opus/Haiku to your upstream models)
4. Click **Start Proxy** — writes config to Claude Desktop and starts the local proxy
5. Claude Desktop connects through the proxy to your chosen provider

## How It Works

```
Claude Desktop → http://127.0.0.1:{port}/claude-desktop → ClaudeSwitch Proxy → Upstream API
```

ClaudeSwitch acts as a gateway between Claude Desktop and third-party AI providers. It:

1. Writes a 3P provider profile to Claude Desktop's `configLibrary/` with gateway connection details
2. Runs a local HTTP proxy that authenticates Claude Desktop via gateway token
3. Maps Claude model role IDs (e.g. `claude-sonnet-4-6`) to upstream model names
4. Forwards requests to the configured upstream API and streams responses back

## Architecture

```
ClaudeSwitch/
├── Models/          Provider, ModelRoute, ModelRole
├── ViewModels/      AppState (central state + persistence)
├── Views/           Status, Providers, Settings, MenuBar
├── Services/
│   ├── ProxyServer            NWListener-based HTTP proxy
│   ├── ClaudeDesktopManager   Config file read/write
│   └── PresetProviders        Built-in provider templates
├── ClaudeSwitchApp.swift      @main entry + AppDelegate
└── AppEnvironment.swift       UserDefaults suite + paths
```

~1600 lines of Swift, no dependencies beyond Apple frameworks.

## License

MIT
