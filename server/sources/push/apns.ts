import { SignJWT, importPKCS8 } from 'jose';
import http2 from 'node:http2';
import fs from 'node:fs';
import path from 'node:path';
import { config } from '@/config';

/**
 * APNs push notification sender.
 * Uses Apple's HTTP/2 APNs API with JWT authentication.
 *
 * Required env vars:
 * - APNS_KEY_ID: Key ID from Apple Developer portal
 * - APNS_TEAM_ID: Apple Developer Team ID
 * - APNS_KEY: Base64-encoded .p8 private key content
 * - APNS_BUNDLE_ID: App bundle ID (e.g., com.codelight.app)
 */

interface APNsConfig {
    keyId: string;
    teamId: string;
    privateKey: string; // base64-encoded .p8 content
    bundleId: string;
    production: boolean;
}

function getApnsConfig(): APNsConfig | null {
    const keyId = process.env.APNS_KEY_ID;
    const teamId = process.env.APNS_TEAM_ID;
    const privateKey = process.env.APNS_KEY;
    const bundleId = process.env.APNS_BUNDLE_ID || 'com.codelight.app';

    if (!keyId || !teamId || !privateKey) {
        return null;
    }

    return {
        keyId,
        teamId,
        privateKey,
        bundleId,
        // APNS_USE_SANDBOX=true for development-signed apps (Xcode runs)
        production: process.env.APNS_USE_SANDBOX !== 'true' && process.env.NODE_ENV === 'production',
    };
}

let cachedToken: { token: string; expiresAt: number } | null = null;

async function getAuthToken(apnsConfig: APNsConfig): Promise<string> {
    // Reuse token if still valid (tokens last 60 min, refresh at 50 min)
    if (cachedToken && cachedToken.expiresAt > Date.now()) {
        return cachedToken.token;
    }

    // Prefer reading the .p8 file directly (avoids base64 encoding issues
    // with OpenSSL 3.0.19+). Fall back to base64-encoded APNS_KEY env var.
    let keyData: string;
    const p8Path = path.resolve(process.cwd(), 'apns-key.p8');
    if (fs.existsSync(p8Path)) {
        keyData = fs.readFileSync(p8Path, 'utf-8');
    } else {
        keyData = Buffer.from(apnsConfig.privateKey, 'base64').toString('utf-8');
    }
    const privateKey = await importPKCS8(keyData, 'ES256');

    const token = await new SignJWT({})
        .setProtectedHeader({ alg: 'ES256', kid: apnsConfig.keyId })
        .setIssuer(apnsConfig.teamId)
        .setIssuedAt()
        .sign(privateKey);

    cachedToken = {
        token,
        expiresAt: Date.now() + 50 * 60 * 1000, // 50 minutes
    };

    return token;
}

export interface PushPayload {
    title: string;
    /// Optional smaller line shown between title and body on iOS 10+.
    subtitle?: string;
    body: string;
    data?: Record<string, string>;
}

/**
 * Result of an APNs send. `terminal === true` means Apple told us this
 * device token is permanently dead (uninstalled, expired, malformed,
 * sandbox/prod mismatch) and the caller MUST delete the token from its
 * own storage. Apple's docs make it very clear: keep retrying these and
 * they'll throttle the whole topic.
 */
export interface PushResult {
    ok: boolean;
    status: number;
    reason?: string;
    /// Caller should delete this token row from the database.
    terminal: boolean;
}

/// APNs status/reason combinations that mean "this token is dead, delete
/// it permanently". 410 always = gone. 400 BadDeviceToken = invalid format
/// or sandbox/prod mismatch — equally hopeless from the server's POV.
function isTerminalApnsError(status: number, reason?: string): boolean {
    if (status === 410) return true;                                // Unregistered, ExpiredToken
    if (status === 400 && reason === 'BadDeviceToken') return true;
    if (status === 400 && reason === 'DeviceTokenNotForTopic') return true;
    return false;
}

/// Pull the `reason` field out of an APNs response body. Apple returns a
/// JSON envelope with `{ reason: "...", timestamp: ... }` on error.
function parseApnsReason(body: string): string | undefined {
    try {
        const parsed = JSON.parse(body);
        return typeof parsed?.reason === 'string' ? parsed.reason : undefined;
    } catch {
        return undefined;
    }
}

/**
 * Send a push notification to a device token via HTTP/2. Node's built-in
 * `fetch()` uses HTTP/1.1 which APNs rejects with "fetch failed" — so we
 * reuse the same `apnsHttp2Request()` helper that the Live Activity path
 * already relies on.
 */
export async function sendPush(deviceToken: string, payload: PushPayload): Promise<PushResult> {
    const apnsConfig = getApnsConfig();
    if (!apnsConfig) {
        console.log('[APNs] Not configured, skipping push');
        return { ok: false, status: 0, terminal: false };
    }

    // http2.connect() interprets the authority string as a URL — without an
    // explicit https:// scheme it would default to http:// and fail to connect.
    // Match the format sendLiveActivityUpdate uses below.
    const host = apnsConfig.production
        ? 'https://api.push.apple.com'
        : 'https://api.sandbox.push.apple.com';

    try {
        const authToken = await getAuthToken(apnsConfig);

        const alert: Record<string, string> = {
            title: payload.title,
            body: payload.body,
        };
        if (payload.subtitle) alert.subtitle = payload.subtitle;
        const apnsPayload = {
            aps: {
                alert,
                sound: 'default',
                'mutable-content': 1,
            },
            ...(payload.data || {}),
        };

        const headers: Record<string, string> = {
            'authorization': `bearer ${authToken}`,
            'apns-topic': apnsConfig.bundleId,
            'apns-push-type': 'alert',
            'apns-priority': '10',
            'content-type': 'application/json',
        };

        const result = await apnsHttp2Request(
            host,
            `/3/device/${deviceToken}`,
            headers,
            JSON.stringify(apnsPayload)
        );

        console.log(`[APNs Alert] host=${host} token=${deviceToken.substring(0, 12)} topic=${apnsConfig.bundleId} status=${result.status} apnsId=${result.apnsId ?? '-'} body=${result.body || '(empty)'}`);

        if (result.status >= 200 && result.status < 300) {
            return { ok: true, status: result.status, terminal: false };
        }
        const reason = parseApnsReason(result.body);
        const terminal = isTerminalApnsError(result.status, reason);
        console.error(`[APNs] Push failed: ${result.status} reason=${reason ?? '?'} terminal=${terminal}`);
        return { ok: false, status: result.status, reason, terminal };
    } catch (error) {
        console.error('[APNs] Push error:', error);
        return { ok: false, status: 0, terminal: false };
    }
}

/**
 * Send push to all tokens for a device.
 *
 * Defense-in-depth: before pushing we verify the device still has at least
 * one active DeviceLink. If not (e.g. the iPhone was unpaired but its push
 * tokens lingered for some reason), we drop the push and self-heal by
 * deleting the orphaned tokens. This is the last line of defence behind the
 * cascade cleanup in DELETE /v1/pairing/links — if we ever miss the cascade
 * (server crash mid-unlink, manual DB edits, etc.) this still stops the
 * "unpaired but still receiving alerts" failure mode.
 */
export async function sendPushToDevice(
    deviceId: string,
    payload: PushPayload,
    db: any
): Promise<void> {
    const linkCount = await db.deviceLink.count({
        where: {
            OR: [
                { sourceDeviceId: deviceId },
                { targetDeviceId: deviceId },
            ],
        },
    });
    if (linkCount === 0) {
        const cleaned = await db.pushToken.deleteMany({ where: { deviceId } });
        console.log(`[sendPushToDevice] device=${deviceId.substring(0, 10)} has 0 DeviceLinks — orphaned, cleaned ${cleaned.count} tokens, skipped push`);
        return;
    }

    const tokens = await db.pushToken.findMany({
        where: { deviceId },
        select: { token: true },
    });

    console.log(`[sendPushToDevice] device=${deviceId.substring(0, 10)} tokenCount=${tokens.length} title=${payload.title}`);
    if (tokens.length === 0) {
        console.log(`[sendPushToDevice]   no PushTokens registered — iPhone probably never called POST /v1/push-tokens`);
        return;
    }

    const results = await Promise.allSettled(
        tokens.map((t: { token: string }) => sendPush(t.token, payload))
    );
    // Self-heal: any token that came back terminal (Unregistered / 410 /
    // BadDeviceToken / sandbox-prod mismatch) is permanently dead. Apple
    // explicitly tells us to delete these — keeping them around triggers
    // throttling on the entire topic and is the root cause of "I uninstalled
    // the app months ago and the server is still trying to push to me".
    const tokensToDelete: string[] = [];
    results.forEach((r, i) => {
        const tok = tokens[i].token;
        const tokPreview = tok.substring(0, 10);
        if (r.status === 'fulfilled') {
            const res = r.value;
            console.log(`[sendPushToDevice]   token=${tokPreview} status=${res.status} ok=${res.ok} terminal=${res.terminal}`);
            if (res.terminal) tokensToDelete.push(tok);
        } else {
            console.error(`[sendPushToDevice]   token=${tokPreview} → REJECTED`, r.reason);
        }
    });
    if (tokensToDelete.length > 0) {
        const deleted = await db.pushToken.deleteMany({
            where: { deviceId, token: { in: tokensToDelete } },
        });
        console.log(`[sendPushToDevice]   self-healed: deleted ${deleted.count} dead PushTokens for device ${deviceId.substring(0, 10)}`);
    }
}

/**
 * Live Activity ContentState matching CodeLightActivityAttributes.ContentState.
 */
export interface LiveActivityContentState {
    activeSessionId: string;
    projectName: string;
    projectPath: string | null;
    phase: string;
    toolName: string | null;
    lastUserMessage: string | null;
    lastAssistantSummary: string | null;
    totalSessions: number;
    activeSessions: number;
    startedAt: number; // unix timestamp
}

/**
 * Send HTTP/2 request to APNs (required — fetch() uses HTTP/1.1).
 */
function apnsHttp2Request(host: string, path: string, headers: Record<string, string>, body: string): Promise<{ status: number; body: string; apnsId?: string }> {
    return new Promise((resolve, reject) => {
        const client = http2.connect(host);

        client.on('error', (err) => {
            client.close();
            reject(err);
        });

        const req = client.request({
            ':method': 'POST',
            ':path': path,
            ...headers,
        });

        let responseBody = '';
        let statusCode = 0;
        let apnsId: string | undefined;

        req.on('response', (headers) => {
            statusCode = headers[':status'] as number;
            apnsId = headers['apns-id'] as string | undefined;
        });

        req.on('data', (chunk) => {
            responseBody += chunk.toString();
        });

        req.on('end', () => {
            client.close();
            resolve({ status: statusCode, body: responseBody, apnsId });
        });

        req.on('error', (err) => {
            client.close();
            reject(err);
        });

        req.write(body);
        req.end();
    });
}

/**
 * Send a Live Activity update via APNs push.
 * This updates an existing Live Activity on the device. Returns the same
 * structured PushResult as `sendPush()` so callers can self-heal dead
 * tokens (the Live Activity APNs feedback path is the noisiest source of
 * stale tokens — sandbox/prod mismatches happen on every fresh install).
 */
export async function sendLiveActivityUpdate(
    pushToken: string,
    contentState: LiveActivityContentState,
    event: 'update' | 'end' = 'update'
): Promise<PushResult> {
    const apnsConfig = getApnsConfig();
    if (!apnsConfig) {
        console.log('[APNs] Not configured, skipping Live Activity push');
        return { ok: false, status: 0, terminal: false };
    }

    const host = apnsConfig.production
        ? 'https://api.push.apple.com'
        : 'https://api.sandbox.push.apple.com';

    try {
        const authToken = await getAuthToken(apnsConfig);

        const apnsPayload: any = {
            aps: {
                timestamp: Math.floor(Date.now() / 1000),
                event,
                'content-state': contentState,
            },
        };

        if (event === 'end') {
            apnsPayload.aps['dismissal-date'] = Math.floor(Date.now() / 1000) + 5;
        }

        const headers = {
            'authorization': `bearer ${authToken}`,
            'apns-topic': `${apnsConfig.bundleId}.push-type.liveactivity`,
            'apns-push-type': 'liveactivity',
            'apns-priority': '10',
            'content-type': 'application/json',
        };

        const result = await apnsHttp2Request(host, `/3/device/${pushToken}`, headers, JSON.stringify(apnsPayload));

        if (result.status === 200) {
            console.log(`[APNs LiveActivity] Push sent: phase=${contentState.phase}`);
            return { ok: true, status: 200, terminal: false };
        }

        const reason = parseApnsReason(result.body);
        const terminal = isTerminalApnsError(result.status, reason);
        console.error(`[APNs LiveActivity] Push failed: ${result.status} reason=${reason ?? '?'} terminal=${terminal}`);
        return { ok: false, status: result.status, reason, terminal };
    } catch (error) {
        console.error('[APNs LiveActivity] Push error:', error);
        return { ok: false, status: 0, terminal: false };
    }
}

// ─────────────────────────────────────────────────────────────────────
// Trial expiry notification
// ─────────────────────────────────────────────────────────────────────

// Track which devices already received a trial expiry notification
// (in-memory, resets on restart — worst case they get one extra notification)
const trialExpiryNotified = new Set<string>();

/** Send a push notification warning that the trial expires within 24h. */
export async function sendTrialExpiryNotification(deviceId: string): Promise<void> {
    if (trialExpiryNotified.has(deviceId)) return;
    trialExpiryNotified.add(deviceId);

    const { db } = await import('@/storage/db');
    await sendPushToDevice(deviceId, {
        title: 'Your Code Light trial ends tomorrow',
        body: 'Upgrade to keep using Code Light with your Mac.',
        data: { type: 'trial_expiry' },
    }, db);

    console.log(`[APNs] Sent trial expiry notification to device ${deviceId.substring(0, 10)}`);
}
