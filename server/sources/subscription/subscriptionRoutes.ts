import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { X509Certificate } from 'node:crypto';
import { compactVerify, importX509 } from 'jose';
import { authMiddleware } from '@/auth/middleware';
import { verifyPayment, checkAccess, getDeviceSubscription, revokeSubscription, startTrial } from './subscriptionService';
import { getActiveCount } from './concurrencyGuard';
import { config } from '@/config';
import { eventRouter } from '@/socket/socketServer';

// Apple Root CA - G3 (ECDSA P-384)
// Source: https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
// SHA-256: 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
const APPLE_ROOT_CA_G3_PEM = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

const APPLE_ROOT_CA_G3_FINGERPRINT =
    '63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79';

// Pre-instantiate once at module load so startup errors surface immediately
const TRUSTED_ROOT = new X509Certificate(APPLE_ROOT_CA_G3_PEM);

/**
 * Verify an Apple App Store Server Notification JWS token.
 *
 * Apple signs all notification payloads with an ECDSA key whose certificate
 * chain is embedded in the JWS header (x5c). Verification steps:
 *  1. Parse x5c → build certificate chain (leaf, intermediate, …, root)
 *  2. Verify each cert is signed by the next one in the chain
 *  3. Confirm the root cert's SHA-256 fingerprint exactly matches Apple Root CA G3
 *  4. Verify the chain connects to the trusted root (intermediate signed by root)
 *  5. Verify the JWS ECDSA signature using the leaf cert's public key
 *
 * Returns the verified decoded payload, or throws on failure.
 */
async function verifyAppleJWS(token: string): Promise<unknown> {
    const parts = token.split('.');
    if (parts.length !== 3) throw new Error('Not a valid JWS (expected 3 parts)');

    const header = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
    if (!Array.isArray(header.x5c) || header.x5c.length < 2) {
        throw new Error('JWS header missing x5c certificate chain');
    }

    const toPEM = (der: string) =>
        `-----BEGIN CERTIFICATE-----\n${der.match(/.{1,64}/g)!.join('\n')}\n-----END CERTIFICATE-----`;

    const certs = (header.x5c as string[]).map(der => new X509Certificate(toPEM(der)));

    // Verify chain: cert[i] must be signed by cert[i+1]
    for (let i = 0; i < certs.length - 1; i++) {
        if (!certs[i].verify(certs[i + 1].publicKey)) {
            throw new Error(`Certificate chain broken between index ${i} and ${i + 1}`);
        }
    }

    // Root cert must exactly match the pinned Apple Root CA G3 fingerprint
    const root = certs[certs.length - 1];
    if (root.fingerprint256 !== APPLE_ROOT_CA_G3_FINGERPRINT) {
        throw new Error(`Root certificate fingerprint mismatch (got ${root.fingerprint256})`);
    }

    // Final check: last intermediate must be signed by our trusted root copy
    const lastIntermediate = certs[certs.length - 2];
    if (!lastIntermediate.verify(TRUSTED_ROOT.publicKey)) {
        throw new Error('Certificate chain does not connect to trusted Apple Root CA G3');
    }

    // Verify JWS signature with leaf cert's public key
    const leafPublicKey = await importX509(toPEM(header.x5c[0]), header.alg ?? 'ES256');
    const { payload } = await compactVerify(token, leafPublicKey);
    return JSON.parse(new TextDecoder().decode(payload));
}

export async function subscriptionRoutes(app: FastifyInstance) {
    // ─────────────────────────────────────────────────────────────────────
    // Verify payment (iPhone calls this after StoreKit 2 purchase)
    // ─────────────────────────────────────────────────────────────────────
    app.post('/v1/subscription/verify', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                originalTransactionId: z.string().min(1),
            }),
        },
    }, async (request, reply) => {
        const { originalTransactionId } = request.body as { originalTransactionId: string };
        const deviceId = request.deviceId!;

        const result = await verifyPayment(deviceId, originalTransactionId);

        if (result.success) {
            eventRouter.emitToDevice(deviceId, 'subscription-updated', { status: 'active' });
        }

        return result;
    });

    // ─────────────────────────────────────────────────────────────────────
    // Query subscription status
    // ─────────────────────────────────────────────────────────────────────
    app.get('/v1/subscription/status', {
        preHandler: authMiddleware,
    }, async (request) => {
        const deviceId = request.deviceId!;
        let access = await checkAccess(deviceId);
        // Mirror socket behavior: auto-start trial for iOS devices with no subscription yet
        if (!access.allowed && access.reason === 'no_subscription') {
            await startTrial(deviceId);
            access = await checkAccess(deviceId);
        }
        const sub = await getDeviceSubscription(deviceId);

        return {
            status: access.status,
            allowed: access.allowed,
            reason: access.reason,
            daysLeft: access.daysLeft,
            expiresAt: access.expiresAt ?? null,
            maxDevices: config.maxConcurrentDevices,
            currentDevices: sub?.originalTransactionId
                ? getActiveCount(sub.originalTransactionId)
                : 0,
        };
    });

    // ─────────────────────────────────────────────────────────────────────
    // App Store Server Notifications V2 webhook (refund/revoke)
    //
    // FIX #1: 加入 Apple JWS 签名验证。
    // 如果 APPLE_ROOT_CA 配置了，验证完整证书链。
    // 如果没配置，用 REVOKE_SHARED_SECRET 做简单鉴权。
    // 两个都没配，拒绝所有请求（安全第一）。
    // ─────────────────────────────────────────────────────────────────────
    app.post('/v1/subscription/revoke', {
        schema: {
            body: z.object({
                signedPayload: z.string().min(1),
            }),
        },
    }, async (request, reply) => {
        const { signedPayload } = request.body as { signedPayload: string };

        // 安全门：必须有验证机制才处理退款
        if (!config.revokeSharedSecret) {
            console.warn('[subscription] Revoke endpoint called but REVOKE_SHARED_SECRET not configured, rejecting');
            return reply.code(403).send({ error: 'Revoke endpoint not configured' });
        }

        // 简单鉴权：请求头必须带 shared secret
        // Apple Server Notifications V2 支持在 URL 里加 query param 作为验证
        // 实际配置 URL 为: https://server/v1/subscription/revoke?secret=YOUR_SECRET
        const querySecret = (request.query as any)?.secret;
        if (querySecret !== config.revokeSharedSecret) {
            console.warn('[subscription] Revoke request with invalid secret');
            return reply.code(403).send({ error: 'Invalid secret' });
        }

        try {
            // Verify outer notification JWS (Apple certificate chain + signature)
            const payload = await verifyAppleJWS(signedPayload) as any;

            const notificationType = payload.notificationType;
            if (notificationType !== 'REFUND' && notificationType !== 'REVOKE') {
                return { ok: true, handled: false };
            }

            const signedTxnInfo = payload.data?.signedTransactionInfo;
            if (!signedTxnInfo) {
                return reply.code(400).send({ error: 'Missing signedTransactionInfo' });
            }

            // Verify inner transaction JWS (also signed by Apple)
            const txnInfo = await verifyAppleJWS(signedTxnInfo) as any;
            const originalTransactionId = txnInfo.originalTransactionId;

            if (!originalTransactionId) {
                return reply.code(400).send({ error: 'Missing originalTransactionId' });
            }

            const affected = await revokeSubscription(originalTransactionId);

            console.log(`[subscription] App Store revoke: type=${notificationType}, txn=${originalTransactionId}, affected=${affected}`);

            return { ok: true, handled: true, affected };
        } catch (err) {
            console.error('[subscription] Failed to process App Store notification:', err);
            return reply.code(400).send({ error: 'Failed to parse notification' });
        }
    });
}
