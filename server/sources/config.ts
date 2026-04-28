export const config = {
    port: parseInt(process.env.PORT || '3005', 10),
    masterSecret: process.env.MASTER_SECRET || '',
    databaseUrl: process.env.DATABASE_URL || '',
    tokenExpiryDays: parseInt(process.env.TOKEN_EXPIRY_DAYS || '30', 10),
    // Subscription / trial
    trialDays: parseInt(process.env.TRIAL_DAYS || '3', 10),
    maxConcurrentDevices: parseInt(process.env.MAX_CONCURRENT_DEVICES || '1', 10),
    enforceSubscription: process.env.ENFORCE_SUBSCRIPTION !== 'false', // default true
    // Apple App Store Server API (用于验证 transactionId 真实性)
    appleApiKeyId: process.env.APPLE_API_KEY_ID || '',
    appleApiIssuerId: process.env.APPLE_API_ISSUER_ID || '',
    appleApiPrivateKey: process.env.APPLE_API_PRIVATE_KEY || '', // base64-encoded .p8
    // 退款回调共享密钥（防伪造）
    revokeSharedSecret: process.env.REVOKE_SHARED_SECRET || '',
} as const;
