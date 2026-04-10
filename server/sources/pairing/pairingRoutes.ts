import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { db } from '@/storage/db';
import { authMiddleware } from '@/auth/middleware';
import { linkDevices } from '@/auth/deviceAccess';
import { eventRouter } from '@/socket/socketServer';

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
}
