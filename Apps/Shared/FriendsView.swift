import SwiftUI
import FluxerKit

struct FriendsView: View {
    @Environment(AppSession.self) private var session

    enum Section: String, CaseIterable {
        case friends = "Friends"
        case pending = "Pending"
        case blocked = "Blocked"
    }

    @State private var section: Section = .friends
    @State private var addUsername = ""
    @State private var addResult: String?

    var body: some View {
        List {
            SwiftUI.Section {
                Picker("Show", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            if section == .friends {
                SwiftUI.Section("Add a friend") {
                    HStack {
                        TextField("username or username#0000", text: $addUsername)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        Button("Send") {
                            let name = addUsername
                            addUsername = ""
                            Task {
                                addResult = await session.sendFriendRequest(username: name)
                                    ? "Request sent."
                                    : nil
                            }
                        }
                        .disabled(addUsername.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let addResult {
                        Text(addResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SwiftUI.Section {
                ForEach(rows) { relationship in
                    row(relationship)
                }
                if rows.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Friends")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var rows: [Relationship] {
        switch section {
        case .friends: return session.friends
        case .pending: return session.pendingRequests
        case .blocked: return session.blockedUsers
        }
    }

    private var emptyText: String {
        switch section {
        case .friends: return "No friends yet. Add one above."
        case .pending: return "No pending requests."
        case .blocked: return "Nobody is blocked."
        }
    }

    private func row(_ relationship: Relationship) -> some View {
        HStack(spacing: 10) {
            AvatarView(user: relationship.user ?? session.knownUsers[relationship.id], diameter: 32)
                .overlay(alignment: .bottomTrailing) {
                    if relationship.type == .friend {
                        PresenceDot(status: session.presenceStatus(for: relationship.id))
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName(for: relationship))
                if relationship.type == .incomingRequest {
                    Text("Incoming request")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if relationship.type == .outgoingRequest {
                    Text("Request sent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if relationship.type == .incomingRequest {
                Button("Accept") {
                    Task { await session.acceptRequest(relationship) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            if relationship.type == .friend {
                Button {
                    Task {
                        if let dm = await session.openDM(with: relationship.id) {
                            session.channelJump = dm
                        }
                    }
                } label: {
                    Image(systemName: "bubble.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .contextMenu {
            switch relationship.type {
            case .friend:
                Button("Remove friend", systemImage: "person.badge.minus", role: .destructive) {
                    Task { await session.removeRelationship(relationship) }
                }
            case .incomingRequest:
                Button("Ignore request", systemImage: "xmark") {
                    Task { await session.removeRelationship(relationship) }
                }
            case .outgoingRequest:
                Button("Cancel request", systemImage: "xmark") {
                    Task { await session.removeRelationship(relationship) }
                }
            case .blocked:
                Button("Unblock", systemImage: "hand.raised.slash") {
                    Task { await session.removeRelationship(relationship) }
                }
            case .unknown:
                EmptyView()
            }
        }
    }
}
