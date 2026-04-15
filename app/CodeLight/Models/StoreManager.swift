import Foundation
import StoreKit
import CodeLightCrypto

/// Manages StoreKit 2 in-app purchases for the CodeLight lifetime unlock.
///
/// Key design decisions:
/// - `isPurchased` tracks LOCAL StoreKit entitlement only. Server enforces its own gate.
/// - Transaction listener lives forever (never cancelled). Events arriving in background
///   are handled on next wake.
/// - `verifyWithServer` is self-contained (own URLRequest), decoupled from SocketClient.
/// - Pending verify survives app kill via UserDefaults, retried on every socket reconnect.
@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    static let productID = "com.codelight.app.lifetime"

    @Published var product: Product?
    @Published var isPurchased: Bool = false
    @Published var purchaseState: PurchaseState = .idle
    /// True when StoreKit confirms purchase but server verify hasn't succeeded yet.
    /// UI can show "purchased, connecting to server..." state.
    @Published var purchasedButPendingVerify: Bool = false

    enum PurchaseState: Equatable {
        case idle
        case loading
        case purchasing
        case verifying
        case success
        case pendingServerVerify   // StoreKit OK, server not yet confirmed
        case error(String)
    }

    /// Result of the most recent verifyWithServer call.
    enum VerifyResult {
        case success
        case networkError
        case authExpired   // 401 — token needs refresh
        case serverError
    }

    private var transactionListener: Task<Void, Never>?
    private let pendingVerifyKey = "pendingOriginalTransactionId"
    private let pendingServerUrlKey = "pendingVerifyServerUrl"
    private let keyManager = KeyManager(serviceName: "com.codelight.app")

    /// Throttle: earliest time retryPendingVerify may fire again.
    private var nextRetryAllowedAt: Date = .distantPast

    private init() {}

    // MARK: - Lifecycle

    /// Call once from CodeLightApp.task. Loads product, checks entitlement,
    /// starts the transaction listener that lives until process death.
    func start() {
        Task {
            await loadProduct()
            await checkEntitlement()
            listenForTransactions()
        }
    }

    // MARK: - Product Loading

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            self.product = products.first
        } catch {
            print("[StoreManager] Failed to load products: \(error)")
        }
    }

    // MARK: - Entitlement Check

    /// Check local StoreKit entitlement. Does NOT hit the server.
    func checkEntitlement() async {
        guard let result = await Transaction.currentEntitlement(for: Self.productID) else {
            isPurchased = false
            return
        }
        switch result {
        case .verified(let tx):
            if tx.revocationDate != nil {
                isPurchased = false
            } else {
                isPurchased = true
            }
        case .unverified:
            isPurchased = false
        }
    }

    // MARK: - Purchase

    /// Purchase the lifetime product. Returns the verified transaction on success.
    @discardableResult
    func purchase() async throws -> Transaction? {
        guard let product else {
            purchaseState = .error(String(localized: "store_product_unavailable"))
            return nil
        }

        purchaseState = .purchasing

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            purchaseState = .error(error.localizedDescription)
            return nil
        }

        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let tx):
                purchaseState = .verifying
                purchasedButPendingVerify = true

                // Persist for retry in case server is unreachable.
                // Record the server URL at purchase time so retries go to the right server.
                savePendingVerify(originalTransactionId: tx.originalID)
                let verifyResult = await verifyWithServer(originalTransactionId: tx.originalID)

                await tx.finish()

                switch verifyResult {
                case .success:
                    isPurchased = true
                    purchasedButPendingVerify = false
                    purchaseState = .success
                case .authExpired:
                    // Token expired — tell AppState to re-authenticate.
                    purchasedButPendingVerify = true
                    purchaseState = .pendingServerVerify
                    AppState.shared.needsReauthentication = true
                case .networkError, .serverError:
                    // Purchase is real (StoreKit confirmed), but server doesn't know yet.
                    // Will retry on next reconnect.
                    purchasedButPendingVerify = true
                    purchaseState = .pendingServerVerify
                }
                return tx

            case .unverified(_, let error):
                purchaseState = .error(String(localized: "store_verification_failed"))
                print("[StoreManager] Unverified transaction: \(error)")
                return nil
            }

        case .pending:
            // Ask to Buy or other deferred flow
            purchaseState = .idle
            return nil

        case .userCancelled:
            purchaseState = .idle
            return nil

        @unknown default:
            purchaseState = .idle
            return nil
        }
    }

    // MARK: - Restore

    /// Restore purchases (triggers App Store sync + re-checks entitlement).
    func restorePurchase() async throws {
        try await AppStore.sync()
        await checkEntitlement()

        // If restored, also verify with server
        if isPurchased {
            if let result = await Transaction.currentEntitlement(for: Self.productID),
               case .verified(let tx) = result {
                savePendingVerify(originalTransactionId: tx.originalID)
                await verifyWithServer(originalTransactionId: tx.originalID)
            }
        }
    }

    // MARK: - Transaction Listener

    /// Listens for transaction updates for the entire app lifetime.
    /// Catches: Ask-to-Buy completions, Family Sharing grants, refunds.
    private func listenForTransactions() {
        guard transactionListener == nil else { return }

        transactionListener = Task { @MainActor [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                switch result {
                case .verified(let tx):
                    if tx.revocationDate != nil {
                        // Refund: revoke access
                        self.isPurchased = false
                        self.purchasedButPendingVerify = false
                    } else {
                        self.purchasedButPendingVerify = true
                        self.savePendingVerify(originalTransactionId: tx.originalID)
                        let verifyResult = await self.verifyWithServer(originalTransactionId: tx.originalID)
                        if verifyResult == .success {
                            self.isPurchased = true
                            self.purchasedButPendingVerify = false
                        }
                        if verifyResult == .authExpired {
                            AppState.shared.needsReauthentication = true
                        }
                    }
                    await tx.finish()
                case .unverified:
                    break
                }
            }
        }
    }

    // MARK: - Server Verification

    /// Notify the server of a successful purchase. Self-contained: builds its own
    /// URLRequest with the current server URL + auth token. Does NOT depend on
    /// AppState.socket (which can be nil during reconnect).
    ///
    /// Uses the server URL recorded at purchase time (pendingServerUrlKey) so that
    /// multi-server setups don't verify against the wrong server.
    ///
    /// `originalTransactionId` is UInt64 from StoreKit 2, sent as String because
    /// UInt64 exceeds JavaScript's Number.MAX_SAFE_INTEGER (2^53-1).
    @discardableResult
    private func verifyWithServer(originalTransactionId: UInt64) async -> VerifyResult {
        // Prefer the server URL recorded at purchase time; fall back to current/last.
        let serverUrl: String
        if let recorded = UserDefaults.standard.string(forKey: pendingServerUrlKey), !recorded.isEmpty {
            serverUrl = recorded
        } else if let current = AppState.shared.currentServerUrl ?? AppState.shared.lastUsedServerUrl {
            serverUrl = current
        } else {
            print("[StoreManager] No server URL available for verify")
            return .networkError
        }

        guard let token = keyManager.loadToken(forServer: serverUrl) else {
            print("[StoreManager] No auth token for \(serverUrl)")
            return .authExpired
        }

        let url = URL(string: "\(serverUrl)/v1/subscription/verify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let body: [String: Any] = ["originalTransactionId": "\(originalTransactionId)"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .networkError
            }

            if http.statusCode == 401 {
                print("[StoreManager] Server verify 401 — token expired, needs re-auth")
                return .authExpired
            }

            if (200...299).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success {
                clearPendingVerify()
                print("[StoreManager] Server verify success")
                return .success
            }

            print("[StoreManager] Server verify failed (\(http.statusCode)), will retry on next connect")
            return .serverError
        } catch {
            print("[StoreManager] Server verify network error: \(error.localizedDescription)")
            return .networkError
        }
    }

    // MARK: - Pending Verify Persistence

    private func savePendingVerify(originalTransactionId: UInt64) {
        UserDefaults.standard.set("\(originalTransactionId)", forKey: pendingVerifyKey)
        // Record the server URL at purchase time so retries go to the correct server.
        if let url = AppState.shared.currentServerUrl ?? AppState.shared.lastUsedServerUrl {
            UserDefaults.standard.set(url, forKey: pendingServerUrlKey)
        }
    }

    private func clearPendingVerify() {
        UserDefaults.standard.removeObject(forKey: pendingVerifyKey)
        UserDefaults.standard.removeObject(forKey: pendingServerUrlKey)
    }

    /// Called from AppState on every successful socket reconnect.
    /// Throttled: skips if called again within 60 seconds of the last attempt.
    func retryPendingVerify() async {
        guard let idString = UserDefaults.standard.string(forKey: pendingVerifyKey),
              let id = UInt64(idString) else { return }

        // Throttle: at most once per 60 seconds
        let now = Date()
        guard now >= nextRetryAllowedAt else {
            print("[StoreManager] Retry throttled, next allowed at \(nextRetryAllowedAt)")
            return
        }
        nextRetryAllowedAt = now.addingTimeInterval(60)

        print("[StoreManager] Retrying pending verify for \(idString)")
        let result = await verifyWithServer(originalTransactionId: id)
        if result == .success {
            isPurchased = true
            purchasedButPendingVerify = false
            purchaseState = .idle
        } else if result == .authExpired {
            AppState.shared.needsReauthentication = true
        }
    }
}
