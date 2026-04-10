import { FastifyInstance } from 'fastify';
import { authMiddleware } from '@/auth/middleware';
import { putBlob, readBlob, getBlob } from './blobStore';

const MAX_BLOB_BYTES = 8 * 1024 * 1024; // 8 MB per blob
const ALLOWED_MIME = new Set([
    'image/jpeg',
    'image/png',
    'image/heic',
    'image/webp',
    'image/gif',
]);

export async function blobRoutes(app: FastifyInstance) {
    // Raw binary body parser for blob uploads
    app.addContentTypeParser(
        ['application/octet-stream', 'image/jpeg', 'image/png', 'image/heic', 'image/webp', 'image/gif'],
        { parseAs: 'buffer', bodyLimit: MAX_BLOB_BYTES },
        (_req, body, done) => {
            done(null, body);
        }
    );

    // Upload a blob. Mime is sent via X-Blob-Mime header (or Content-Type if set).
    app.post('/v1/blobs', {
        preHandler: authMiddleware,
        bodyLimit: MAX_BLOB_BYTES,
    }, async (request, reply) => {
        const body = request.body as Buffer;
        if (!Buffer.isBuffer(body) || body.length === 0) {
            return reply.code(400).send({ error: 'Empty body' });
        }
        if (body.length > MAX_BLOB_BYTES) {
            return reply.code(413).send({ error: 'Blob too large' });
        }

        const headerMime = (request.headers['x-blob-mime'] as string | undefined)
            || (request.headers['content-type'] as string | undefined)
            || 'application/octet-stream';
        const mime = headerMime.split(';')[0]!.trim().toLowerCase();
        if (!ALLOWED_MIME.has(mime)) {
            return reply.code(415).send({ error: `Unsupported mime: ${mime}` });
        }

        const rec = await putBlob(request.deviceId!, mime, body);
        return { blobId: rec.id, mime: rec.mime, size: rec.size };
    });

    // Download a blob. MioIsland fetches this, then acks via socket to trigger delete.
    app.get('/v1/blobs/:id', {
        preHandler: authMiddleware,
    }, async (request, reply) => {
        const { id } = request.params as { id: string };
        const rec = getBlob(id);
        if (!rec) {
            return reply.code(404).send({ error: 'Blob not found' });
        }
        const data = await readBlob(id);
        if (!data) {
            return reply.code(404).send({ error: 'Blob not found' });
        }
        reply.header('content-type', rec.mime);
        reply.header('content-length', data.length.toString());
        return reply.send(data);
    });
}
