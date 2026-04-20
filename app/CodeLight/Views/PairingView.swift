import SwiftUI
import AVFoundation
import VisionKit
import CodeLightProtocol

/// Pair with a Mac MioIsland — supports BOTH QR scanning and manual short-code entry.
///
/// Both paths converge on `appState.pairWithCode(...)`. The QR scanner reads the
/// `{server, code}` payload that the Mac displays; the manual entry tab takes a
/// server URL + 6-char code from the user.
struct PairingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Tab = .qr
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showScanner = false

    // Manual entry state
    @State private var manualUrl: String = AppState.shared.lastUsedServerUrl ?? "https://code.7ove.online"
    @State private var manualCode: String = ""

    private var isScannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    /// All unique server URLs the user has paired with before — shown as quick-pick
    /// buttons above the URL field. Empty on first launch.
    private var recentServerUrls: [String] {
        appState.knownServerUrls
    }

    private enum Tab: Hashable { case qr, code }

    var body: some View {
        VStack(spacing: 0) {
            // Tab segmented control
            Picker("", selection: $selectedTab) {
                Text(String(localized: "scan_qr")).tag(Tab.qr)
                Text(String(localized: "enter_code")).tag(Tab.code)
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: selectedTab) { _, _ in Haptics.selection() }

            // Tab content
            Group {
                switch selectedTab {
                case .qr:    qrTab
                case .code:  codeTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status row
            if isProcessing {
                ProgressView(String(localized: "pairing"))
                    .padding()
            } else if let successMessage {
                Text(successMessage)
                    .foregroundStyle(.green)
                    .font(.callout)
                    .padding()
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .navigationTitle(String(localized: "pair_a_mac"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { code in
                    showScanner = false
                    Task { await handleQRPayload(code) }
                }
                .navigationTitle(String(localized: "scan_qr_code"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "cancel")) { showScanner = false }
                    }
                }
            }
        }
    }

    // MARK: - QR Tab

    private var qrTab: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(Theme.brand)

            VStack(spacing: 6) {
                Text(String(localized: "scan_qr_on_mac"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(String(localized: "scan_qr_instruction"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

            Button {
                if isScannerAvailable {
                    showScanner = true
                } else {
                    errorMessage = String(localized: "camera_not_available")
                }
            } label: {
                Label(String(localized: "scan_qr_code"), systemImage: "camera.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Theme.onBrand)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Manual Code Tab

    private var codeTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 8)

                Image(systemName: "number.square.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.brand)

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "server_url"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // If the user has paired before, show their previous server URLs
                    // as quick-pick buttons above the char pills.
                    if !recentServerUrls.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(recentServerUrls, id: \.self) { url in
                                    recentServerPill(url)
                                }
                            }
                        }
                    }

                    // Quick-input character pills for building a URL from scratch
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            quickPill("https://", prepend: true)
                            quickPill("http://", prepend: true)
                            quickPill(".com")
                            quickPill(".chat")
                            quickPill(".cn")
                            quickPill(":3006")
                        }
                    }

                    TextField("https://code.7ove.online", text: $manualUrl)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "pairing_code"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("X7K2M9", text: $manualCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.center)
                        .onChange(of: manualCode) { _, new in
                            // Cap at 6 chars and uppercase
                            let cleaned = new.uppercased().filter { $0.isLetter || $0.isNumber }
                            if cleaned != new { manualCode = String(cleaned.prefix(6)) }
                            else if cleaned.count > 6 { manualCode = String(cleaned.prefix(6)) }
                        }
                }
                .padding(.horizontal, 24)

                Button {
                    Task { await pairManually() }
                } label: {
                    Text(String(localized: "pair"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Theme.brand, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(Theme.onBrand)
                }
                .padding(.horizontal, 24)
                .disabled(manualCode.count < 4 || isProcessing)
                .opacity((manualCode.count < 4 || isProcessing) ? 0.5 : 1)

                Spacer()
            }
        }
    }

    private func quickPill(_ text: String, prepend: Bool = false) -> some View {
        Button {
            Haptics.light()
            insertIntoUrl(text, prepend: prepend)
        } label: {
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    /// Tap to fill the manual URL with a previously-used server URL.
    private func recentServerPill(_ url: String) -> some View {
        Button {
            Haptics.selection()
            manualUrl = url
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                Text(URL(string: url)?.host ?? url)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.brandSoft, in: Capsule())
            .foregroundStyle(Theme.brand)
        }
        .buttonStyle(.plain)
    }

    private func insertIntoUrl(_ text: String, prepend: Bool) {
        if prepend {
            // Strip any existing scheme
            var stripped = manualUrl
            if let r = stripped.range(of: "://") {
                stripped = String(stripped[r.upperBound...])
            }
            manualUrl = text + stripped
        } else {
            manualUrl += text
        }
    }

    // MARK: - Actions

    private func handleQRPayload(_ code: String) async {
        guard let data = code.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PairingQRPayload.self, from: data) else {
            errorMessage = String(localized: "invalid_qr_code")
            Haptics.error()
            return
        }

        guard payload.isModern, let server = payload.server, let pairCode = payload.code else {
            errorMessage = String(localized: "qr_outdated_codeisland")
            Haptics.error()
            return
        }

        Haptics.rigid()
        isProcessing = true
        errorMessage = nil
        successMessage = nil

        do {
            let mac = try await appState.pairWithCode(pairCode, onServer: server)
            successMessage = String(format: NSLocalizedString("paired_with_format", comment: ""), mac.name)
            Haptics.success()
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }

        isProcessing = false
    }

    private func pairManually() async {
        let urlToUse = sanitizedManualUrl()
        guard !urlToUse.isEmpty else {
            errorMessage = String(localized: "server_url_required")
            Haptics.error()
            return
        }
        guard !manualCode.isEmpty else {
            errorMessage = String(localized: "pairing_code_required")
            Haptics.error()
            return
        }

        Haptics.rigid()
        isProcessing = true
        errorMessage = nil
        successMessage = nil

        do {
            let mac = try await appState.pairWithCode(manualCode, onServer: urlToUse)
            successMessage = String(format: NSLocalizedString("paired_with_format", comment: ""), mac.name)
            manualCode = ""
            Haptics.success()
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }

        isProcessing = false
    }

    private func sanitizedManualUrl() -> String {
        let trimmed = manualUrl.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        return "https://" + trimmed
    }
}
