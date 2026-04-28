import { Server as HttpServer } from 'http';
import { Server } from 'socket.io';
import { verifyToken } from '@/auth/crypto';
import { bumpLastSeenAt } from '@/auth/middleware';
import { config } from '@/config';
import { EventRouter, type ClientConnection } from './eventRouter';
import { registerSessionHandler } from './sessionHandler';
import { registerRpcHandler } from './rpcHandler';
import { checkAccess, getDeviceSubscription, startTrial } from '@/subscription/subscriptionService';
import * as concurrencyGuard from '@/subscription/concurrencyGuard';

export const eventRouter = new EventRouter();

export function startSocket(server: HttpServer) {
    const io = new Server(server, {
        cors: { origin: '*', methods: ['GET', 'POST', 'OPTIONS'] },
        transports: ['websocket', 'polling'],
        pingTimeout: 45000,
        pingInterval: 15000,
        path: '/v1/updates',
        connectTimeout: 20000,
    });

    io.on('connection', async (socket) => {
        // Support both auth object and query params (Swift Socket.io client uses query)
        const token = (socket.handshake.auth.token || socket.handshake.query.token) as string | undefined;
        const clientType = ((socket.handshake.auth.clientType || socket.handshake.query.clientType) as string) || 'user-scoped';
        const sessionId = (socket.handshake.auth.sessionId || socket.handshake.query.sessionId) as string | undefined;
        console.log(`Socket connection: clientType=${clientType}, hasToken=${!!token}`);

        if (!token) {
            socket.disconnect();
            return;
        }

        const payload = verifyToken(token, config.masterSecret);
        if (!payload) {
            socket.disconnect();
            return;
        }

        // ── Subscription check ──────────────────────────────────────────
        let trackedTransactionId: string | null = null;
        if (config.enforceSubscription) {
            let access = await checkAccess(payload.deviceId);

            // Auto-start trial for iOS devices that have no subscription yet
            // (covers existing users who paired before subscription system was deployed)
            if (!access.allowed && access.reason === 'no_subscription') {
                await startTrial(payload.deviceId);
                access = await checkAccess(payload.deviceId);
            }

            if (!access.allowed) {
                socket.emit('subscription-required', {
                    reason: access.reason,
                    status: access.status,
                });
                socket.disconnect();
                return;
            }

            // Concurrent device limit (only for paid users with a subscription)
            const sub = await getDeviceSubscription(payload.deviceId);
            if (sub?.originalTransactionId) {
                if (!concurrencyGuard.canConnect(sub.originalTransactionId, socket.id)) {
                    socket.emit('device-limit-reached', {
                        max: config.maxConcurrentDevices,
                        currentDevices: concurrencyGuard.getActiveCount(sub.originalTransactionId),
                    });
                    socket.disconnect();
                    return;
                }
                concurrencyGuard.addConnection(sub.originalTransactionId, socket.id);
                trackedTransactionId = sub.originalTransactionId;
            }
        }
        // ── End subscription check ───────────────────────────────────────

        const connection: ClientConnection = {
            connectionType: clientType === 'session-scoped' ? 'session-scoped' : 'user-scoped',
            socket,
            deviceId: payload.deviceId,
            sessionId,
        };

        eventRouter.addConnection(payload.deviceId, connection);
        // Touch lastSeenAt so notifyLinkedIPhones can tell this device is
        // still alive even if the user only ever talks via the socket.
        bumpLastSeenAt(payload.deviceId);

        // Lightweight ping for client-side latency measurement — just ack immediately.
        socket.on('ping', (_data, ack) => { if (typeof ack === 'function') ack({}); });

        registerSessionHandler(socket, payload.deviceId, eventRouter);
        registerRpcHandler(socket, payload.deviceId);

        socket.on('disconnect', () => {
            eventRouter.removeConnection(payload.deviceId, connection);
            if (trackedTransactionId) {
                concurrencyGuard.removeConnection(trackedTransactionId, socket.id);
            }
        });
    });

    return io;
}
