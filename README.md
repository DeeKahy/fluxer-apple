# Fluxer Apple

A native Fluxer client for iOS and macOS, written in Swift and SwiftUI.

[Fluxer](https://fluxer.app) is a free and open source chat platform built for friends, groups, and communities. The official mobile apps are Flutter and the desktop app is Electron. This project aims to build a fully native client for Apple platforms instead.

## Why native

- **Calls that feel like calls.** CallKit and PushKit integration so incoming Fluxer calls ring on the lock screen, show the native call UI, and work when the app is not running.
- **A composer that behaves.** Native text input with correct autocorrect, dictation, keyboard avoidance, and international input. Chat apps live and die by the message box.
- **Smooth history.** Native list performance and predictable memory use while scrolling through months of messages and media.
- **Platform integration.** Share extension, notification reply actions, widgets, Shortcuts, menu bar and keyboard shortcuts on the Mac, and real accessibility support.

## One codebase, two platforms

The plan is a single SwiftUI codebase with real iOS and macOS destinations, not a Catalyst port. Roughly 80 percent of the code (networking, models, view models, most views) is shared. The remaining platform layer adapts navigation: tab bar on iPhone, sidebar and multi-window on the Mac.

Planned structure:

- **FluxerKit** - Swift package with the API client, gateway (WebSocket) connection, models, and persistence. UI-independent, fully testable.
- **App target (iOS)** - iPhone and iPad UI, CallKit/PushKit, share extension.
- **App target (macOS)** - sidebar navigation, menu bar commands, keyboard-first UX.

## Status

Planning. Nothing to run yet.

Rough order of attack:

1. FluxerKit: auth, REST client, gateway connection with heartbeat/resume
2. Message list and composer (iOS first)
3. Guilds, channels, DMs navigation on both platforms
4. Media upload and viewing
5. Voice with CallKit
6. Polish: notifications, share extension, widgets

## Relation to Fluxer

This is an unofficial community client. Fluxer's terms of service do not prohibit third-party clients and a small ecosystem of them already exists. This project uses the documented HTTP and WebSocket APIs at [docs.fluxer.app](https://docs.fluxer.app).

## License

AGPL-3.0, matching upstream Fluxer.
