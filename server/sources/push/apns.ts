import { SignJWT, importPKCS8 } from 'jose';
import http2 from 'node:http2';
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

    const keyData = Buffer.from(apnsConfig.privateKey, 'base64').toString('utf-8');
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
    body: string;
    data?: Record<string, string>;
}

/**
 * Send a push notification to a device token via HTTP/2. Node's built-in
 * `fetch()` uses HTTP/1.1 which APNs rejects with "fetch failed" — so we
 * reuse the same `apnsHttp2Request()` helper that the Live Activity path
 * already relies on.
 */
export async function sendPush(deviceToken: string, payload: PushPayload): Promise<boolean> {
    const apnsConfig = getApnsConfig();
    if (!apnsConfig) {
        console.log('[APNs] Not configured, skipping push');
        return false;
    }

    // http2.connect() interprets the authority string as a URL — without an
    // explicit https:// scheme it would default to http:// and fail to connect.
    // Match the format sendLiveActivityUpdate uses below.
    const host = apnsConfig.production
        ? 'https://api.push.apple.com'
        : 'https://api.sandbox.push.apple.com';

    try {
        const authToken = await getAuthToken(apnsConfig);

        const apnsPayload = {
            aps: {
                alert: {
                    title: payload.title,
                    body: payload.body,
                },
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
            return true;
        }
        console.error(`[APNs] Push failed: ${result.status} ${result.body}`);
        return false;
    } catch (error) {
        console.error('[APNs] Push error:', error);
        return false;
    }
}

/**
 * Send push to all tokens for a device.
 */
export async function sendPushToDevice(
    deviceId: string,
    payload: PushPayload,
    db: any
): Promise<void> {
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
    results.forEach((r, i) => {
        const tok = tokens[i].token.substring(0, 10);
        if (r.status === 'fulfilled') {
            console.log(`[sendPushToDevice]   token=${tok} → ${r.value}`);
        } else {
            console.error(`[sendPushToDevice]   token=${tok} → REJECTED`, r.reason);
        }
    });
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
 * This updates an existing Live Activity on the device.
 */
export async function sendLiveActivityUpdate(
    pushToken: string,
    contentState: LiveActivityContentState,
    event: 'update' | 'end' = 'update'
): Promise<boolean> {
    const apnsConfig = getApnsConfig();
    if (!apnsConfig) {
        console.log('[APNs] Not configured, skipping Live Activity push');
        return false;
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
            return true;
        }

        console.error(`[APNs LiveActivity] Push failed: ${result.status} ${result.body}`);
        return false;
    } catch (error) {
        console.error('[APNs LiveActivity] Push error:', error);
        return false;
    }
}
