import SwiftUI

/// Sessions belonging to a single paired Mac. Shown after the user picks a Mac
/// from `LinkedMacsListView`. Filters `appState.sessions` by `ownerDeviceId`.
struct MacSessionListView: View {
    @EnvironmentObject var appState: AppState
    let mac: LinkedMac
    @State private var isLoading = true
    @State private var showLaunchSheet = false

    private var macSessions: [SessionInfo] {
        appState.sessions.filter { $0.ownerDeviceId == mac.deviceId }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                } else if macSessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
        }
        .navigationTitle(mac.name)
        .navigationDestination(for: String.self) { sessionId in
            ChatView(sessionId: sessionId)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Button {
                        Task { await refreshSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button {
                        showLaunchSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
        }
        .sheet(isPresented: $showLaunchSheet) {
            NavigationStack {
                LaunchSessionSheet(mac: mac)
            }
        }
        .task {
            // Make sure we're connected to this Mac's server before fetching sessions.
            if mac.serverUrl != appState.currentServerUrl || !appState.isConnected {
                await appState.switchServerIfNeeded(to: mac.serverUrl)
            }
            if let socket = appState.socket {
                do {
                    appState.sessions = try await socket.fetchSessions()
                } catch {
                    print("[MacSessionList] Fetch error: \(error)")
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

                Text(String(localized: "tap_plus_to_launch"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                showLaunchSheet = true
            } label: {
                Label(String(localized: "launch_session"), systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Theme.brand, in: Capsule())
                    .foregroundStyle(Theme.onBrand)
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding()
    }

    // MARK: - Session List

    private var sessionList: some View {
        List {
            let active = macSessions.filter(\.active)
            if !active.isEmpty {
                Section {
                    ForEach(active) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.brand)
                            .frame(width: 6, height: 6)
                        Text(String(localized: "active"))
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(active.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.brandSoft, in: Capsule())
                            .foregroundStyle(Theme.brand)
                    }
                }
            }

            let inactive = macSessions.filter { !$0.active }
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bgPrimary)
        .refreshable {
            await refreshSessions()
        }
    }

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

private struct SessionRow: View {
    @EnvironmentObject var appState: AppState
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if session.active {
                    Circle()
                        .fill(Theme.brand.opacity(0.25))
                        .frame(width: 18, height: 18)
                }
                Circle()
                    .fill(session.active ? Theme.brand : Theme.textTertiary)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.metadata?.displayProjectName ?? session.tag)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                if let title = session.metadata?.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                if let path = session.metadata?.path {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 8))
                        Text(shortenPath(path))
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let model = session.metadata?.model {
                    Text(model.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.brandSoft, in: Capsule())
                        .overlay(Capsule().stroke(Theme.borderActive, lineWidth: 0.5))
                        .foregroundStyle(Theme.brand)
                }

                if let lastTime = appState.lastMessageTimeBySession[session.id] {
                    Text(lastTime, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Theme.bgPrimary)
        .listRowSeparatorTint(Theme.divider)
    }
}
