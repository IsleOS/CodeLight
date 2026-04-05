import { db } from '@/storage/db';
import { startApi } from '@/api';
import { startSocket } from '@/socket/socketServer';
import { config } from '@/config';

async function main() {
    if (!config.masterSecret || config.masterSecret === 'change-me-to-a-random-string') {
        console.error('MASTER_SECRET must be set');
        process.exit(1);
    }

    await db.$connect();
    console.log('Database connected');

    const app = await startApi();

    startSocket(app.server);
    console.log('Socket.io ready on /v1/updates');

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
