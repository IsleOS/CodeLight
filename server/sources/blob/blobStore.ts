/**
 * Ephemeral blob store for images sent from phone → Pounce.
 *
 * Design:
 *   - Files live in BLOB_DIR (default ./blobs), named <id>.bin
 *   - Metadata kept in-memory only (Map). Process restart drops everything.
 *   - Three-tier cleanup:
 *       1. Consumed on delivery (socket ack)
 *       2. TTL sweep every minute, 10-min deadline
 *       3. Purge-all on server startup
 *
 * Not meant for persistent storage — purely a transit buffer for messages
 * in flight between the phone and the desktop companion.
 */

import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

const BLOB_DIR = path.resolve(process.cwd(), 'blobs');
const TTL_MS = 10 * 60 * 1000;    // 10 minutes
const SWEEP_MS = 60 * 1000;       // every 1 minute

interface BlobRecord {
    id: string;
    mime: string;
    size: number;
    deviceId: string;
    createdAt: number;
    filePath: string;
}

const blobs = new Map<string, BlobRecord>();

export async function initBlobStore() {
    // Startup purge: wipe any leftover files from prior runs
    try {
        await fs.rm(BLOB_DIR, { recursive: true, force: true });
    } catch {}
    await fs.mkdir(BLOB_DIR, { recursive: true });
    console.log(`[BlobStore] Initialized at ${BLOB_DIR}`);

    // Periodic TTL sweep
    setInterval(sweepExpired, SWEEP_MS);
}

async function sweepExpired() {
    const now = Date.now();
    const expired: string[] = [];
    for (const [id, rec] of blobs) {
        if (now - rec.createdAt > TTL_MS) expired.push(id);
    }
    for (const id of expired) {
        await deleteBlob(id).catch(() => {});
    }
    if (expired.length > 0) {
        console.log(`[BlobStore] Swept ${expired.length} expired blobs`);
    }
}

export async function putBlob(deviceId: string, mime: string, data: Buffer): Promise<BlobRecord> {
    const id = crypto.randomBytes(16).toString('hex');
    const filePath = path.join(BLOB_DIR, `${id}.bin`);
    await fs.writeFile(filePath, data);
    const rec: BlobRecord = {
        id,
        mime,
        size: data.length,
        deviceId,
        createdAt: Date.now(),
        filePath,
    };
    blobs.set(id, rec);
    return rec;
}

export function getBlob(id: string): BlobRecord | undefined {
    return blobs.get(id);
}

export async function readBlob(id: string): Promise<Buffer | null> {
    const rec = blobs.get(id);
    if (!rec) return null;
    try {
        return await fs.readFile(rec.filePath);
    } catch {
        blobs.delete(id);
        return null;
    }
}

export async function deleteBlob(id: string): Promise<boolean> {
    const rec = blobs.get(id);
    if (!rec) return false;
    blobs.delete(id);
    try {
        await fs.unlink(rec.filePath);
    } catch {}
    return true;
}

export function blobCount(): number {
    return blobs.size;
}
