import Foundation

/// Auth challenge request for public key authentication.
public struct AuthRequest: Codable, Sendable {
    public let publicKey: String   // base64
    public let challenge: String   // base64
    public let signature: String   // base64

    public init(publicKey: String, challenge: String, signature: String) {
        self.publicKey = publicKey
        self.challenge = challenge
        self.signature = signature
    }
}

/// Auth response from server.
public struct AuthResponse: Codable, Sendable {
    public let success: Bool
    public let token: String?
    public let deviceId: String?
}

/// QR code pairing payload (encoded in QR).
///
/// **Current format (post-multi-mac-pairing):** `{server, code}` — Mac displays
/// its permanent shortCode in QR, iPhone redeems via POST /v1/pairing/code/redeem.
///
/// **Legacy format:** `{s, k, n}` — kept as optional fields for migration only.
/// New Mac builds always emit the new format. iPhone shows a friendly error
/// when it sees a legacy QR (no `code` field).
public struct PairingQRPayload: Codable, Sendable {
    public let server: String?
    public let code: String?

    // Legacy fields — present in old QR codes from CodeIsland < multi-mac-pairing.
    public let s: String?
    public let k: String?
    public let n: String?

    public init(server: String, code: String) {
        self.server = server
        self.code = code
        self.s = nil
        self.k = nil
        self.n = nil
    }

    /// True if this QR is in the modern `{server, code}` format and has both fields populated.
    public var isModern: Bool {
        guard let server, !server.isEmpty, let code, !code.isEmpty else { return false }
        return true
    }
}

/// A device linked to the caller via DeviceLink. Returned from GET /v1/pairing/links.
public struct LinkedDevice: Codable, Sendable, Identifiable, Hashable {
    public let deviceId: String
    public let name: String
    public let kind: String      // "ios" | "mac"
    public let createdAt: String // ISO8601

    public init(deviceId: String, name: String, kind: String, createdAt: String) {
        self.deviceId = deviceId
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
    }

    public var id: String { deviceId }
}

/// A launch preset for remote-launching a session on a paired Mac.
public struct LaunchPresetDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let command: String
    public let icon: String?
    public let sortOrder: Int

    public init(id: String, name: String, command: String, icon: String?, sortOrder: Int) {
        self.id = id
        self.name = name
        self.command = command
        self.icon = icon
        self.sortOrder = sortOrder
    }
}

/// A known project path on a paired Mac.
public struct KnownProjectDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let path: String
    public let name: String
    public let lastSeenAt: String

    public init(id: String, path: String, name: String, lastSeenAt: String) {
        self.id = id
        self.path = path
        self.name = name
        self.lastSeenAt = lastSeenAt
    }
}

/// Session metadata (sent as encrypted blob from the Mac).
/// NOTE: For owner device info, see the wrapper `SessionInfo`/`ownerDeviceId` —
/// server-side join, not part of the encrypted blob.
public struct SessionMetadata: Codable, Sendable {
    public let path: String?         // working directory
    public let title: String?        // session title (conversation summary)
    public let projectName: String?  // project folder name (cwd basename, sent by Mac CodeIsland)
    public let model: String?        // Claude model
    public let mode: String?         // permission mode

    public init(
        path: String? = nil,
        title: String? = nil,
        projectName: String? = nil,
        model: String? = nil,
        mode: String? = nil
    ) {
        self.path = path
        self.title = title
        self.projectName = projectName
        self.model = model
        self.mode = mode
    }

    /// Project name for display: prefer the explicit `projectName`, fall back to
    /// the basename of `path`, and finally to `title`.
    public var displayProjectName: String {
        if let p = projectName, !p.isEmpty { return p }
        if let path = path, !path.isEmpty {
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        if let t = title, !t.isEmpty { return t }
        return "Session"
    }
}
