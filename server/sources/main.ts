import { db } from '@/storage/db';
import { startApi } from '@/api';
import { startSocket } from '@/socket/socketServer';
import { initBlobStore } from '@/blob/blobStore';
import { config } from '@/config';
import { expireStaleTrials, findExpiringTrials } from '@/subscription/subscriptionService';
import { sendTrialExpiryNotification } from '@/push/apns';

async function main() {
    if (!config.masterSecret || config.masterSecret === 'change-me-to-a-random-string') {
        console.error('MASTER_SECRET must be set');
        process.exit(1);
    }

    await db.$connect();
    console.log('Database connected');

    await initBlobStore();

    const app = await startApi();

    startSocket(app.server);
    console.log('Socket.io ready on /v1/updates');

    // Auto-cleanup stale sessions every hour (inactive for >4 hours)
    setInterval(async () => {
        try {
            const fourHoursAgo = new Date(Date.now() - 4 * 60 * 60 * 1000);
            const result = await db.session.updateMany({
                where: { active: true, lastActiveAt: { lt: fourHoursAgo } },
                data: { active: false },
            });
            if (result.count > 0) {
                console.log(`[Auto-cleanup] Marked ${result.count} stale sessions as inactive`);
                // Clean orphan Live Activity tokens
                const inactive = await db.session.findMany({
                    where: { active: false, lastActiveAt: { lt: fourHoursAgo } },
                    select: { id: true },
                });
                const ids = inactive.map(s => s.id);
                const tokensDeleted = await db.liveActivityToken.deleteMany({
                    where: { sessionId: { in: ids } },
                });
                if (tokensDeleted.count > 0) {
                    console.log(`[Auto-cleanup] Deleted ${tokensDeleted.count} orphan Live Activity tokens`);
                }
            }

            // Purge messages older than 5 days
            const fiveDaysAgo = new Date(Date.now() - 5 * 24 * 60 * 60 * 1000);
            const purged = await db.sessionMessage.deleteMany({
                where: { createdAt: { lt: fiveDaysAgo } },
            });
            if (purged.count > 0) {
                console.log(`[Auto-cleanup] Purged ${purged.count} messages older than 5 days`);
            }
        } catch (err) {
            console.error('[Auto-cleanup] Error:', err);
        }
    }, 60 * 60 * 1000); // Run every hour
    console.log('Auto-cleanup scheduled (hourly, 4h threshold)');

    // Subscription cleanup: expire trials + send day-2 notifications (every 30 min)
    if (config.enforceSubscription) {
        setInterval(async () => {
            try {
                // 1. Expire stale trials
                await expireStaleTrials();

                // 2. Send push notifications to devices whose trial expires within 24h
                const expiring = await findExpiringTrials();
                let notifyFailed = 0;
                for (const device of expiring) {
                    try {
                        await sendTrialExpiryNotification(device.id);
                    } catch (err) {
                        notifyFailed++;
                        console.error(`[subscription-cleanup] Failed to notify ${device.id}:`, err);
                    }
                }
                if (expiring.length > 0) {
                    console.log(`[subscription-cleanup] Trial expiry: ${expiring.length} devices, ${notifyFailed} failed`);
                }
            } catch (err) {
                console.error('[subscription-cleanup] Error:', err);
            }
        }, 30 * 60 * 1000); // Every 30 minutes
        console.log('Subscription cleanup scheduled (every 30 min)');
    }

    const shutdown = async () => {
        console.log('Shutting down...');
        await app.close();
        await db.$disconnect();
        process.exit(0);
    };

    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);
    process.on('uncaughtException', (err) => {
        console.error('Uncaught exception:', err);
        process.exit(1);
    });
}

main().catch((err) => {
    console.error('Failed to start:', err);
    process.exit(1);
});
