import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { db } from '@/storage/db';
import { authMiddleware } from '@/auth/middleware';
import { linkDevices, invalidateAccessCache } from '@/auth/deviceAccess';
import { eventRouter } from '@/socket/socketServer';

// In-memory rate limiter for Mac /v1/pairing/redeem-code. 10 fails/hour/device.
// Separate keyspace from /v1/subscription/redeem (iPhone-side, soon deprecated)
// so a Mac brute-forcing can't be diluted by also having tried the iPhone path.
const macRedeemFailures = new Map<string, { count: number; resetAt: number }>();

function macIsRateLimited(deviceId: string): boolean {
    const now = Date.now();
    const entry = macRedeemFailures.get(deviceId);
    if (!entry || entry.resetAt < now) return false;
    return entry.count >= 10;
}

function macRecordFailure(deviceId: string): void {
    const now = Date.now();
    const entry = macRedeemFailures.get(deviceId);
    if (!entry || entry.resetAt < now) {
        macRedeemFailures.set(deviceId, { count: 1, resetAt: now + 60 * 60 * 1000 });
    } else {
        entry.count++;
    }
}

function macClearFailures(deviceId: string): void {
    macRedeemFailures.delete(deviceId);
}

// Propagate a Mac's active trial to a freshly-paired iPhone.
// Idempotent + safe: only acts when the source is a Mac with a non-expired
// trialExpiresAt and the target is an iOS device. Lets pairing-after-redeem
// hand off the entitlement automatically; the iPhone never had to ask.
async function propagateMacSubscriptionToPhone(macId: string, phoneId: string): Promise<void> {
    const mac = await db.device.findUnique({
        where: { id: macId },
        select: { kind: true, subscriptionStatus: true, trialExpiresAt: true },
    });
    if (!mac || mac.kind !== 'mac') return;
    if (mac.subscriptionStatus !== 'active') return;
    if (!mac.trialExpiresAt || mac.trialExpiresAt < new Date()) return;

    const result = await db.device.updateMany({
        where: { id: phoneId, kind: 'ios' },
        data: {
            subscriptionStatus: 'active',
            trialExpiresAt: mac.trialExpiresAt,
        },
    });
    if (result.count === 0) return;

    const daysLeft = Math.max(
        0,
        Math.ceil((mac.trialExpiresAt.getTime() - Date.now()) / (24 * 60 * 60 * 1000))
    );
    eventRouter.emitToDevice(phoneId, 'subscription-updated', { status: 'active', daysLeft });
    console.log(`[pairing-inherit] Phone ${phoneId} inherited trial from Mac ${macId} (until ${mac.trialExpiresAt.toISOString()})`);
}

export async function pairingRoutes(app: FastifyInstance) {

    // Step 1: MioIsland creates a pairing request (authenticated)
    // Stores the initiator's deviceId for later verification
    app.post('/v1/pairing/request', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                tempPublicKey: z.string(),
                serverUrl: z.string(),
                deviceName: z.string(),
            }),
        },
    }, async (request) => {
        const { tempPublicKey, serverUrl, deviceName } = request.body as {
            tempPublicKey: string;
            serverUrl: string;
            deviceName: string;
        };
        const expiresAt = new Date(Date.now() + 5 * 60 * 1000);

        const pairing = await db.pairingRequest.upsert({
            where: { tempPublicKey },
            create: {
                tempPublicKey,
                serverUrl,
                deviceName,
                expiresAt,
                // Store initiator's deviceId in responseDeviceId temporarily
                // (will be overwritten when response comes in)
                responseDeviceId: request.deviceId,
            },
            update: { serverUrl, deviceName, expiresAt, response: null, responseDeviceId: request.deviceId },
        });

        return { id: pairing.id, expiresAt: pairing.expiresAt.toISOString() };
    });

    // Step 2: CodeLight scans QR, responds (authenticated)
    // This creates a DeviceLink between the two devices
    app.post('/v1/pairing/respond', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                tempPublicKey: z.string(),
                response: z.string(),
            }),
        },
    }, async (request, reply) => {
        const { tempPublicKey, response } = request.body as {
            tempPublicKey: string;
            response: string;
        };

        const pairing = await db.pairingRequest.findUnique({
            where: { tempPublicKey },
        });

        if (!pairing) {
            return reply.code(404).send({ error: 'Pairing request not found' });
        }

        if (pairing.expiresAt < new Date()) {
            await db.pairingRequest.delete({ where: { id: pairing.id } });
            return reply.code(410).send({ error: 'Pairing request expired' });
        }

        const initiatorDeviceId = pairing.responseDeviceId;
        const responderDeviceId = request.deviceId!;

        // Create device link (bidirectional access)
        if (initiatorDeviceId && initiatorDeviceId !== responderDeviceId) {
            await linkDevices(initiatorDeviceId, responderDeviceId);
            console.log(`[pairing] Linked devices: ${initiatorDeviceId} <-> ${responderDeviceId}`);

            // If either side is a Mac with an active trial, hand the trial to
            // the other side. Function is a no-op when neither side qualifies.
            await propagateMacSubscriptionToPhone(initiatorDeviceId, responderDeviceId);
            await propagateMacSubscriptionToPhone(responderDeviceId, initiatorDeviceId);
        }

        // Update pairing with response
        await db.pairingRequest.update({
            where: { id: pairing.id },
            data: { response, responseDeviceId: responderDeviceId },
        });

        return { success: true, linkedWith: initiatorDeviceId };
    });

    // Step 3: MioIsland polls for response
    // Only the initiator can poll (verified by deviceId)
    app.get('/v1/pairing/status', {
        preHandler: authMiddleware,
        schema: {
            querystring: z.object({
                tempPublicKey: z.string(),
            }),
        },
    }, async (request, reply) => {
        const { tempPublicKey } = request.query as { tempPublicKey: string };

        const pairing = await db.pairingRequest.findUnique({
            where: { tempPublicKey },
        });

        if (!pairing) {
            return reply.code(404).send({ error: 'Not found' });
        }

        // Only the initiator can poll their own pairing request
        if (pairing.responseDeviceId && pairing.response === null && pairing.responseDeviceId !== request.deviceId!) {
            return reply.code(403).send({ error: 'Access denied' });
        }

        if (pairing.response) {
            // Clean up — pairing complete
            await db.pairingRequest.delete({ where: { id: pairing.id } });
            return {
                status: 'paired',
                response: pairing.response,
                responseDeviceId: pairing.responseDeviceId,
            };
        }

        if (pairing.expiresAt < new Date()) {
            await db.pairingRequest.delete({ where: { id: pairing.id } });
            return { status: 'expired' };
        }

        return { status: 'pending' };
    });

    // ─────────────────────────────────────────────────────────────────────
    // Short-code pairing flow
    //
    // Each Mac has a permanent shortCode (Device.shortCode), lazy-allocated
    // by POST /v1/devices/me. iPhone redeems the code here to establish a
    // DeviceLink. The same code remains valid forever — pairing additional
    // iPhones is just additional redeem calls.
    // ─────────────────────────────────────────────────────────────────────

    // iPhone redeems a Mac's permanent shortCode → links the two devices.
    app.post('/v1/pairing/code/redeem', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({ code: z.string().min(4).max(12) }),
        },
    }, async (request, reply) => {
        const { code } = request.body as { code: string };
        const normalized = code.toUpperCase().trim();
        const iosDeviceId = request.deviceId!;

        const macDevice = await db.device.findUnique({
            where: { shortCode: normalized },
            select: { id: true, name: true, kind: true },
        });
        if (!macDevice) {
            return reply.code(404).send({ error: 'Invalid code' });
        }
        if (macDevice.id === iosDeviceId) {
            return reply.code(400).send({ error: 'Cannot pair with yourself' });
        }
        if (macDevice.kind !== 'mac') {
            return reply.code(400).send({ error: 'Code does not belong to a Mac device' });
        }

        await linkDevices(macDevice.id, iosDeviceId);

        console.log(`[pairing] Code-redeemed link: ${macDevice.id} <-> ${iosDeviceId}`);

        // Inherit Mac trial if active.
        await propagateMacSubscriptionToPhone(macDevice.id, iosDeviceId);

        return {
            macDeviceId: macDevice.id,
            name: macDevice.name,
            kind: macDevice.kind,
        };
    });

    // ─────────────────────────────────────────────────────────────────────
    // Device link management
    // ─────────────────────────────────────────────────────────────────────

    // List all devices linked to the caller.
    app.get('/v1/pairing/links', {
        preHandler: authMiddleware,
    }, async (request) => {
        const myDeviceId = request.deviceId!;
        const links = await db.deviceLink.findMany({
            where: {
                OR: [
                    { sourceDeviceId: myDeviceId },
                    { targetDeviceId: myDeviceId },
                ],
            },
            include: {
                sourceDevice: { select: { id: true, name: true, kind: true } },
                targetDevice: { select: { id: true, name: true, kind: true } },
            },
            orderBy: { createdAt: 'desc' },
        });

        const links_out = links.map((l) => {
            const peer = l.sourceDeviceId === myDeviceId ? l.targetDevice : l.sourceDevice;
            return {
                deviceId: peer.id,
                name: peer.name,
                kind: peer.kind,
                createdAt: l.createdAt.toISOString(),
            };
        });

        return links_out;
    });

    // Unlink the caller from a target device. Notifies the target via socket.
    // After deleting the link, cascade-cleanup any device that no longer has
    // ANY remaining DeviceLinks: drop its push tokens so we don't keep firing
    // APNs alerts at an iPhone that thinks it's no longer paired. Without
    // this, "unpair last Mac" left orphaned PushTokens that kept receiving
    // alerts forever (the user's reported Bug 3).
    app.delete('/v1/pairing/links/:targetDeviceId', {
        preHandler: authMiddleware,
        schema: {
            params: z.object({ targetDeviceId: z.string() }),
        },
    }, async (request, reply) => {
        const myDeviceId = request.deviceId!;
        const { targetDeviceId } = request.params as { targetDeviceId: string };

        const deleted = await db.deviceLink.deleteMany({
            where: {
                OR: [
                    { sourceDeviceId: myDeviceId, targetDeviceId },
                    { sourceDeviceId: targetDeviceId, targetDeviceId: myDeviceId },
                ],
            },
        });

        if (deleted.count === 0) {
            return reply.code(404).send({ error: 'Link not found' });
        }

        // Drop cached access decisions so the unlinked device loses access immediately.
        invalidateAccessCache();

        // Cascade push-token cleanup for any device that just became unlinked.
        for (const id of [myDeviceId, targetDeviceId]) {
            const remaining = await db.deviceLink.count({
                where: {
                    OR: [
                        { sourceDeviceId: id },
                        { targetDeviceId: id },
                    ],
                },
            });
            if (remaining === 0) {
                const tokenResult = await db.pushToken.deleteMany({ where: { deviceId: id } });
                if (tokenResult.count > 0) {
                    console.log(`[pairing] Cascade-deleted ${tokenResult.count} push tokens for ${id}`);
                }
            }
        }

        // Notify the other side so it can clean local state
        eventRouter.emitToDevice(targetDeviceId, 'link-removed', {
            sourceDeviceId: myDeviceId,
        });

        console.log(`[pairing] Unlinked ${myDeviceId} <-> ${targetDeviceId}`);
        return { ok: true };
    });

    // ─────────────────────────────────────────────────────────────────────
    // Mac-side trial redemption (replaces App-side /v1/subscription/redeem
    // which Apple flagged as Guideline 3.1.1 violation — paid-feature unlock
    // outside IAP). Mac inputs a FREE-XXXXXXXX code, Mac gets the trial,
    // any iPhone paired to this Mac inherits the entitlement automatically.
    //
    // Error envelope is stable: { error: <machine-readable-key>, message: <human> }.
    // Clients should switch on `error`, not on HTTP status.
    // ─────────────────────────────────────────────────────────────────────
    app.post('/v1/pairing/redeem-code', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({ code: z.string().min(1).max(50) }),
        },
    }, async (request, reply) => {
        const macDeviceId = request.deviceId!;
        const { code } = request.body as { code: string };
        const normalized = code.trim().toUpperCase();

        try {

        if (macIsRateLimited(macDeviceId)) {
            return reply.code(429).send({
                error: 'rate_limited',
                message: 'Too many failed attempts. Try again in an hour.',
            });
        }

        // Confirm the caller is a Mac. Phones can't redeem (Apple rule).
        const device = await db.device.findUnique({
            where: { id: macDeviceId },
            select: { kind: true },
        });
        if (!device) {
            return reply.code(401).send({ error: 'unauthorized', message: 'Device not found' });
        }
        if (device.kind !== 'mac') {
            return reply.code(403).send({
                error: 'not_a_mac',
                message: 'Only Mac devices can redeem trial codes',
            });
        }

        const redeemCode = await db.redeemCode.findUnique({ where: { code: normalized } });
        if (!redeemCode) {
            macRecordFailure(macDeviceId);
            return reply.code(404).send({ error: 'invalid_code', message: 'Invalid redeem code' });
        }

        if (redeemCode.expiresAt && redeemCode.expiresAt < new Date()) {
            return reply.code(410).send({ error: 'code_expired', message: 'This code has expired' });
        }

        // Admin-revoked codes carry maxUses=0.
        if (redeemCode.maxUses === 0) {
            return reply.code(410).send({ error: 'code_revoked', message: 'This code has been revoked' });
        }

        // Same Mac can't redeem the same code twice.
        const existingUsage = await db.redeemCodeUsage.findUnique({
            where: {
                redeemCodeId_deviceId: {
                    redeemCodeId: redeemCode.id,
                    deviceId: macDeviceId,
                },
            },
        });
        if (existingUsage) {
            return reply.code(409).send({
                error: 'already_redeemed',
                message: 'This Mac has already used this code',
            });
        }

        const grantedUntil = new Date(Date.now() + redeemCode.durationDays * 24 * 60 * 60 * 1000);

        // Atomic exhausted-check + bump + write inside a transaction so
        // concurrent redeems can't oversell a maxUses=N code.
        try {
            await db.$transaction(async (tx) => {
                const fresh = await tx.redeemCode.findUnique({
                    where: { id: redeemCode.id },
                    select: { usedCount: true, maxUses: true },
                });
                if (!fresh || fresh.usedCount >= fresh.maxUses) {
                    throw Object.assign(new Error('exhausted'), { code: 'code_exhausted' });
                }

                await tx.redeemCodeUsage.create({
                    data: { redeemCodeId: redeemCode.id, deviceId: macDeviceId, grantedUntil },
                });
                await tx.redeemCode.update({
                    where: { id: redeemCode.id },
                    data: { usedCount: { increment: 1 } },
                });
                await tx.device.update({
                    where: { id: macDeviceId },
                    data: {
                        subscriptionStatus: 'active',
                        trialExpiresAt: grantedUntil,
                    },
                });
            });
        } catch (err: any) {
            if (err?.code === 'code_exhausted') {
                return reply.code(410).send({
                    error: 'code_exhausted',
                    message: 'This code has been fully redeemed',
                });
            }
            throw err;
        }

        macClearFailures(macDeviceId);

        // Propagate to every iPhone already paired to this Mac, both as
        // persistent device state (so a later reconnect sees active) and
        // as a live socket event (so an in-app screen updates immediately).
        const links = await db.deviceLink.findMany({
            where: {
                OR: [
                    { sourceDeviceId: macDeviceId },
                    { targetDeviceId: macDeviceId },
                ],
            },
            select: { sourceDeviceId: true, targetDeviceId: true },
        });

        const daysLeft = Math.max(
            0,
            Math.ceil((grantedUntil.getTime() - Date.now()) / (24 * 60 * 60 * 1000))
        );

        // Build the canonical socket payload. Same payload shape goes to the
        // Mac itself (so its banner refreshes live) and to every linked iPhone
        // (so AppState picks it up — iPhone reads daysLeft already, ignores
        // expiresAt/source extras).
        const expiresAtISO = grantedUntil.toISOString();
        const socketPayload = {
            status: 'trial',
            expiresAt: expiresAtISO,
            source: 'redeem_code',
            daysLeft,
        };

        // Self-broadcast so the Mac's own UI reflects the new state without
        // having to re-fetch /v1/subscription/status.
        eventRouter.emitToDevice(macDeviceId, 'subscription-updated', socketPayload);

        let propagated = 0;
        for (const l of links) {
            const peerId = l.sourceDeviceId === macDeviceId ? l.targetDeviceId : l.sourceDeviceId;
            const updated = await db.device.updateMany({
                where: { id: peerId, kind: 'ios' },
                data: { subscriptionStatus: 'active', trialExpiresAt: grantedUntil },
            });
            if (updated.count > 0) {
                propagated++;
                eventRouter.emitToDevice(peerId, 'subscription-updated', socketPayload);
            }
        }

        console.log(
            `[pairing-redeem] Mac ${macDeviceId} redeemed ${normalized}, ` +
            `granted ${redeemCode.durationDays}d, propagated to ${propagated} iPhone(s)`
        );

        return {
            success: true,
            durationDays: redeemCode.durationDays,
            expiresAt: expiresAtISO,
        };

        } catch (err: any) {
            // Stable envelope for any unexpected failure (DB down, prisma
            // engine crash, etc.). Client switches on `error`, so giving them
            // server_error here keeps them on the same code path as for known
            // errors and prevents falling back to Fastify's default 500 body
            // which has a different shape.
            console.error(`[pairing-redeem] Unexpected error for Mac ${macDeviceId}:`, err);
            return reply.code(500).send({
                error: 'server_error',
                message: err?.message || 'Internal server error',
            });
        }
    });
}
