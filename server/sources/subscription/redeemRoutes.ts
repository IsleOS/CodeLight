import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { authMiddleware } from '@/auth/middleware';
import { db } from '@/storage/db';
import { eventRouter } from '@/socket/socketServer';
import { config } from '@/config';

// In-memory rate limiter for redeem attempts: max 10 failed attempts per device per hour.
// Prevents brute-force guessing of FREE-XXXXXXXX codes.
const redeemFailures = new Map<string, { count: number; resetAt: number }>();

function isRateLimited(deviceId: string): boolean {
    const now = Date.now();
    const entry = redeemFailures.get(deviceId);
    if (!entry || entry.resetAt < now) return false;
    return entry.count >= 10;
}

function recordFailure(deviceId: string): void {
    const now = Date.now();
    const entry = redeemFailures.get(deviceId);
    if (!entry || entry.resetAt < now) {
        redeemFailures.set(deviceId, { count: 1, resetAt: now + 60 * 60 * 1000 });
    } else {
        entry.count++;
    }
}

function clearFailures(deviceId: string): void {
    redeemFailures.delete(deviceId);
}

export async function redeemRoutes(app: FastifyInstance) {
    // ─────────────────────────────────────────────────────────────────────
    // Redeem a promotional code for free access
    // ─────────────────────────────────────────────────────────────────────
    app.post('/v1/subscription/redeem', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                code: z.string().min(1).max(50),
            }),
        },
    }, async (request, reply) => {
        const { code } = request.body as { code: string };
        const deviceId = request.deviceId!;
        const normalized = code.trim().toUpperCase();

        if (isRateLimited(deviceId)) {
            return reply.code(429).send({ error: 'rate_limited', message: 'Too many failed attempts. Try again in an hour.' });
        }

        // 查找兑换码
        const redeemCode = await db.redeemCode.findUnique({
            where: { code: normalized },
        });

        if (!redeemCode) {
            recordFailure(deviceId);
            return reply.code(404).send({ error: 'invalid_code', message: 'Invalid redeem code' });
        }

        // 检查码是否过期
        if (redeemCode.expiresAt && redeemCode.expiresAt < new Date()) {
            return reply.code(410).send({ error: 'code_expired', message: 'This code has expired' });
        }

        // 检查该设备是否已用过这个码
        const existingUsage = await db.redeemCodeUsage.findUnique({
            where: {
                redeemCodeId_deviceId: {
                    redeemCodeId: redeemCode.id,
                    deviceId,
                },
            },
        });

        if (existingUsage) {
            return reply.code(409).send({ error: 'already_redeemed', message: 'You have already redeemed this code' });
        }

        // 计算授权到期时间
        const grantedUntil = new Date(Date.now() + redeemCode.durationDays * 24 * 60 * 60 * 1000);

        // 在事务内做 usedCount 检查 + 递增，防止并发超额兑换
        try {
            await db.$transaction(async (tx) => {
                const freshCode = await tx.redeemCode.findUnique({
                    where: { id: redeemCode.id },
                    select: { usedCount: true, maxUses: true },
                });
                if (!freshCode || freshCode.usedCount >= freshCode.maxUses) {
                    throw Object.assign(new Error('code_exhausted'), { code: 'code_exhausted' });
                }

                await tx.redeemCodeUsage.create({
                    data: { redeemCodeId: redeemCode.id, deviceId, grantedUntil },
                });
                await tx.redeemCode.update({
                    where: { id: redeemCode.id },
                    data: { usedCount: { increment: 1 } },
                });
                await tx.device.update({
                    where: { id: deviceId },
                    data: {
                        subscriptionStatus: 'active',
                        trialExpiresAt: grantedUntil,
                    },
                });
            });
        } catch (err: any) {
            if (err?.code === 'code_exhausted') {
                return reply.code(410).send({ error: 'code_exhausted', message: 'This code has been fully redeemed' });
            }
            throw err;
        }

        clearFailures(deviceId);

        // 通知连接的 socket
        const daysLeft = Math.ceil((grantedUntil.getTime() - Date.now()) / (24 * 60 * 60 * 1000));
        eventRouter.emitToDevice(deviceId, 'subscription-updated', { status: 'active', daysLeft });

        console.log(`[redeem] Code ${normalized} redeemed by device ${deviceId}, access until ${grantedUntil.toISOString()}`);

        return {
            success: true,
            status: 'active',
            expiresAt: grantedUntil.toISOString(),
            durationDays: redeemCode.durationDays,
        };
    });

    // ─────────────────────────────────────────────────────────────────────
    // Admin: Generate redeem codes (simple shared-secret auth)
    // ─────────────────────────────────────────────────────────────────────
    app.post('/v1/admin/redeem-codes', {
        schema: {
            body: z.object({
                secret: z.string().min(1),
                count: z.number().int().min(1).max(100).default(1),
                durationDays: z.number().int().min(1).max(365).default(30),
                maxUses: z.number().int().min(1).max(1000).default(1),
                note: z.string().optional(),
            }),
        },
    }, async (request, reply) => {
        const { secret, count, durationDays, maxUses, note } = request.body as {
            secret: string;
            count: number;
            durationDays: number;
            maxUses: number;
            note?: string;
        };

        if (!config.revokeSharedSecret || secret !== config.revokeSharedSecret) {
            return reply.code(403).send({ error: 'Unauthorized' });
        }

        const codes: string[] = [];
        for (let i = 0; i < count; i++) {
            // 生成 8 位随机码: FREE-XXXXXXXX
            const random = Array.from({ length: 8 }, () =>
                'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[Math.floor(Math.random() * 32)]
            ).join('');
            const code = `FREE-${random}`;

            await db.redeemCode.create({
                data: {
                    code,
                    durationDays,
                    maxUses,
                    note: note || null,
                    createdBy: 'admin',
                },
            });

            codes.push(code);
        }

        console.log(`[admin] Generated ${count} redeem codes: ${codes.join(', ')}`);

        return { success: true, codes, durationDays, maxUses };
    });
}
