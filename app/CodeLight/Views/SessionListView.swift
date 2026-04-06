import SwiftUI

/// List of sessions for a given server.
struct SessionListView: View {
    @EnvironmentObject var appState: AppState
    let server: ServerConfig
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            // Connection status banner
            ConnectionStatusBar()

            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(String(localized: "loading_sessions"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appState.sessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
        }
        .navigationTitle(server.name)
        .navigationDestination(for: String.self) { sessionId in
            ChatView(sessionId: sessionId)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    // Refresh
                    Button {
                        Task { await refreshSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    // Settings
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .task {
            if let socket = appState.socket {
                do {
                    appState.sessions = try await socket.fetchSessions()
                } catch {
                    print("[SessionList] Fetch error: \(error)")
                }
            }
            isLoading = false
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.5))

            VStack(spacing: 8) {
                Text(String(localized: "no_sessions_yet"))
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(String(localized: "no_sessions_instruction"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(.blue)
                    Text(String(localized: "step_install_codeisland"))
                        .font(.caption)
                }

                HStack(spacing: 8) {
                    Image(systemName: "2.circle.fill")
                        .foregroundStyle(.blue)
                    Text(String(localized: "step_start_session"))
                        .font(.caption)
                }

                HStack(spacing: 8) {
                    Image(systemName: "3.circle.fill")
                        .foregroundStyle(.blue)
                    Text(String(localized: "step_sessions_appear"))
                        .font(.caption)
                }
            }
            .padding()
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))

            Button {
                Task { await refreshSessions() }
            } label: {
                Label(String(localized: "refresh"), systemImage: "arrow.clockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
    }

    // MARK: - Session List

    private var sessionList: some View {
        List {
            // Active sessions
            let active = appState.sessions.filter(\.active)
            if !active.isEmpty {
                Section {
                    ForEach(active) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session)
                        }
                    }
                } header: {
                    HStack {
                        Text(String(localized: "active"))
                        Spacer()
                        Text("\(active.count)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
            }

            // Inactive sessions
            let inactive = appState.sessions.filter { !$0.active }
            if !inactive.isEmpty {
                Section(String(localized: "recent")) {
                    ForEach(inactive) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session)
                        }
                    }
                }
            }
        }
        .refreshable {
            await refreshSessions()
        }
    }

    // MARK: - Helpers

    private func refreshSessions() async {
        if let socket = appState.socket {
            appState.sessions = (try? await socket.fetchSessions()) ?? []
        }
    }
}

/// Shorten a path by replacing home directory with ~
private func shortenPath(_ path: String) -> String {
    var p = path
    if let home = ProcessInfo.processInfo.environment["HOME"], p.hasPrefix(home) {
        p = "~" + p.dropFirst(home.count)
    }
    return p
}

/// A single session row.
private struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            VStack {
                Circle()
                    .fill(session.active ? .green : .gray.opacity(0.4))
                    .frame(width: 10, height: 10)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.metadata?.title ?? session.tag)
                    .font(.headline)
                    .lineLimit(1)

                if let path = session.metadata?.path {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(shortenPath(path))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let model = session.metadata?.model {
                    Text(model.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }

                Text(session.lastActiveAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
