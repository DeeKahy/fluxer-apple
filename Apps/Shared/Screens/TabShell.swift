import SwiftUI
import FluxerKit

/// iPhone shell on native navigation: a system TabView (Liquid Glass bar on
/// iOS 26), large titles, and a native search field. Guilds are workspaces,
/// switched from the home title menu or the grid switcher.
struct TabShell: View {
    @Environment(AppSession.self) private var session

    enum Tab: String, CaseIterable {
        case home, dms, activity, search, you
    }

    @State private var tab: Tab = .home
    @State private var homePath = NavigationPath()
    @State private var dmsPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var showWorkspaces = false
    @AppStorage("currentWorkspace") private var currentWorkspaceId = ""

    private var currentGuild: Guild? {
        session.guilds.first { $0.id.stringValue == currentWorkspaceId } ?? session.guilds.first
    }

    private var unreadDMCount: Int {
        session.privateChannels.filter { session.isUnread($0) }.count
    }

    private var mentionTotal: Int {
        session.guildMentionTotal
    }

    /// Re-tapping the home tab brings up the workspace switcher.
    private var tabSelection: Binding<Tab> {
        Binding {
            tab
        } set: { newValue in
            if newValue == tab, newValue == .home {
                showWorkspaces = true
            }
            tab = newValue
        }
    }

    var body: some View {
        decoratedTabView
            .safeAreaInset(edge: .top, spacing: 0) {
                IncomingCallBanner()
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showWorkspaces) {
                WorkspaceSwitcherView(currentId: $currentWorkspaceId)
            }
            #else
            .sheet(isPresented: $showWorkspaces) {
                WorkspaceSwitcherView(currentId: $currentWorkspaceId)
                    .frame(minWidth: 520, minHeight: 480)
            }
            #endif
            .onChange(of: session.channelJump) { _, jump in
                guard let jump else { return }
                session.channelJump = nil
                if jump.type == .dm || jump.type == .groupDM {
                    tab = .dms
                    dmsPath.append(jump)
                } else {
                    tab = .home
                    homePath.append(jump)
                }
            }
    }

    /// The voice pill rides in the iOS 26 bottom accessory slot (the Music
    /// mini-player treatment); older systems get an inset bar above the tabs.
    @ViewBuilder
    private var decoratedTabView: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // The accessory capsule renders even when its content is empty,
            // so only attach it while a call is live.
            if session.voice.isActive {
                tabView
                    .tabBarMinimizeBehavior(.onScrollDown)
                    .tabViewBottomAccessory {
                        VoiceAccessoryBar()
                    }
            } else {
                tabView
                    .tabBarMinimizeBehavior(.onScrollDown)
            }
        } else {
            tabView
                .safeAreaInset(edge: .bottom, spacing: 0) { VoiceBar() }
        }
        #else
        tabView
            .safeAreaInset(edge: .bottom, spacing: 0) { VoiceBar() }
        #endif
    }

    private var tabView: some View {
        TabView(selection: tabSelection) {
            NavigationStack(path: $homePath) {
                HomeTab(guild: currentGuild, openWorkspaces: { showWorkspaces = true }) { channel in
                    homePath.append(channel)
                }
                .navigationDestination(for: Channel.self) { channel in
                    MessageView(channel: channel)
                        .background(Theme.bg)
                }
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(Tab.home)

            NavigationStack(path: $dmsPath) {
                DMsTab { channel in
                    dmsPath.append(channel)
                }
                .navigationDestination(for: Channel.self) { channel in
                    MessageView(channel: channel)
                        .background(Theme.bg)
                }
            }
            .tabItem { Label("DMs", systemImage: "bubble.left") }
            .badge(unreadDMCount)
            .tag(Tab.dms)

            NavigationStack {
                ActivityTab()
            }
            .tabItem { Label("Activity", systemImage: "bell") }
            .badge(mentionTotal)
            .tag(Tab.activity)

            NavigationStack(path: $searchPath) {
                SearchTab { channel in
                    searchPath.append(channel)
                }
                .navigationDestination(for: Channel.self) { channel in
                    MessageView(channel: channel)
                        .background(Theme.bg)
                }
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(Tab.search)

            NavigationStack {
                YouTab()
            }
            .tabItem { Label("You", systemImage: "person") }
            .tag(Tab.you)
        }
    }
}
