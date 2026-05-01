import type { Socket } from 'socket.io';
import { getAccessibleDeviceIds } from '@/auth/deviceAccess';

export interface ClientConnection {
    connectionType: 'session-scoped' | 'user-scoped';
    socket: Socket;
    deviceId: string;
    sessionId?: string;
}

export type RecipientFilter =
    | { type: 'all-interested-in-session'; sessionId: string }
    | { type: 'user-scoped-only' }
    | { type: 'all' };

export class EventRouter {
    private connections = new Map<string, Set<ClientConnection>>();

    addConnection(deviceId: string, connection: ClientConnection) {
        if (!this.connections.has(deviceId)) {
            this.connections.set(deviceId, new Set());
        }
        this.connections.get(deviceId)!.add(connection);
    }

    removeConnection(deviceId: string, connection: ClientConnection) {
        const conns = this.connections.get(deviceId);
        if (conns) {
            conns.delete(connection);
            if (conns.size === 0) this.connections.delete(deviceId);
        }
    }

    getConnections(deviceId: string): ClientConnection[] {
        return Array.from(this.connections.get(deviceId) || []);
    }

    /** Total number of connected sockets across all devices. */
    getConnectionCount(): number {
        let count = 0;
        for (const conns of this.connections.values()) count += conns.size;
        return count;
    }

    /** Check if a specific device has at least one active socket. */
    isDeviceConnected(deviceId: string): boolean {
        const conns = this.connections.get(deviceId);
        return !!conns && conns.size > 0;
    }

    /** Broadcast to connected devices that are linked to the sender via DeviceLink. */
    async emitUpdate(
        senderDeviceId: string,
        event: string,
        payload: unknown,
        filter: RecipientFilter,
        skipSocket?: Socket
    ) {
        // Only send to devices that are linked to the sender (including the sender itself).
        const allowedIds = new Set(await getAccessibleDeviceIds(senderDeviceId));
        let sent = 0;
        let skipped = 0;
        for (const [devId, conns] of this.connections.entries()) {
            if (!allowedIds.has(devId)) { skipped += conns.size; continue; }
            for (const conn of conns) {
                if (conn.socket === skipSocket) { skipped++; continue; }
                if (this.shouldSend(conn, filter)) {
                    conn.socket.emit(event, payload);
                    sent++;
                } else {
                    skipped++;
                }
            }
        }
        const type = (payload as any)?.type || event;
        console.log(`[EventRouter] ${type}: sent=${sent} skipped=${skipped} allowed=${allowedIds.size} totalDevices=${this.connections.size}`);
    }

    async emitEphemeral(senderDeviceId: string, event: string, payload: unknown) {
        await this.emitUpdate(senderDeviceId, event, payload, { type: 'all' });
    }

    /** Emit an event to all connections of a specific target device. */
    emitToDevice(targetDeviceId: string, event: string, payload: unknown): number {
        const conns = this.connections.get(targetDeviceId);
        if (!conns) return 0;
        let count = 0;
        for (const conn of conns) {
            conn.socket.emit(event, payload);
            count++;
        }
        return count;
    }

    private shouldSend(conn: ClientConnection, filter: RecipientFilter): boolean {
        switch (filter.type) {
            case 'all':
                return true;
            case 'user-scoped-only':
                return conn.connectionType === 'user-scoped';
            case 'all-interested-in-session':
                return conn.connectionType === 'user-scoped' ||
                    (conn.connectionType === 'session-scoped' && conn.sessionId === filter.sessionId);
        }
    }
}
