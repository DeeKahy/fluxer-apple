# CornFlux

A native client for Fluxer on iOS and macOS, written in Swift and SwiftUI.

[Fluxer](https://fluxer.app) is a free and open source chat platform built for friends, groups, and communities. The official mobile apps are Flutter and the desktop app is Electron. CornFlux is a fully native client for Apple platforms instead: one SwiftUI codebase, real system integration, and it opens instantly. It is currently in personal beta and moving fast.

<!--
SCREENSHOTS: drop real images into docs/media/ then uncomment the block below.
See docs/media/README.md for the suggested shots and filenames.

<p align="center">
  <img src="docs/media/hero.png" alt="Fluxer on iPhone and macOS" width="100%">
</p>
-->

> **Screenshots coming.** Real captures from the app will live here soon. If you want to see it now, grab a build below.

## Get it

### macOS (easy)

Install with Homebrew:

```
brew install --cask deekahy/tap/cornflux
```

Or grab `CornFlux-macOS-Universal.dmg` from the [latest release](https://github.com/DeeKahy/fluxer-apple/releases/latest) and drag **CornFlux** to Applications. It is one universal build that runs on both Intel and Apple Silicon.

The app is signed ad hoc, because I do not have a paid Apple Developer certificate, so macOS quarantines it and calls it "damaged" on first launch. Clear that once:

```
xattr -dr com.apple.quarantine /Applications/CornFlux.app
```

Or open it once, let macOS block it, then click **Open Anyway** under **System Settings > Privacy & Security**. One time per build.

Nix users: a Darwin package for a future nixpkgs submission lives in [packaging/nix/package.nix](packaging/nix/package.nix). Build it with `nix-build packaging/nix`.

### iPhone and iPad (build it yourself)

I am not going to pretend there is a smooth iPhone install, because there is not. Apple will not run an app on iOS unless it is signed, and signing for real distribution needs a paid Apple Developer membership at 99 dollars a year that I cannot afford right now. Until that changes, the honest path onto a device is to build it yourself:

1. Clone this repo and open it in Xcode (see [Building from source](#building-from-source)).
2. Set `DEVELOPMENT_TEAM` in `project.yml` to your own Apple ID team. A free account works.
3. Plug in your iPhone, choose it as the run destination, and press run.

Builds from a free account stop working after seven days and need a rebuild. That is Apple's limit, not mine. If you already run SideStore or AltStore, an unsigned `CornFlux.ipa` is attached to every release and you know what to do with it. I am not writing that guide here.

Everything that would make this painless (a normal install, no seven day expiry, push and calls while the app is closed) unlocks with that paid membership. If you want it to happen, see [Funding](#funding) below.

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
is parked until the project earns it or i can afford it. The same membership would enable CallKit
ringing on the lock screen and remove the seven day resigning cycle for
sideloaded builds.

## Funding

The one thing holding CornFlux back is money for the Apple Developer Program
membership, 99 dollars a year. Everything below is already mapped out and
becomes buildable the moment that membership exists:

- Push notifications and calls arriving with the app closed on iPhone.
  Fluxer uses standard Web Push, so a small relay can forward the encrypted
  pushes through Apple's push service without ever seeing message contents
  or account tokens. Apple only grants push entitlements to paid accounts.
- CallKit: incoming Fluxer calls ring like real phone calls and can be
  answered from the lock screen.
- A public TestFlight beta. TestFlight itself is free with the membership
  and supports up to ten thousand testers through a public link, so anyone
  could install the app in one tap without owning a Mac or building it themselves.
- An eventual App Store release, and no more seven day expiry on builds.

Before setting up any donation infrastructure I want to know people actually
want this. If you'd use the app, give a thumbs up on
[the CallKit and push issue](https://github.com/DeeKahy/fluxer-apple/issues/20)
or open an issue and say hi. If enough people show up, funding the membership
comes next.

## Building from source

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

This is an unofficial community client. Custom clients are explicitly
welcomed by Fluxer. The app uses the same documented HTTP and websocket APIs as the
official web client, and LiveKit for media, matching upstream.

## License

AGPL-3.0, matching upstream Fluxer.
