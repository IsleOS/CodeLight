import type { Socket } from 'socket.io';
import { db } from '@/storage/db';
import { allocateSessionSeq } from '@/storage/seq';
import type { EventRouter } from './eventRouter';
import { canAccessSession } from '@/auth/deviceAccess';
import { sendPushToDevice, sendLiveActivityUpdate } from '@/push/apns';

export function registerSessionHandler(
    socket: Socket,
    deviceId: string,
    eventRouter: EventRouter
) {
    socket.on('message', async (data: {
        sid: string;
        message: string;
        localId?: string;
    }, callback?: (result: any) => void) => {
        try {
            // Verify device can access this session
            if (!await canAccessSession(deviceId, data.sid)) {
                console.log(`[sessionHandler] Access denied: device ${deviceId} → session ${data.sid}`);
                callback?.({ error: 'Access denied' });
                return;
            }

            if (data.localId) {
                const existing = await db.sessionMessage.findUnique({
                    where: { sessionId_localId: { sessionId: data.sid, localId: data.localId } },
                });
                if (existing) {
                    callback?.({ id: existing.id, seq: existing.seq });
                    return;
                }
            }

            const seq = await allocateSessionSeq(data.sid);
            const message = await db.sessionMessage.create({
                data: {
                    sessionId: data.sid,
                    content: data.message,
                    localId: data.localId,
                    seq,
                },
            });

            eventRouter.emitUpdate(deviceId, 'update', {
                type: 'new-message',
                sessionId: data.sid,
                message: { id: message.id, seq, content: data.message, localId: data.localId },
            }, { type: 'all-interested-in-session', sessionId: data.sid }, socket);

            // Handle phase messages: push Live Activity update via APNs
            try {
                const parsed = JSON.parse(data.message);

                if (parsed.type === 'phase') {
                    // Find all Live Activity tokens for this session
                    const laTokens = await db.liveActivityToken.findMany({
                        where: { sessionId: data.sid },
                    });

                    if (laTokens.length > 0) {
                        const session = await db.session.findUnique({
                            where: { id: data.sid },
                            select: { metadata: true },
                        });
                        let projectName = 'Session';
                        try {
                            const meta = JSON.parse(session?.metadata || '{}');
                            projectName = meta.title || 'Session';
                        } catch {}

                        const contentState = {
                            phase: parsed.phase || 'idle',
                            toolName: parsed.toolName || null,
                            projectName,
                            lastUserMessage: parsed.lastUserMessage || null,
                            lastAssistantSummary: parsed.lastAssistantSummary || null,
                            startedAt: Date.now() / 1000,
                        };

                        // Push to all device tokens for this session
                        for (const t of laTokens) {
                            sendLiveActivityUpdate(t.token, contentState as any).catch(() => {});
                        }
                    }
                }

                // Tool error → notification
                if (parsed.type === 'tool' && parsed.toolStatus === 'error') {
                    const session = await db.session.findUnique({ where: { id: data.sid }, select: { deviceId: true } });
                    if (session) {
                        sendPushToDevice(session.deviceId, { title: 'Tool Error', body: `${parsed.toolName || 'Tool'} failed` }, db);
                    }
                }
            } catch {}

            callback?.({ id: message.id, seq });
        } catch (error) {
            callback?.({ error: 'Failed to save message' });
        }
    });

    socket.on('update-metadata', async (data: {
        sid: string;
        metadata: string;
        expectedVersion: number;
    }, callback?: (result: any) => void) => {
        if (!await canAccessSession(deviceId, data.sid)) {
            callback?.({ result: 'denied' });
            return;
        }

        const result = await db.session.updateMany({
            where: {
                id: data.sid,
                metadataVersion: data.expectedVersion,
            },
            data: {
                metadata: data.metadata,
                metadataVersion: data.expectedVersion + 1,
            },
        });

        if (result.count === 0) {
            callback?.({ result: 'conflict' });
            return;
        }

        eventRouter.emitUpdate(deviceId, 'update', {
            type: 'update-session',
            sessionId: data.sid,
            metadata: data.metadata,
        }, { type: 'all-interested-in-session', sessionId: data.sid }, socket);

        callback?.({ result: 'ok', version: data.expectedVersion + 1 });
    });

    socket.on('session-alive', async (data: { sid: string }) => {
        // Alive is read-only status — allow if device can access session
        if (!await canAccessSession(deviceId, data.sid)) return;

        await db.session.update({
            where: { id: data.sid },
            data: { lastActiveAt: new Date(), active: true },
        }).catch(() => {});

        eventRouter.emitEphemeral(deviceId, 'ephemeral', {
            type: 'activity',
            sessionId: data.sid,
            active: true,
        });
    });

    socket.on('session-end', async (data: { sid: string }) => {
        if (!await canAccessSession(deviceId, data.sid)) return;

        await db.session.update({
            where: { id: data.sid },
            data: { active: false, lastActiveAt: new Date() },
        }).catch(() => {});

        eventRouter.emitUpdate(deviceId, 'update', {
            type: 'update-session',
            sessionId: data.sid,
            active: false,
        }, { type: 'all-interested-in-session', sessionId: data.sid });
    });
}
