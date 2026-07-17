# Fluxer Apple

A native Fluxer client for iOS and macOS, written in Swift and SwiftUI.

[Fluxer](https://fluxer.app) is a free and open source chat platform built for friends, groups, and communities. The official mobile apps are Flutter and the desktop app is Electron. This project is a fully native client for Apple platforms instead. It is currently in personal beta and moving fast.

## What works today

**Messaging**
- Full text chat: guilds, channels, DMs, and group DMs with live gateway updates
- History with scroll-up pagination, replies, reactions, editing, deleting, pins
- Attachments with photo picker (iOS) and file panel (macOS), inline image rendering,
  full screen viewer with zoom and share
- Markdown, code blocks, custom emoji with a picker, clickable channel mentions,
  link embeds, invite cards with join and open actions
- Unread tracking synced across devices, new messages divider, typing indicators,
  slowmode and permission aware composer

**Voice and video**
- Voice channels and DM calls over LiveKit: join, mute, speaking indicators,
  occupancy in the channel list
- Outgoing calls ring the other side, incoming calls show an accept/decline banner
- Video calls and screen share viewing: tap to focus a stream, pinch to zoom and
  pan, camera flip on iOS, camera picker and screen share publishing on macOS

**Social and account**
- Friends, requests, blocks, profiles, presence dots, own status
- Member lists with moderation actions where permitted
- Sessions manager, TOTP and email-confirmation login, captcha support,
  browser handoff login for passkey accounts

**Platform**
- One SwiftUI codebase: drill-down navigation on iPhone, three pane split on
  Mac and iPad
- Disk cache so the app renders instantly on launch
- Native notifications for DMs, mentions, and incoming calls, with a dock and
  app icon badge (see the notifications note below)
- Self hosting support: point the login screen at any Fluxer instance and the
  app reads its bootstrap config, including captcha provider and endpoints

## Notifications and the closed-app problem

While the app is running and connected, notifications are fully native on both
platforms. On the Mac you can close the window and keep the app running and it
keeps notifying, including for incoming calls.

When the app is not running on iPhone, iOS kills the connection, so nothing can
arrive. Fixing that for a third-party client is possible because Fluxer uses
standard Web Push with client-chosen endpoints: the plan is a small self-hosted
relay that receives Fluxer's encrypted pushes and forwards them through APNs to
wake the app, end to end encrypted, without ever holding the account token.
This requires a paid Apple Developer membership for the push entitlement, so it
is parked until the project earns it. The same membership would enable CallKit
ringing on the lock screen and remove the seven day resigning cycle for
sideloaded builds.

## Building

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
xcodegen generate
open Fluxer.xcodeproj
```

FluxerKit, the networking core (REST, gateway, models, permissions), is a Swift
package at the repo root with its own test suite: `swift test`.

To run on a device, set `DEVELOPMENT_TEAM` in project.yml to your own team id.
Free Apple accounts work; apps expire after seven days and need a rebuild.

## Relation to Fluxer

This is an unofficial community client. Fluxer's terms of service do not
prohibit third-party clients and a small ecosystem of them already exists. It
uses the same documented HTTP and websocket APIs as the official web client,
and LiveKit for media, matching upstream.

## License

AGPL-3.0, matching upstream Fluxer.
