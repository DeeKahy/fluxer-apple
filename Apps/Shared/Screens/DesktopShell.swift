import SwiftUI
import FluxerKit

/// Marks views living inside the desktop shell so shared screens can
/// swap in the desktop styling (hover tools, boxed composer).
private struct DesktopChromeKey: EnvironmentKey {
    static let defaultValue = false
}

/// True while the transcript is actively being scrolled, so desktop message
/// rows can drop their hover chrome (highlight + floating toolbar) until the
/// scroll settles. Scrolling drags rows under a stationary cursor, firing
/// onHover on every row it passes; re-rendering the toolbar for each one made
/// the wheel feel laggy.
private struct TranscriptScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var desktopChrome: Bool {
        get { self[DesktopChromeKey.self] }
        set { self[DesktopChromeKey.self] = newValue }
    }

    var transcriptScrolling: Bool {
        get { self[TranscriptScrollingKey.self] }
        set { self[TranscriptScrollingKey.self] = newValue }
    }
}

/// Desktop shell in the comp's anatomy: workspace rail, one sidebar with
/// channels + voice + DMs, the chat column, and slide-in right panels.
struct DesktopShell: View {
    @Environment(AppSession.self) private var session

    @AppStorage("currentWorkspace") private var currentWorkspaceId = ""
    @State private var selectedChannel: Channel?
    @State private var searchText = ""
    @State private var showMembers = false
    @State private var profileUser: User?
    @State private var showPins = false
    @State private var callMinimized = false
    @State private var callConnectedAt: Date?
    @State private var showJoinPrompt = false
    @State private var joinCode = ""
    @State private var showCreatePrompt = false
    @State private var newGuildName = ""

    private var currentGuild: Guild? {
        session.guilds.first { $0.id.stringValue == currentWorkspaceId } ?? session.guilds.first
    }

    private var callActive: Bool { session.voice.isActive }

    var body: some View {
        HStack(spacing: 0) {
            DesktopRail(
                currentGuildId: currentGuild?.id,
                onSelect: { guild in
                    currentWorkspaceId = guild.id.stringValue
                    if selectedChannel?.guildId != guild.id {
                        selectedChannel = session.defaultChannel(for: guild)
                    }
                },
                onJoin: { showJoinPrompt = true },
                onCreate: { showCreatePrompt = true }
            )
            DesktopSidebar(
                guild: currentGuild,
                selectedChannel: $selectedChannel,
                searchText: $searchText,
                onRestoreCall: { callMinimized = false },
                onOpenProfile: { profileUser = $0 }
            )
            .frame(width: 256)
            .background {
                #if os(macOS)
                BehindWindowBlur(material: .sidebar)
                    .overlay(Theme.sidebarBg.opacity(0.72))
                    .ignoresSafeArea()
                #else
                Theme.sidebarBg
                #endif
            }
            .overlay(alignment: .trailing) { Theme.hairline.frame(width: 1) }
            mainColumn
            if showMembers, let guild = currentGuild {
                DesktopMembersPanel(
                    guildId: guild.id,
                    onClose: { showMembers = false },
                    onOpenProfile: { profileUser = $0 }
                )
                .transition(.move(edge: .trailing))
            } else if let user = profileUser {
                DesktopProfilePanel(
                    user: user,
                    onClose: { profileUser = nil },
                    onOpenDM: { channel in
                        profileUser = nil
                        selectedChannel = channel
                    }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .background(Theme.deskBg)
        .safeAreaInset(edge: .top, spacing: 0) { IncomingCallBanner() }
        .sheet(isPresented: $showPins) {
            if let channel = selectedChannel {
                PinsView(channel: channel)
            }
        }
        .alert("Join a guild", isPresented: $showJoinPrompt) {
            TextField("Invite code or link", text: $joinCode)
            Button("Join") {
                let code = joinCode
                joinCode = ""
                Task { _ = await session.joinGuild(code: code) }
            }
            Button("Cancel", role: .cancel) { joinCode = "" }
        }
        .alert("Create a guild", isPresented: $showCreatePrompt) {
            TextField("Guild name", text: $newGuildName)
            Button("Create") {
                let name = newGuildName
                newGuildName = ""
                Task { _ = await session.createGuild(name: name) }
            }
            Button("Cancel", role: .cancel) { newGuildName = "" }
        }
        .onChange(of: session.channelJump) { _, jump in
            guard let jump else { return }
            session.channelJump = nil
            if let guildId = jump.guildId {
                currentWorkspaceId = guildId.stringValue
            }
            selectedChannel = jump
            searchText = ""
        }
        .onChange(of: callActive) { _, active in
            callMinimized = false
            callConnectedAt = active ? Date() : nil
        }
        .onChange(of: selectedChannel?.id) { _, newId in
            // Opening another channel or DM mid-call shrinks the call to
            // the pill so the conversation is readable; the call keeps going.
            if callActive, newId != session.voice.connectedChannelId {
                callMinimized = true
            }
        }
        .task(id: session.guilds.count) {
            // Open straight into the guild's default channel like the comp,
            // instead of an empty pick-a-conversation state.
            if selectedChannel == nil, let guild = currentGuild {
                selectedChannel = session.defaultChannel(for: guild)
            }
        }
    }

    // MARK: Main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            DesktopConversationHeader(
                channel: selectedChannel,
                membersOpen: showMembers,
                onPins: { showPins = true },
                onToggleMembers: {
                    profileUser = nil
                    showMembers.toggle()
                }
            )
            ZStack {
                Group {
                    if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        DesktopSearchResults(
                            query: searchText,
                            guild: currentGuild,
                            onOpenChannel: { channel in
                                selectedChannel = channel
                                searchText = ""
                            },
                            onOpenProfile: { profileUser = $0 }
                        )
                    } else if let channel = selectedChannel {
                        MessageView(channel: channel)
                            .id(channel.id)
                            .environment(\.desktopChrome, true)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(Theme.faint)
                            Text("Pick a conversation")
                                .foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if callActive && !callMinimized {
                    DesktopCallView(
                        connectedAt: callConnectedAt,
                        onMinimize: { callMinimized = true }
                    )
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.deskBg)
        .overlay(alignment: .bottomTrailing) {
            if callActive && callMinimized {
                DesktopCallPill(
                    connectedAt: callConnectedAt,
                    onOpen: { callMinimized = false }
                )
                .padding([.trailing, .bottom], 20)
            }
        }
    }
}

/// Row button style for the desktop sidebar and panels. Unlike
/// PressableRowStyle it adds no padding or background of its own, the
/// rows draw those themselves to stay on the comp's 6px geometry.
struct DeskRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Small x button used by the right panels.
struct PanelCloseButton: View {
    var dark = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(dark ? .white : Theme.icon)
                .frame(width: 30, height: 30)
                .background(
                    dark ? AnyShapeStyle(.black.opacity(0.35)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(SquishButtonStyle())
    }
}

func copyToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
