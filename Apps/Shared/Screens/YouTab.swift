import SwiftUI
import FluxerKit

struct YouTab: View {
    @Environment(AppSession.self) private var session

    @State private var showSessions = false

    /// CFBundleVersion, stamped with the build time by the deploy command
    /// so a glance at this footer answers "which build is this phone on".
    static let buildStamp = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

    /// When the running binary was compiled, straight from the executable
    /// file's timestamp, so it works even without the stamped version.
    static let buildDate: String = {
        guard let url = Bundle.main.executableURL,
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate)
        else { return "unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }()

    private let statuses: [(String, String, Color)] = [
        ("online", "Active", Theme.green),
        ("idle", "Away", Color(hex: 0xFAA61A)),
        ("dnd", "Do not disturb", Theme.red),
        ("invisible", "Invisible", Theme.faint),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    AvatarView(user: session.currentUser, diameter: 66)
                        .overlay(alignment: .bottomTrailing) {
                            PresenceDot(status: session.myStatus == "invisible" ? nil : session.myStatus)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.currentUser?.displayName ?? "")
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(Theme.text)
                        Text(session.currentUser?.username ?? "")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                SectionLabel(text: "Set yourself as")
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(Array(statuses.enumerated()), id: \.offset) { index, status in
                        Button {
                            Task { await session.setStatus(status.0) }
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(status.2)
                                    .frame(width: 12, height: 12)
                                    .shadow(color: status.2.opacity(0.35), radius: 4)
                                Text(status.1)
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                if session.myStatus == status.0 {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.vertical, 13)
                            .padding(.horizontal, 15)
                        }
                        .buttonStyle(.plain)
                        if index < statuses.count - 1 {
                            Theme.hairline.frame(height: 1).padding(.leading, 39)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)
                .padding(.bottom, 22)

                VStack(spacing: 0) {
                    settingsRow(icon: "laptopcomputer.and.iphone", tint: Theme.accent, label: "Sessions") {
                        showSessions = true
                    }
                    Theme.hairline.frame(height: 1).padding(.leading, 55)
                    settingsRow(icon: "server.rack", tint: Color(hex: 0x8B5CF6),
                                label: "Instance",
                                detail: session.instanceConfig.apiBase.host() ?? "") {}
                    Theme.hairline.frame(height: 1).padding(.leading, 55)
                    settingsRow(icon: "rectangle.portrait.and.arrow.right", tint: Theme.red, label: "Log out") {
                        Task { await session.logout() }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)

                VStack(spacing: 3) {
                    Text("CornFlux for iOS and macOS")
                    Text("build \(Self.buildStamp) · compiled \(Self.buildDate)")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            }
        }
        .background(Theme.bg)
        .navigationTitle("You")
        .sheet(isPresented: $showSessions) {
            SessionsView()
                .preferredColorScheme(.dark)
        }
    }

    private func settingsRow(
        icon: String,
        tint: Color,
        label: String,
        detail: String = "",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                Text(label)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                Spacer()
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 15)
        }
        .buttonStyle(.plain)
    }
}
