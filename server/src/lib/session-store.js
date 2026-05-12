// Last updated: May 12, 2026 - 3:05pm - GitHub Copilot (GPT-5.3-Codex)
import redis from './redis.js';

export const SESSION_TTL_SECONDS = 7 * 24 * 60 * 60;

function sessionKey(jti) {
    return `auth:jti:${jti}`;
}

function userSessionsKey(userId) {
    return `auth:user:${userId}:jtis`;
}

export async function createSession({ userId, jti, ttlSeconds = SESSION_TTL_SECONDS }) {
    if (!userId || !jti) {
        throw new Error('createSession requires userId and jti');
    }

    const ttl = Number(ttlSeconds);
    if (!Number.isFinite(ttl) || ttl <= 0) {
        throw new Error('createSession requires a positive ttlSeconds');
    }

    await redis.set(sessionKey(jti), String(userId), 'EX', ttl);
    await redis.sadd(userSessionsKey(userId), jti);
    await redis.expire(userSessionsKey(userId), ttl);
}

export async function hasSession(jti) {
    if (!jti) return false;
    const value = await redis.get(sessionKey(jti));
    return typeof value === 'string' && value.length > 0;
}

export async function deleteSession({ userId, jti }) {
    if (!jti) return 0;

    const deleted = await redis.del(sessionKey(jti));
    if (userId) {
        await redis.srem(userSessionsKey(userId), jti);
    }

    return deleted;
}

export async function revokeUserSessions(userId) {
    if (!userId) return 0;

    const key = userSessionsKey(userId);
    const jtis = await redis.smembers(key);
    if (jtis.length === 0) {
        await redis.del(key);
        return 0;
    }

    const sessionKeys = jtis.map((jti) => sessionKey(jti));
    await redis.del(...sessionKeys);
    await redis.del(key);

    return jtis.length;
}
