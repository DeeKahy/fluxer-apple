# Roadmap

Grounded in the actual Fluxer API surface (fluxer_app/src/features/app/constants/Endpoints.ts
upstream). Checked items are built and QA'd in the app.

## Done

- [x] Auth: email/password login, captcha (hCaptcha in a web view), TOTP MFA,
      new device email confirmation, browser login handoff for passkey accounts,
      keychain token storage, session restore
- [x] Gateway: identify, heartbeat, resume, reconnect with backoff
- [x] Guilds, channels, DMs from READY, live updates for guild/channel events
- [x] Messages: history with scroll-up pagination, send, live create/update/delete,
      message grouping, day dividers
- [x] Unread state: read states from READY, acks on view, MESSAGE_ACK sync, unread dots
- [x] Typing indicators both directions
- [x] Media: avatars, guild icons, inline image attachments, cached loader
- [x] Markdown: inline styles, links, clickable channel mentions, named user mentions
- [x] iPhone drill-down and Mac/iPad split layouts

## Messaging, near term

- [x] Send attachments (multipart payload_json + files path; presigned two phase
      upload for big files still todo), photo picker on iOS, file panel on macOS
- [x] Replies: referenced message preview on rows, context menu to reply
- [x] Reactions: pills with counts, toggle via tap or context menu quick picks,
      MESSAGE_REACTION_ADD/REMOVE gateway events, custom emoji rendering
- [x] Edit and delete own messages from a context menu
- [x] Guilds open on the last visited channel, falling back to the first
- [ ] Pins: view pinned messages (GET .../messages/pins), pin/unpin
- [ ] Link previews: render embeds that arrive on messages, /unfurl for composing
- [ ] Mentions feed: /users/@me/mentions as a "recent mentions" screen
- [ ] Saved messages: /users/@me/saved-messages, save from context menu
- [ ] Scheduled messages: compose with a send-at time (/channels/{id}/messages/schedule)
- [ ] Bulk delete my messages in a channel or guild (bulk-delete-mine endpoints)
- [x] Slowmode awareness: cooldown countdown in the composer, bypass permissions
      respected, server rate limit answers extend the cooldown
- [ ] Custom emoji: render guild emoji in messages, emoji picker for composing,
      sticker rendering and picker (guild emojis/stickers endpoints, packs)
- [ ] GIF picker: /gifs/search, /gifs/trending, /gifs/featured
- [ ] Group DM management: create group (POST /users/@me/channels), add/remove
      recipients, leave

## Social

- [x] Friends list: relationships from READY plus RELATIONSHIP_* events, add by
      username, accept/ignore/remove/unblock, open DM from the list
- [ ] User profiles: /users/{id}/profile popover (bio, pronouns), personal notes
      (/users/@me/notes/{id})
- [x] Presence: online/idle/dnd dots from READY and PRESENCE_UPDATE (setting own
      status still todo)
- [ ] Pinned DMs: /users/@me/channels/{id}/pin
- [ ] User connections display (Bluesky etc.)

## Guild management

- [ ] Create guild, edit name/icon/description, delete/leave
- [ ] Invites: create (POST /channels/{id}/invites), list, accept (/invites/{code}),
      invite paste-to-join UI
- [x] Member list sheet: first 200 members with local search and presence dots
      (full pagination and server-side search still todo)
- [ ] Roles: display colors and hoisting in member list, role management screens
- [ ] Moderation: kick, ban, timeout, audit logs
- [x] Permissions: per-channel computation with tests, composer locks when send
      is denied, attach and member list buttons follow their permissions
- [ ] Webhooks management
- [ ] Guild settings: notifications per guild (/users/@me/guilds/{id}/settings)
- [ ] Discovery: browse public guilds (/discovery/guilds), join

## Voice and video (big)

- [ ] Voice state tracking: who is in which voice channel (voice_states in READY,
      VOICE_STATE_UPDATE)
- [ ] Join voice: gateway op 4, VOICE_SERVER_UPDATE, WebRTC media engine
- [ ] DM calls: /channels/{id}/call, ring, stop-ringing
- [ ] CallKit integration: native incoming call UI, PushKit wake
- [ ] Screen share viewing (stream previews exist in the API)
- [ ] Entrance sounds (they exist and they are funny)

## Notifications

- [ ] Push: APNs registration, /users/@me/push/subscribe (needs investigation,
      upstream may only support web push; worst case local notifications while
      the app runs, real APNs likely needs upstream support)
- [ ] In-app: badge counts on the app icon from unread and mention counts
- [ ] Notification settings respect (user_guild_settings mute/suppress)

## Account and settings

- [ ] Settings screen: user settings sync (/users/@me/settings covers theme,
      locale, and more), edit profile (avatar upload, bio, pronouns)
- [ ] Sessions manager: list and revoke active sessions (/auth/sessions)
- [ ] MFA management: enable TOTP in-app, backup codes, authorized IPs
- [ ] Native passkey MFA (ASAuthorization) once Fluxer serves an AASA file, or
      keep handoff as the answer
- [ ] Data export (/users/@me/harvest), account disable/delete flows

## Platform polish

- [ ] macOS: menu bar commands (jump to channel, next unread), keyboard shortcuts,
      multi-window, dock badge
- [ ] iOS: share extension (share images/text into a channel), home screen widgets,
      App Intents/Shortcuts
- [ ] Image viewer: tap attachment to view full screen, save, share
- [ ] Better message list: scroll-position restoration per channel, jump to
      first unread, "new messages" divider
- [ ] Block quotes, code blocks, and spoilers as real styled blocks
- [ ] Accessibility pass: VoiceOver labels, Dynamic Type
- [ ] Localization scaffolding

## Self hosting support

- [ ] Instance picker at login: accept any base URL, read /instance bootstrap
      (captcha provider and keys, gateway URL, media endpoints) instead of
      hardcoding fluxer.app values
- [ ] Multi account switching (auth handoff and account storage exist upstream)

## Engineering

- [ ] Move chat state out of AppSession into a ChatStore before it gets bigger
- [ ] Persist message cache to disk so channels open instantly offline
- [ ] Gateway event decoding tests for every handled event type
- [ ] UI tests for login flow with a stubbed API
- [ ] CI: build and test on push (GitHub Actions, macOS runner)
- [ ] TestFlight or ad hoc distribution so QA doesn't need the simulator

## Explicitly out of scope for now

- Premium/Stripe/Swish payment flows (use the web app)
- Admin/instance-config endpoints
- OAuth application management
- DSA reports (use the web app)
