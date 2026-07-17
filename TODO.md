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
- [x] Pins: pins sheet per channel, pin/unpin from context menu, permission gated
- [x] Link previews: embeds render (color bar, author, title, description, image,
      footer); /unfurl while composing still todo
- [x] Mentions feed: recent mentions screen in the account menu
- [x] Saved messages: save/unsave from context menu, saved list in account menu
- [ ] Scheduled messages: compose with a send-at time (/channels/{id}/messages/schedule)
- [ ] Bulk delete my messages in a channel or guild (bulk-delete-mine endpoints)
- [x] Slowmode awareness: cooldown countdown in the composer, bypass permissions
      respected, server rate limit answers extend the cooldown
- [x] Custom emoji: emoji-only messages render images, tokens show names inline,
      picker inserts guild emoji (stickers and packs still todo)
- [ ] GIF picker: /gifs/search, /gifs/trending, /gifs/featured
- [ ] Group DM management: create group (POST /users/@me/channels), add/remove
      recipients, leave

## Social

- [x] Friends list: relationships from READY plus RELATIONSHIP_* events, add by
      username, accept/ignore/remove/unblock, open DM from the list
- [x] User profiles: profile sheet on avatar tap with bio, pronouns, message and
      add friend actions (personal notes still todo)
- [x] Presence: online/idle/dnd dots, own status via account menu (session only,
      not persisted to user settings yet)
- [x] Pinned DMs: pin/unpin from DM context menu, pinned sort first
- [ ] User connections display (Bluesky etc.)

## Guild management

- [x] Create guild and leave guild (editing name/icon still todo)
- [x] Invites: create from channel context menu with copyable link, join by code
      or link from the sidebar plus menu
- [x] Member list sheet: first 200 members with local search and presence dots
      (full pagination and server-side search still todo)
- [ ] Roles: display colors and hoisting in member list, role management screens
- [x] Moderation: kick and ban from member list with confirmation (timeout and
      audit logs still todo)
- [x] Permissions: per-channel computation with tests, composer locks when send
      is denied, attach and member list buttons follow their permissions
- [ ] Webhooks management
- [ ] Guild settings: notifications per guild (/users/@me/guilds/{id}/settings)
- [ ] Discovery: browse public guilds (/discovery/guilds), join

## Voice and video

- [x] Voice state tracking: occupancy from READY and VOICE_STATE_UPDATE, avatars
      with speaking rings in channel rows
- [x] Join voice: op 4, VOICE_SERVER_UPDATE, LiveKit room, mic publish, presence
      heartbeat, mute, voice bar with participants and speaking indicators
- [x] DM calls: ring after connect (order matters, server rejects early rings),
      outgoing calling state, incoming call banner with accept and decline
- [ ] Ring sounds: ringtone while banner shows, ringback while calling
- [ ] CallKit integration: native incoming call UI, PushKit wake (needs real device)
- [ ] Video: camera tracks and screen share viewing over the same LiveKit room
- [ ] Deafen, output device picker, e2ee_key handling for encrypted calls
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
- [x] Sessions manager: list devices, revoke any non-current session
- [ ] MFA management: enable TOTP in-app, backup codes, authorized IPs
- [ ] Native passkey MFA (ASAuthorization) once Fluxer serves an AASA file, or
      keep handoff as the answer
- [ ] Data export (/users/@me/harvest), account disable/delete flows

## Platform polish

- [ ] macOS: menu bar commands (jump to channel, next unread), keyboard shortcuts,
      multi-window, dock badge
- [ ] iOS: share extension (share images/text into a channel), home screen widgets,
      App Intents/Shortcuts
- [x] Image viewer: tap attachment for full screen with pinch zoom and share
- [x] New messages divider where reading left off (scroll restoration and jump
      to first unread still todo)
- [x] Fenced code blocks as monospaced boxes (quotes and spoilers still todo)
- [ ] Accessibility pass: VoiceOver labels, Dynamic Type
- [ ] Localization scaffolding

## Self hosting support

- [x] Instance picker at login: reads any instance's bootstrap (endpoints and
      captcha config, hCaptcha or Turnstile), persisted across launches
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
