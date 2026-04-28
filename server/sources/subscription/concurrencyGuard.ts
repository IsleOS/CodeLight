import { config } from '@/config';

/**
 * In-memory tracker for concurrent socket connections per subscription.
 * Lost on restart — sockets reconnect automatically and re-register.
 */
const activeConnections = new Map<string, Set<string>>();

/** Check if a new connection is allowed for this transaction ID. */
export function canConnect(originalTransactionId: string, socketId: string): boolean {
    const conns = activeConnections.get(originalTransactionId);
    if (!conns) return true;
    // Already connected with this socket (reconnect case)
    if (conns.has(socketId)) return true;
    return conns.size < config.maxConcurrentDevices;
}

/** Register a socket connection for a transaction ID. */
export function addConnection(originalTransactionId: string, socketId: string): void {
    if (!activeConnections.has(originalTransactionId)) {
        activeConnections.set(originalTransactionId, new Set());
    }
    activeConnections.get(originalTransactionId)!.add(socketId);
}

/** Remove a socket connection. Call on disconnect. */
export function removeConnection(originalTransactionId: string, socketId: string): void {
    const conns = activeConnections.get(originalTransactionId);
    if (conns) {
        conns.delete(socketId);
        if (conns.size === 0) activeConnections.delete(originalTransactionId);
    }
}

/** Get count of active connections for a transaction ID. */
export function getActiveCount(originalTransactionId: string): number {
    return activeConnections.get(originalTransactionId)?.size ?? 0;
}

/** Get all socket IDs for a transaction ID (for "kick device" UI). */
export function getActiveSocketIds(originalTransactionId: string): string[] {
    const conns = activeConnections.get(originalTransactionId);
    return conns ? Array.from(conns) : [];
}

/** Remove ALL connections for a transaction ID (used on revoke). */
export function disconnectAll(originalTransactionId: string): string[] {
    const conns = activeConnections.get(originalTransactionId);
    if (!conns) return [];
    const socketIds = Array.from(conns);
    activeConnections.delete(originalTransactionId);
    return socketIds;
}
