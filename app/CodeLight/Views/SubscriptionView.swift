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

                            // Footer (restore + privacy + terms)
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
                  || storeManager.purchaseState == .success)
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
        VStack(spacing: 12) {
            // Restore — prominent standalone row (Apple Guideline 3.1.1)
            Button {
                Task { await handleRestore() }
            } label: {
                Group {
                    if isRestoring {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(Theme.textSecondary)
                            Text(String(localized: "sub_restore_purchase"))
                        }
                    } else {
                        Text(String(localized: "sub_restore_purchase"))
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            }
            .disabled(isRestoring)

            // Legal links
            HStack(spacing: 16) {
                if let privacyURL = URL(string: "https://code.7ove.online/privacy") {
                    Link(String(localized: "privacy_policy").uppercased(),
                         destination: privacyURL)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                }

                if let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
                    Link(String(localized: "sub_terms").uppercased(),
                         destination: termsURL)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: - Actions

    private func handlePurchase() async {
        Haptics.medium()
        do {
            let tx = try await storeManager.purchase()
            guard tx != nil else { return }

            // StoreManager grants local entitlement synchronously on Apple-verified
            // purchase, then runs server sync in the background. Either of these
            // signals the user is paid and the paywall should close.
            if storeManager.purchaseState == .success || storeManager.isPurchased {
                Haptics.success()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                appState.isSubscriptionBlocked = false
                dismiss()
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
