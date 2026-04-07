import type { Socket } from 'socket.io';
import { db } from '@/storage/db';
import { allocateSessionSeq } from '@/storage/seq';
import type { EventRouter } from './eventRouter';
import { canAccessSession } from '@/auth/deviceAccess';
import { sendPushToDevice, sendLiveActivityUpdate } from '@/push/apns';
import { deleteBlob } from '@/blob/blobStore';

// In-memory phase state per session, used to detect transitions like
// "non-ended → ended" so we only fire a completion notification on the exact
// moment Claude finishes, not on every ended heartbeat. Lost on restart —
// worst case we miss one notification right after a restart.
const lastPhaseBySession = new Map<string, string>();

/// Send completion / approval alerts to every iPhone linked to the Mac that
/// owns this session, respecting each iPhone's notification preferences.
async function notifyLinkedIPhones(params: {
    macDeviceId: string;
    kind: 'completion' | 'approval' | 'error';
    title: string;
    body: string;
    sessionId: string;
}) {
    const { macDeviceId, kind, title, body, sessionId } = params;
    // Find iPhones linked to this Mac — check both directions since DeviceLink is symmetric.
    const links = await db.deviceLink.findMany({
        where: {
            OR: [
                { sourceDeviceId: macDeviceId },
                { targetDeviceId: macDeviceId },
            ],
        },
    });
    const iPhoneIds = new Set<string>();
    for (const link of links) {
        if (link.sourceDeviceId !== macDeviceId) iPhoneIds.add(link.sourceDeviceId);
        if (link.targetDeviceId !== macDeviceId) iPhoneIds.add(link.targetDeviceId);
    }
    if (iPhoneIds.size === 0) return;

    const devices = await db.device.findMany({
        where: { id: { in: Array.from(iPhoneIds) }, kind: 'ios' },
        select: {
            id: true,
            notifyOnCompletion: true,
            notifyOnApproval: true,
            notifyOnError: true,
        },
    });

    console.log(`[notify] kind=${kind} mac=${macDeviceId.substring(0,10)} linkedIphones=${iPhoneIds.size} candidates=${devices.length}`);
    for (const d of devices) {
        const enabled =
            (kind === 'completion' && d.notifyOnCompletion) ||
            (kind === 'approval'   && d.notifyOnApproval)   ||
            (kind === 'error'      && d.notifyOnError);
        console.log(`[notify]   iphone=${d.id.substring(0,10)} completion=${d.notifyOnCompletion} approval=${d.notifyOnApproval} error=${d.notifyOnError} → enabled=${enabled}`);
        if (!enabled) continue;
        sendPushToDevice(d.id, {
            title,
            body,
            data: { sessionId, kind },
        }, db).then((result) => {
            console.log(`[notify]   → sendPushToDevice result=${JSON.stringify(result)}`);
        }).catch((err) => {
            console.error('[notify]   push failed', err);
        });
    }
}

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

            // Look up tag (Claude UUID) and path so receivers can route to a terminal
            // even if they aren't currently tracking this session locally.
            const sessionInfo = await db.session.findUnique({
                where: { id: data.sid },
                select: { tag: true, metadata: true },
            });
            let sessionTag: string | null = sessionInfo?.tag ?? null;
            let sessionPath: string | null = null;
            try {
                const meta = JSON.parse(sessionInfo?.metadata || '{}');
                if (typeof meta.path === 'string') sessionPath = meta.path;
            } catch {}

            eventRouter.emitUpdate(deviceId, 'update', {
                type: 'new-message',
                sessionId: data.sid,
                sessionTag,
                sessionPath,
                message: { id: message.id, seq, content: data.message, localId: data.localId },
            }, { type: 'all-interested-in-session', sessionId: data.sid }, socket);

            // Handle phase messages: push Live Activity update via APNs
            try {
                const parsed = JSON.parse(data.message);

                if (parsed.type === 'phase') {
                    console.log(`[Phase] session=${data.sid.substring(0,10)} phase=${parsed.phase} tool=${parsed.toolName || '-'}`);

                    // Find GLOBAL Live Activity token for this device (sessionId="__global__")
                    const globalTokens = await db.liveActivityToken.findMany({
                        where: { sessionId: '__global__' },
                    });

                    if (globalTokens.length === 0) {
                        console.log(`[Phase]   no global Live Activity tokens registered`);
                    } else {
                        const session = await db.session.findUnique({
                            where: { id: data.sid },
                            select: { metadata: true, deviceId: true },
                        });
                        let projectName = 'Session';
                        let projectPath: string | null = null;
                        try {
                            const meta = JSON.parse(session?.metadata || '{}');
                            projectName = meta.title || 'Session';
                            projectPath = meta.path || null;
                        } catch {}

                        // Count sessions for aggregate display
                        const totalSessions = await db.session.count();
                        const activeSessions = await db.session.count({ where: { active: true } });

                        const contentState = {
                            activeSessionId: data.sid,
                            projectName,
                            projectPath,
                            phase: parsed.phase || 'idle',
                            toolName: parsed.toolName || null,
                            lastUserMessage: parsed.lastUserMessage || null,
                            lastAssistantSummary: parsed.lastAssistantSummary || null,
                            totalSessions,
                            activeSessions,
                            startedAt: Date.now() / 1000,
                        };

                        for (const t of globalTokens) {
                            sendLiveActivityUpdate(t.token, contentState as any).catch(() => {});
                        }
                    }

                    // Detect phase transitions we notify on: non-ended → ended
                    // (completion) and anything → waiting_approval. We DO NOT
                    // fire on every ended heartbeat, only the first.
                    const newPhase = parsed.phase || 'idle';
                    const prevPhase = lastPhaseBySession.get(data.sid);
                    lastPhaseBySession.set(data.sid, newPhase);
                    console.log(`[transition] ${data.sid.substring(0,10)} ${prevPhase ?? '(first)'} → ${newPhase}`);

                    if (prevPhase && prevPhase !== newPhase) {
                        const session = await db.session.findUnique({
                            where: { id: data.sid },
                            select: { deviceId: true, metadata: true },
                        });
                        if (session) {
                            let projectName = 'Session';
                            try {
                                const meta = JSON.parse(session.metadata || '{}');
                                projectName = meta.title || meta.projectName || 'Session';
                            } catch {}

                            if (newPhase === 'ended' && prevPhase !== 'ended') {
                                const tail = (parsed.lastAssistantSummary || parsed.lastUserMessage || '').toString().slice(0, 80);
                                notifyLinkedIPhones({
                                    macDeviceId: session.deviceId,
                                    kind: 'completion',
                                    title: projectName,
                                    body: tail.length > 0 ? tail : 'Claude is ready for your next message',
                                    sessionId: data.sid,
                                }).catch(() => {});
                            } else if (newPhase === 'waiting_approval') {
                                const tool = (parsed.toolName || 'a tool').toString();
                                notifyLinkedIPhones({
                                    macDeviceId: session.deviceId,
                                    kind: 'approval',
                                    title: projectName,
                                    body: `Needs approval: ${tool}`,
                                    sessionId: data.sid,
                                }).catch(() => {});
                            }
                        }
                    }
                }

                // Tool error → respect per-device notifyOnError
                if (parsed.type === 'tool' && parsed.toolStatus === 'error') {
                    const session = await db.session.findUnique({ where: { id: data.sid }, select: { deviceId: true, metadata: true } });
                    if (session) {
                        let projectName = 'Session';
                        try {
                            const meta = JSON.parse(session.metadata || '{}');
                            projectName = meta.title || meta.projectName || 'Session';
                        } catch {}
                        notifyLinkedIPhones({
                            macDeviceId: session.deviceId,
                            kind: 'error',
                            title: projectName,
                            body: `${parsed.toolName || 'Tool'} failed`,
                            sessionId: data.sid,
                        }).catch(() => {});
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

    // CodeIsland acknowledges that it successfully consumed a blob, so the server
    // can drop it from disk immediately. No ack from CodeIsland = TTL sweeper handles it.
    socket.on('blob-consumed', async (data: { blobId: string }) => {
        if (!data?.blobId) return;
        const ok = await deleteBlob(data.blobId);
        if (ok) console.log(`[blob-consumed] deleted ${data.blobId}`);
    });
}
