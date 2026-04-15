import SwiftUI
import StoreKit
import CodeLightCrypto

/// Paywall / trial-expiry screen. Three entry points:
/// - `.trialExpired` — automatic, trial ended
/// - `.sessionBlocked` — server sent `subscription-required`
/// - `.voluntary` — user tapped "Upgrade" in Settings
///
/// Always dismissible (swipe or button). Closing without purchase
/// leaves the app in a degraded state — server refuses socket connections
/// until the user subscribes.
struct SubscriptionView: View {
    let reason: AppState.SubscriptionReason

    @EnvironmentObject var appState: AppState
    @ObservedObject var storeManager = StoreManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isRestoring = false
    @State private var restoreError: String?
    @State private var showRedeemInput = false
    @State private var redeemCode = ""
    @State private var isRedeeming = false
    @State private var redeemError: String?

    private var headline: String {
        switch reason {
        case .trialExpired:
            return String(localized: "sub_trial_ended_title")
        case .sessionBlocked:
            return String(localized: "sub_subscription_required_title")
        case .voluntary:
            return String(localized: "sub_unlock_title")
        }
    }

    private var subtitle: String {
        switch reason {
        case .trialExpired:
            return String(localized: "sub_trial_ended_subtitle")
        case .sessionBlocked:
            return String(localized: "sub_subscription_required_subtitle")
        case .voluntary:
            return String(localized: "sub_unlock_subtitle")
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        Spacer().frame(height: 20)

                        // Already purchased — show success state
                        if storeManager.isPurchased && storeManager.purchaseState != .success {
                            alreadyPurchasedView
                        } else {
                            // App icon
                            appIcon

                            // Headline + subtitle
                            VStack(spacing: 8) {
                                Text(headline)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(Theme.textPrimary)
                                    .multilineTextAlignment(.center)

                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 32)

                            // Feature list
                            featureList

                            // Price
                            priceDisplay

                            // Purchase button
                            purchaseButton

                            // Error messages
                            errorArea

                            // Redeem code input (shown when tapped)
                            if showRedeemInput {
                                redeemInputField
                            }

                            // Footer (restore + redeem + privacy + terms)
                            footerLinks
                        }

                        Spacer().frame(height: 40)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .interactiveDismissDisabled(
                storeManager.purchaseState == .purchasing
                || storeManager.purchaseState == .verifying
            )
        }
        .preferredColorScheme(.dark)
        .onChange(of: appState.subscriptionStatus) { _, newStatus in
            // Auto-dismiss when server confirms subscription (e.g. via subscription-updated event)
            if newStatus == "active" {
                Haptics.success()
                appState.isSubscriptionBlocked = false
                dismiss()
            }
        }
    }

    // MARK: - Already Purchased

    private var alreadyPurchasedView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 40)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.brand)

            Text(String(localized: "sub_already_purchased_title"))
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)

            Text(String(localized: "sub_already_purchased_subtitle"))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                dismiss()
            } label: {
                Text(String(localized: "done"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Theme.onBrand)
            }
            .padding(.horizontal, 40)
        }
    }

    // MARK: - App Icon

    private var appIcon: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 32))
            .foregroundStyle(.black)
            .frame(width: 64, height: 64)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Feature List

    private var featureList: some View {
        VStack(spacing: 0) {
            featureRow("bolt.fill",
                        String(localized: "sub_feat_sessions_title"),
                        String(localized: "sub_feat_sessions_desc"))
            featureRow("arrow.triangle.2.circlepath",
                        String(localized: "sub_feat_sync_title"),
                        String(localized: "sub_feat_sync_desc"))
            featureRow("desktopcomputer",
                        String(localized: "sub_feat_mac_title"),
                        String(localized: "sub_feat_mac_desc"))
            featureRow("sparkles",
                        String(localized: "sub_feat_island_title"),
                        String(localized: "sub_feat_island_desc"))
        }
        .padding(.vertical, 8)
        .brandSurface(corner: 16)
        .padding(.horizontal, 24)
    }

    private func featureRow(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(Theme.brand)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Price

    private var priceDisplay: some View {
        VStack(spacing: 4) {
            if let product = storeManager.product {
                Text(product.displayPrice)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.brand)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(String(localized: "sub_one_time_forever"))
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Purchase Button

    private var purchaseButton: some View {
        Button {
            Task { await handlePurchase() }
        } label: {
            Group {
                switch storeManager.purchaseState {
                case .purchasing, .verifying:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.onBrand)
                        Text(storeManager.purchaseState == .verifying
                             ? String(localized: "sub_verifying")
                             : String(localized: "sub_purchasing"))
                            .font(.headline)
                    }
                case .success:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(String(localized: "sub_success"))
                            .font(.headline)
                    }
                case .pendingServerVerify:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.onBrand)
                        Text(String(localized: "sub_pending_server"))
                            .font(.headline)
                    }
                default:
                    Text(String(localized: "sub_unlock_button"))
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                storeManager.purchaseState == .success ? Theme.success : Theme.brand,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .foregroundStyle(Theme.onBrand)
        }
        .padding(.horizontal, 40)
        .disabled(storeManager.product == nil
                  || storeManager.purchaseState == .purchasing
                  || storeManager.purchaseState == .verifying
                  || storeManager.purchaseState == .success
                  || storeManager.purchaseState == .pendingServerVerify)
        .opacity(storeManager.product == nil ? 0.5 : 1)
    }

    // MARK: - Restore

    private var restoreButton: some View {
        Button {
            Task { await handleRestore() }
        } label: {
            if isRestoring {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(String(localized: "sub_restore_purchase"))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .disabled(isRestoring)
    }

    // MARK: - Error Area

    @ViewBuilder
    private var errorArea: some View {
        if case .error(let message) = storeManager.purchaseState {
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }

        if let restoreError {
            Text(restoreError)
                .font(.callout)
                .foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Footer

    private var footerLinks: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                Button {
                    Task { await handleRestore() }
                } label: {
                    Text(String(localized: "sub_restore_purchase").uppercased())
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .disabled(isRestoring)

                redeemInlineButton
            }

            HStack(spacing: 16) {
                Link(String(localized: "privacy_policy").uppercased(),
                     destination: URL(string: "https://github.com/MioMioOS/CodeLight/blob/main/PRIVACY.md")!)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)

                Link(String(localized: "sub_terms").uppercased(),
                     destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var redeemInlineButton: some View {
        Button {
            withAnimation { showRedeemInput = true }
        } label: {
            Text(String(localized: "redeem_code_button").uppercased())
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Redeem Code Input

    private var redeemInputField: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField(String(localized: "redeem_placeholder"), text: $redeemCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.subheadline, design: .monospaced))

                Button {
                    Task { await handleRedeem() }
                } label: {
                    if isRedeeming {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(String(localized: "redeem_submit"))
                            .font(.subheadline.bold())
                            .foregroundStyle(Theme.brand)
                    }
                }
                .disabled(redeemCode.trimmingCharacters(in: .whitespaces).isEmpty || isRedeeming)
            }
            .padding(.horizontal, 24)

            if let redeemError {
                Text(redeemError)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    // MARK: - Actions

    private func handleRedeem() async {
        Haptics.medium()
        isRedeeming = true
        redeemError = nil

        guard let serverUrl = appState.currentServerUrl ?? appState.lastUsedServerUrl else {
            redeemError = String(localized: "redeem_no_server")
            isRedeeming = false
            return
        }

        let keyManager = KeyManager(serviceName: "com.codelight.app")
        guard let token = keyManager.loadToken(forServer: serverUrl) else {
            redeemError = String(localized: "redeem_no_auth")
            isRedeeming = false
            return
        }

        let trimmed = redeemCode.trimmingCharacters(in: .whitespaces).uppercased()

        do {
            var request = URLRequest(url: URL(string: "\(serverUrl)/v1/subscription/redeem")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["code": trimmed])
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let success = json["success"] as? Bool, success {
                    Haptics.success()
                    appState.isSubscriptionBlocked = false
                    appState.subscriptionStatus = "active"
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    dismiss()
                    return
                }
            }

            // Error response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                switch error {
                case "invalid_code":
                    redeemError = String(localized: "redeem_invalid")
                case "code_expired":
                    redeemError = String(localized: "redeem_expired")
                case "code_exhausted":
                    redeemError = String(localized: "redeem_exhausted")
                case "already_redeemed":
                    redeemError = String(localized: "redeem_already_used")
                default:
                    redeemError = String(localized: "redeem_failed")
                }
            } else {
                redeemError = String(localized: "redeem_failed")
            }
        } catch {
            redeemError = String(localized: "redeem_network_error")
        }

        Haptics.error()
        isRedeeming = false
    }

    private func handlePurchase() async {
        Haptics.medium()
        do {
            let tx = try await storeManager.purchase()
            guard tx != nil else { return }

            if storeManager.purchaseState == .success {
                // Server confirmed — all good, dismiss.
                Haptics.success()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                appState.isSubscriptionBlocked = false
                dismiss()
            } else if storeManager.purchaseState == .pendingServerVerify {
                // StoreKit purchase succeeded but server verify failed/pending.
                // Keep the paywall open and show a "purchased, connecting..." state.
                // The paywall will auto-dismiss when subscription-updated arrives.
                Haptics.medium()
            }
        } catch {
            Haptics.error()
        }
    }

    private func handleRestore() async {
        Haptics.medium()
        isRestoring = true
        restoreError = nil
        do {
            try await storeManager.restorePurchase()
            if storeManager.isPurchased {
                Haptics.success()
                appState.isSubscriptionBlocked = false
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            } else {
                restoreError = String(localized: "sub_restore_no_purchase")
                Haptics.error()
            }
        } catch {
            restoreError = error.localizedDescription
            Haptics.error()
        }
        isRestoring = false
    }
}
