import { db } from '@/storage/db';
import { config } from '@/config';
import { eventRouter } from '@/socket/socketServer';

export interface AccessCheck {
    allowed: boolean;
    reason: string;
    status: string;
    daysLeft?: number;
    expiresAt?: string; // ISO8601 — only set when access has a finite expiry (trial or redeemed)
}

/** Start a 3-day trial for an iOS device. No-op if already trialing or paid. */
export async function startTrial(deviceId: string): Promise<void> {
    const device = await db.device.findUnique({ where: { id: deviceId } });
    if (!device || device.subscriptionStatus !== 'none') return;

    const now = new Date();
    const expiresAt = new Date(now.getTime() + config.trialDays * 24 * 60 * 60 * 1000);

    await db.device.update({
        where: { id: deviceId },
        data: {
            subscriptionStatus: 'trial',
            trialStartedAt: now,
            trialExpiresAt: expiresAt,
        },
    });

    console.log(`[subscription] Trial started for device ${deviceId}, expires ${expiresAt.toISOString()}`);
}

/** Check whether a device is allowed to use the service. */
export async function checkAccess(deviceId: string): Promise<AccessCheck> {
    if (!config.enforceSubscription) {
        return { allowed: true, reason: 'subscription_not_enforced', status: 'none' };
    }

    const device = await db.device.findUnique({ where: { id: deviceId } });
    if (!device) {
        return { allowed: false, reason: 'device_not_found', status: 'none' };
    }

    if (device.kind === 'mac') {
        // Mac is always allowed access (the gate is on iPhones), but we still
        // expose its own trial state when one exists. This is what
        // /v1/pairing/redeem-code writes onto the Mac and what the MioIsland
        // banner reads via /v1/subscription/status. Falls through to the
        // generic mac_device response when there's no trial to surface.
        if (device.subscriptionStatus === 'active' && device.trialExpiresAt) {
            const now = new Date();
            if (device.trialExpiresAt > now) {
                const msLeft = device.trialExpiresAt.getTime() - now.getTime();
                const daysLeft = Math.ceil(msLeft / (24 * 60 * 60 * 1000));
                return {
                    allowed: true,
                    reason: 'mac_redeemed',
                    status: 'trial',
                    daysLeft,
                    expiresAt: device.trialExpiresAt.toISOString(),
                };
            }
            // Trial lapsed — flip the row but keep allowing the Mac (Mac is
            // never gated by subscription).
            await db.device.updateMany({
                where: { id: deviceId, subscriptionStatus: 'active' },
                data: { subscriptionStatus: 'expired' },
            });
            return { allowed: true, reason: 'mac_device', status: 'expired' };
        }
        return { allowed: true, reason: 'mac_device', status: 'none' };
    }

    if (device.subscriptionStatus === 'active') {
        // 兑换码用户有到期时间，永久付费用户没有
        if (device.trialExpiresAt) {
            const now = new Date();
            if (device.trialExpiresAt > now) {
                const msLeft = device.trialExpiresAt.getTime() - now.getTime();
                const daysLeft = Math.ceil(msLeft / (24 * 60 * 60 * 1000));
                return { allowed: true, reason: 'redeemed', status: 'active', daysLeft, expiresAt: device.trialExpiresAt.toISOString() };
            }
            // 兑换码到期
            await db.device.updateMany({
                where: { id: deviceId, subscriptionStatus: 'active' },
                data: { subscriptionStatus: 'expired' },
            });
            return { allowed: false, reason: 'access_expired', status: 'expired' };
        }
        return { allowed: true, reason: 'paid', status: 'active' };
    }

    if (device.subscriptionStatus === 'trial' && device.trialExpiresAt) {
        const now = new Date();
        if (device.trialExpiresAt > now) {
            const msLeft = device.trialExpiresAt.getTime() - now.getTime();
            const daysLeft = Math.ceil(msLeft / (24 * 60 * 60 * 1000));
            return { allowed: true, reason: 'trial', status: 'trial', daysLeft, expiresAt: device.trialExpiresAt.toISOString() };
        }
        // FIX #4: 加条件防止竞态，只更新仍为 trial 状态的记录
        await db.device.updateMany({
            where: { id: deviceId, subscriptionStatus: 'trial' },
            data: { subscriptionStatus: 'expired' },
        });
        return { allowed: false, reason: 'trial_expired', status: 'expired' };
    }

    if (device.subscriptionStatus === 'none') {
        return { allowed: false, reason: 'no_subscription', status: 'none' };
    }

    return { allowed: false, reason: device.subscriptionStatus, status: device.subscriptionStatus };
}

/**
 * Verify payment from StoreKit 2 and activate the device.
 *
 * FIX #2: 调用 Apple App Store Server API 验证 transactionId 真实性。
 * 如果 APPLE_ISSUER_ID 未配置，退化为信任客户端（适用于开发/测试阶段）。
 */
export async function verifyPayment(
    deviceId: string,
    originalTransactionId: string
): Promise<{ success: boolean; status: string; error?: string }> {
    // Fail-closed: production enforcement requires Apple API keys.
    // Without them a jailbroken client could fake any transactionId.
    if (config.appleApiKeyId) {
        const isValid = await verifyWithApple(originalTransactionId);
        if (!isValid) {
            console.warn(`[subscription] Apple verification failed for txn=${originalTransactionId}`);
            return { success: false, status: 'invalid', error: 'apple_verification_failed' };
        }
    } else if (config.enforceSubscription) {
        console.error('[subscription] APPLE_API_KEY_ID not configured but ENFORCE_SUBSCRIPTION=true — rejecting payment to prevent bypass');
        return { success: false, status: 'invalid', error: 'server_misconfigured' };
    } else {
        console.warn('[subscription] APPLE_API_KEY_ID not set, skipping Apple verification (dev/self-hosted mode)');
    }

    const subscription = await db.subscription.upsert({
        where: { originalTransactionId },
        create: {
            originalTransactionId,
            status: 'active',
            paidAt: new Date(),
        },
        update: {
            status: 'active',
            paidAt: new Date(),
            revokedAt: null,
        },
    });

    await db.subscriptionDevice.upsert({
        where: {
            subscriptionId_deviceId: {
                subscriptionId: subscription.id,
                deviceId,
            },
        },
        create: {
            subscriptionId: subscription.id,
            deviceId,
        },
        update: {},
    });

    await db.device.update({
        where: { id: deviceId },
        data: {
            subscriptionStatus: 'active',
            trialExpiresAt: null,  // clear trial expiry — paid users have permanent access
        },
    });

    console.log(`[subscription] Payment verified for device ${deviceId}, txn=${originalTransactionId}`);
    return { success: true, status: 'active' };
}

/**
 * 调用 Apple App Store Server API 验证 transaction。
 * 需要环境变量: APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, APPLE_API_PRIVATE_KEY
 * 参考: https://developer.apple.com/documentation/appstoreserverapi
 */
async function verifyWithApple(originalTransactionId: string): Promise<boolean> {
    try {
        const { SignJWT, importPKCS8 } = await import('jose');

        const keyId = config.appleApiKeyId!;
        const issuerId = config.appleApiIssuerId!;
        const privateKeyBase64 = config.appleApiPrivateKey!;

        // 构建 JWT token 用于 Apple API 认证
        const privateKeyPem = Buffer.from(privateKeyBase64, 'base64').toString('utf-8');
        const key = await importPKCS8(privateKeyPem, 'ES256');

        const token = await new SignJWT({})
            .setProtectedHeader({ alg: 'ES256', kid: keyId, typ: 'JWT' })
            .setIssuer(issuerId)
            .setIssuedAt()
            .setExpirationTime('5m')
            .setAudience('appstoreconnect-v1')
            .sign(key);

        const isProduction = process.env.NODE_ENV === 'production';
        const baseUrl = isProduction
            ? 'https://api.storekit.itunes.apple.com'
            : 'https://api.storekit-sandbox.itunes.apple.com';

        const response = await fetch(
            `${baseUrl}/inApps/v1/transactions/${originalTransactionId}`,
            {
                headers: { Authorization: `Bearer ${token}` },
            }
        );

        if (response.status === 200) {
            console.log(`[subscription] Apple API confirmed txn=${originalTransactionId}`);
            return true;
        }

        console.warn(`[subscription] Apple API rejected txn=${originalTransactionId}, status=${response.status}`);
        return false;
    } catch (err) {
        console.error(`[subscription] Apple API verification error:`, err);
        return false;
    }
}

/** Get the subscription linked to a device (if any). */
export async function getDeviceSubscription(deviceId: string) {
    const link = await db.subscriptionDevice.findFirst({
        where: { deviceId },
        include: { subscription: true },
        orderBy: { createdAt: 'desc' },
    });
    return link?.subscription ?? null;
}

/** Revoke a subscription (App Store refund). Returns number of affected devices. */
export async function revokeSubscription(originalTransactionId: string): Promise<number> {
    const subscription = await db.subscription.findUnique({
        where: { originalTransactionId },
        include: { devices: true },
    });

    if (!subscription) return 0;

    await db.subscription.update({
        where: { id: subscription.id },
        data: { status: 'revoked', revokedAt: new Date() },
    });

    const deviceIds = subscription.devices.map(d => d.deviceId);
    if (deviceIds.length > 0) {
        await db.device.updateMany({
            where: { id: { in: deviceIds }, subscriptionStatus: 'active' },
            data: { subscriptionStatus: 'expired' },
        });

        // Notify and disconnect any currently connected sockets
        for (const deviceId of deviceIds) {
            eventRouter.emitToDevice(deviceId, 'subscription-required', {
                reason: 'revoked',
                status: 'expired',
            });
        }
    }

    console.log(`[subscription] Revoked txn=${originalTransactionId}, affected ${deviceIds.length} devices`);
    return deviceIds.length;
}

/** Expire all stale trials. Called from cleanup job. */
export async function expireStaleTrials(): Promise<number> {
    const result = await db.device.updateMany({
        where: {
            subscriptionStatus: 'trial',
            trialExpiresAt: { lt: new Date() },
        },
        data: { subscriptionStatus: 'expired' },
    });
    if (result.count > 0) {
        console.log(`[subscription] Expired ${result.count} stale trials`);
    }
    return result.count;
}

/**
 * Find devices whose trial expires within 24h and haven't been notified yet
 * (or were last notified >23h ago). Marks them as notified atomically to
 * prevent sending 48 pushes over the 24h window.
 */
export async function findExpiringTrials(): Promise<Array<{ id: string; trialExpiresAt: Date }>> {
    const now = new Date();
    const in24h = new Date(now.getTime() + 24 * 60 * 60 * 1000);
    const notifyThreshold = new Date(now.getTime() - 23 * 60 * 60 * 1000);

    const devices = await db.device.findMany({
        where: {
            subscriptionStatus: 'trial',
            trialExpiresAt: { gte: now, lte: in24h },
            OR: [
                { trialExpireNotifiedAt: null },
                { trialExpireNotifiedAt: { lt: notifyThreshold } },
            ],
        },
        select: { id: true, trialExpiresAt: true },
    });

    const eligible = devices.filter((d): d is { id: string; trialExpiresAt: Date } =>
        d.trialExpiresAt !== null
    );

    if (eligible.length > 0) {
        await db.device.updateMany({
            where: { id: { in: eligible.map(d => d.id) } },
            data: { trialExpireNotifiedAt: now },
        });
    }

    return eligible;
}
