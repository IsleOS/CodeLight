import { FastifyInstance } from 'fastify';
import { authMiddleware } from '@/auth/middleware';
import { getAccessibleDeviceIds } from '@/auth/deviceAccess';
import { putCapabilities, getCapabilities, type CapabilitySnapshot } from './capabilityStore';

export async function capabilityRoutes(app: FastifyInstance) {
    // Pounce pushes its latest capability snapshot here. No schema validation:
    // the payload is opaque to the server, we just stash it per-device.
    app.post('/v1/capabilities', {
        preHandler: authMiddleware,
    }, async (request, reply) => {
        const deviceId = request.deviceId!;
        const body = request.body as CapabilitySnapshot | undefined;
        if (!body || typeof body !== 'object') {
            return reply.code(400).send({ error: 'Invalid body' });
        }
        putCapabilities(deviceId, body);
        return { ok: true };
    });

    // Phone fetches the snapshot. Returns the first accessible device that has
    // uploaded one — in practice a single user has their own device + one Pounce.
    app.get('/v1/capabilities', {
        preHandler: authMiddleware,
    }, async (request, reply) => {
        const accessibleIds = await getAccessibleDeviceIds(request.deviceId!);
        for (const id of accessibleIds) {
            const snap = getCapabilities(id);
            if (snap) return snap;
        }
        return reply.code(404).send({ error: 'No capabilities uploaded yet' });
    });
}
