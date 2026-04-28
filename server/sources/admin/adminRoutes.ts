import { FastifyInstance } from 'fastify';
import { db } from '@/storage/db';
import { config } from '@/config';
import { eventRouter } from '@/socket/socketServer';

/** Admin endpoints — protected by MASTER_SECRET bearer token. */
export async function adminRoutes(app: FastifyInstance) {

    // Admin auth check
    app.addHook('onRequest', async (request, reply) => {
        const auth = request.headers.authorization;
        if (!auth || auth !== `Bearer ${config.masterSecret}`) {
            return reply.code(401).send({ error: 'Unauthorized' });
        }
    });

    // Server overview stats
    app.get('/v1/admin/stats', async () => {
        const [devices, sessions, messages, links, pushTokens, activeSessions] = await Promise.all([
            db.device.count(),
            db.session.count(),
            db.sessionMessage.count(),
            db.deviceLink.count(),
            db.pushToken.count(),
            db.session.count({ where: { active: true } }),
        ]);

        // Connected sockets from EventRouter
        const connectedDevices = eventRouter.getConnectionCount();

        return {
            devices,
            sessions,
            activeSessions,
            messages,
            links,
            pushTokens,
            connectedDevices,
        };
    });

    // List all devices with their link count and last seen
    app.get('/v1/admin/devices', async () => {
        const devices = await db.device.findMany({
            orderBy: { lastSeenAt: { sort: 'desc', nulls: 'last' } },
            select: {
                id: true,
                name: true,
                kind: true,
                shortCode: true,
                lastSeenAt: true,
                notificationsEnabled: true,
                createdAt: true,
            },
        });

        // Enrich with link count and online status
        const enriched = await Promise.all(devices.map(async (d) => {
            const linkCount = await db.deviceLink.count({
                where: { OR: [{ sourceDeviceId: d.id }, { targetDeviceId: d.id }] },
            });
            return {
                ...d,
                linkCount,
                online: eventRouter.isDeviceConnected(d.id),
            };
        }));

        return { devices: enriched };
    });

    // List all sessions with owner info
    app.get('/v1/admin/sessions', async (request) => {
        const { active, limit } = request.query as { active?: string; limit?: string };
        const where = active === 'true' ? { active: true } : active === 'false' ? { active: false } : {};

        const sessions = await db.session.findMany({
            where,
            orderBy: { lastActiveAt: 'desc' },
            take: parseInt(limit || '50', 10),
            include: {
                device: { select: { name: true, kind: true } },
            },
        });

        return { sessions };
    });

    // Read messages for any session (admin only, no device scoping)
    app.get('/v1/admin/sessions/:sessionId/messages', async (request) => {
        const { sessionId } = request.params as { sessionId: string };
        const { limit, before_seq } = request.query as { limit?: string; before_seq?: string };

        const take = parseInt(limit || '50', 10);
        const where: any = { sessionId };
        if (before_seq) {
            where.seq = { lt: parseInt(before_seq, 10) };
        }

        const messages = await db.sessionMessage.findMany({
            where,
            orderBy: { seq: 'desc' },
            take,
            select: { id: true, seq: true, content: true, createdAt: true },
        });

        return {
            messages: messages.reverse(),
            hasMore: messages.length === take,
        };
    });

    // Delete a device and all its data (nuclear option)
    app.delete('/v1/admin/devices/:deviceId', async (request) => {
        const { deviceId } = request.params as { deviceId: string };

        // Delete in order: messages → sessions → links → tokens → device
        const sessions = await db.session.findMany({ where: { deviceId }, select: { id: true } });
        const sessionIds = sessions.map(s => s.id);

        if (sessionIds.length > 0) {
            await db.sessionMessage.deleteMany({ where: { sessionId: { in: sessionIds } } });
        }
        await db.session.deleteMany({ where: { deviceId } });
        await db.deviceLink.deleteMany({
            where: { OR: [{ sourceDeviceId: deviceId }, { targetDeviceId: deviceId }] },
        });
        await db.pushToken.deleteMany({ where: { deviceId } });
        await db.liveActivityToken.deleteMany({ where: { deviceId } });
        await db.device.delete({ where: { id: deviceId } }).catch(() => {});

        return { ok: true, deletedSessions: sessionIds.length };
    });
}
