import type { Socket } from 'socket.io';
import { db } from '@/storage/db';
import { allocateSessionSeq } from '@/storage/seq';
import type { EventRouter } from './eventRouter';
import { canAccessSession, getAccessibleDeviceIds } from '@/auth/deviceAccess';
import { sendPushToDevice, sendLiveActivityUpdate } from '@/push/apns';
import { deleteBlob } from '@/blob/blobStore';
import { config } from '@/config';

/// How long after a device's last successful auth we keep pushing alerts
/// to it. We use the JWT TTL plus a 1-day grace so brief downtime doesn't
/// silence anyone — but a device that hasn't auth'd in over a JWT lifetime
/// has effectively gone dark and we should stop spamming APNs on its behalf.
function getStaleThresholdMs(): number {
    const days = (config.tokenExpiryDays || 30) + 1;
    return days * 24 * 60 * 60 * 1000;
}

// In-memory phase state per session, used to detect transitions like
// "non-ended → ended" so we only fire a completion notification on the exact
// moment Claude finishes, not on every ended heartbeat. Lost on restart —
// worst case we miss one notification right after a restart.
const lastPhaseBySession = new Map<string, string>();

/// Pull the latest user message + the latest assistant message for a session
/// directly from SessionMessage. We can't trust phase payload fields because
/// MioIsland sometimes ships a phase event before its in-memory snapshot
/// catches up to the message that just landed in JSONL — that's how the user
/// ended up seeing "上上次" content in the notification.
async function fetchLatestQAndA(sessionId: string): Promise<{ userText: string; assistantText: string }> {
    // Pull recent messages descending and pick the first match of each kind.
    // 30 is a safe upper bound — there's never that many phase/tool events
    // sandwiched between a Q and an A.
    const recent = await db.sessionMessage.findMany({
        where: { sessionId },
        orderBy: { seq: 'desc' },
        take: 30,
        select: { content: true },
    });

    let userText = '';
    let assistantText = '';

    for (const m of recent) {
        if (userText && assistantText) break;
        try {
            const parsed = JSON.parse(m.content);
            if (parsed?.type === 'user' && !userText) {
                userText = (parsed.text || '').toString();
            } else if (parsed?.type === 'assistant' && !assistantText) {
                assistantText = (parsed.text || '').toString();
            }
        } catch {
            // Plain-text bodies (the phone path) are user messages.
            if (!userText) {
                userText = m.content;
            }
        }
    }

    return { userText, assistantText };
}

/// Strip excessive whitespace and trim a body of text to a hard limit. iOS
/// notification body shows ~4 lines collapsed and ~10 lines expanded — 280
/// characters is a comfortable upper bound that fills the expanded view
/// without truncating sentences.
function shapeNotificationText(raw: string, maxLength = 280): string {
    const collapsed = raw.replace(/\s+/g, ' ').trim();
    if (collapsed.length <= maxLength) return collapsed;
    return collapsed.slice(0, maxLength - 1).trimEnd() + '…';
}

/// Resolve a STABLE project name from session metadata. We deliberately do
/// NOT use `meta.title` here because MioIsland sets that to a "smart title"
/// that prefers the latest summary or user message — which means if it leaks
/// into the Live Activity it'll show user input on the trailing side. Use the
/// folder name (`projectName`), falling back to the last component of the
/// path, falling back to a placeholder.
function resolveStableProjectName(metadataJson: string | null | undefined): { name: string; path: string | null } {
    let path: string | null = null;
    let name = 'Session';
    if (!metadataJson) return { name, path };
    try {
        const meta = JSON.parse(metadataJson);
        if (typeof meta.path === 'string') path = meta.path;
        if (typeof meta.projectName === 'string' && meta.projectName.trim().length > 0) {
            name = meta.projectName.trim();
        } else if (path) {
            const segments = path.split('/').filter(Boolean);
            if (segments.length > 0) name = segments[segments.length - 1];
        }
    } catch {}
    return { name, path };
}

/// Send completion / approval alerts to every iPhone linked to the Mac that
/// owns this session, respecting each iPhone's notification preferences.
async function notifyLinkedIPhones(params: {
    macDeviceId: string;
    kind: 'completion' | 'approval' | 'error';
    title: string;
    subtitle?: string;
    body: string;
    sessionId: string;
}) {
    const { macDeviceId, kind, title, subtitle, body, sessionId } = params;
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
            notificationsEnabled: true,
            notifyOnCompletion: true,
            notifyOnApproval: true,
            notifyOnError: true,
            lastSeenAt: true,
        },
    });

    const staleCutoff = Date.now() - getStaleThresholdMs();
    console.log(`[notify] kind=${kind} mac=${macDeviceId.substring(0,10)} linkedIphones=${iPhoneIds.size} candidates=${devices.length}`);
    for (const d of devices) {
        // Master kill-switch — if the iPhone has flipped its top-level
        // notifications toggle off, skip without checking per-kind flags.
        if (!d.notificationsEnabled) {
            console.log(`[notify]   iphone=${d.id.substring(0,10)} master=OFF → skipped`);
            continue;
        }
        // Staleness filter — JWT-expired iPhones can't refresh their
        // server state but APNs may still happily deliver to them. After
        // a JWT lifetime + grace day with no auth, treat the device as
        // dark and stop pushing. Devices with NULL lastSeenAt are
        // pre-migration rows (we backfilled them on deploy) and pass.
        if (d.lastSeenAt && d.lastSeenAt.getTime() < staleCutoff) {
            const daysAgo = Math.floor((Date.now() - d.lastSeenAt.getTime()) / (24 * 60 * 60 * 1000));
            console.log(`[notify]   iphone=${d.id.substring(0,10)} stale=${daysAgo}d → skipped`);
            continue;
        }
        const enabled =
            (kind === 'completion' && d.notifyOnCompletion) ||
            (kind === 'approval'   && d.notifyOnApproval)   ||
            (kind === 'error'      && d.notifyOnError);
        console.log(`[notify]   iphone=${d.id.substring(0,10)} completion=${d.notifyOnCompletion} approval=${d.notifyOnApproval} error=${d.notifyOnError} → enabled=${enabled}`);
        if (!enabled) continue;
        sendPushToDevice(d.id, {
            title,
            subtitle,
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

                    // Find GLOBAL Live Activity tokens — only for iPhones linked to this Mac.
                    const linkedIds = await getAccessibleDeviceIds(deviceId);
                    const globalTokens = await db.liveActivityToken.findMany({
                        where: { sessionId: '__global__', deviceId: { in: linkedIds } },
                    });

                    if (globalTokens.length === 0) {
                        console.log(`[Phase]   no global Live Activity tokens registered`);
                    } else {
                        const session = await db.session.findUnique({
                            where: { id: data.sid },
                            select: { metadata: true, deviceId: true },
                        });
                        const resolved = resolveStableProjectName(session?.metadata);
                        const projectName = resolved.name;
                        const projectPath = resolved.path;

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
                            sendLiveActivityUpdate(t.token, contentState as any).then((res) => {
                                // Self-heal: when APNs tells us the Live
                                // Activity token is permanently dead, drop
                                // it so we stop spamming the same dead row
                                // forever (this is the noisiest source of
                                // 410/BadDeviceToken errors in our logs).
                                if (res.terminal) {
                                    db.liveActivityToken.delete({ where: { id: t.id } }).catch(() => {});
                                    console.log(`[LiveActivity] Self-healed: deleted dead token id=${t.id}`);
                                }
                            }).catch(() => {});
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
                            const projectName = resolveStableProjectName(session.metadata).name;

                            if (newPhase === 'ended' && prevPhase !== 'ended') {
                                // Pull the actual latest user question + assistant
                                // reply from the DB so the notification reflects
                                // *this* turn, not a stale phase-payload snapshot.
                                const { userText, assistantText } = await fetchLatestQAndA(data.sid);
                                const title = userText
                                    ? shapeNotificationText(userText, 60)
                                    : projectName;
                                const body = assistantText
                                    ? shapeNotificationText(assistantText, 280)
                                    : 'Claude is ready for your next message';
                                notifyLinkedIPhones({
                                    macDeviceId: session.deviceId,
                                    kind: 'completion',
                                    title,
                                    subtitle: userText ? projectName : undefined,
                                    body,
                                    sessionId: data.sid,
                                }).catch(() => {});
                            } else if (newPhase === 'waiting_approval') {
                                const tool = (parsed.toolName || 'a tool').toString();
                                const { userText } = await fetchLatestQAndA(data.sid);
                                notifyLinkedIPhones({
                                    macDeviceId: session.deviceId,
                                    kind: 'approval',
                                    title: userText ? shapeNotificationText(userText, 60) : projectName,
                                    subtitle: userText ? projectName : undefined,
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
                        const projectName = resolveStableProjectName(session.metadata).name;
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

    // MioIsland acknowledges that it successfully consumed a blob, so the server
    // can drop it from disk immediately. No ack from MioIsland = TTL sweeper handles it.
    socket.on('blob-consumed', async (data: { blobId: string }) => {
        if (!data?.blobId) return;
        const ok = await deleteBlob(data.blobId);
        if (ok) console.log(`[blob-consumed] deleted ${data.blobId}`);
    });
}
