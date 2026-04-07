import SwiftUI

/// Shows connection status at the top of session list.
struct ConnectionStatusBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if !appState.isConnected {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(Theme.warning)
                Text(String(localized: "reconnecting"))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(String(localized: "retry")) {
                    Task { await appState.connect() }
                }
                .font(.caption)
                .foregroundStyle(Theme.brand)
                .buttonStyle(.bordered)
                .tint(Theme.brand)
                .controlSize(.mini)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.warning.opacity(0.10))
            .overlay(
                Rectangle()
                    .fill(Theme.warning.opacity(0.4))
                    .frame(height: 0.5),
                alignment: .bottom
            )
        }
    }
}
