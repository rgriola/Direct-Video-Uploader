// Last updated: May 12, 2026 - 4:39pm - GitHub Copilot (GPT-5.3-Codex)
import Redis from 'ioredis';

const REDIS_URL = process.env.REDIS_URL?.trim() || '';

class InMemoryRedisShim {
    constructor() {
        this.store = new Map();
        this.timers = new Map();
    }

    clearTimer(key) {
        const timer = this.timers.get(key);
        if (timer) {
            clearTimeout(timer);
            this.timers.delete(key);
        }
    }

    async ping() {
        return 'PONG';
    }

    async get(key) {
        if (!this.store.has(key)) {
            return null;
        }

        const value = this.store.get(key);
        return value instanceof Set ? null : value;
    }

    async set(key, value, ttlMode, ttlValue) {
        this.store.set(key, String(value));

        this.clearTimer(key);

        if (typeof ttlMode === 'string' && ttlMode.toUpperCase() === 'EX') {
            const ttlSeconds = Number(ttlValue);
            if (Number.isFinite(ttlSeconds) && ttlSeconds > 0) {
                const timer = setTimeout(() => {
                    this.store.delete(key);
                    this.timers.delete(key);
                }, ttlSeconds * 1000);
                this.timers.set(key, timer);
            }
        }

        return 'OK';
    }

    async del(...keys) {
        let removed = 0;
        for (const key of keys) {
            if (this.store.has(key)) {
                removed += 1;
                this.store.delete(key);
            }
            this.clearTimer(key);
        }
        return removed;
    }

    async sadd(key, ...members) {
        let set = this.store.get(key);
        if (!(set instanceof Set)) {
            set = new Set();
            this.store.set(key, set);
        }

        let added = 0;
        for (const member of members) {
            const normalized = String(member);
            if (!set.has(normalized)) {
                set.add(normalized);
                added += 1;
            }
        }

        return added;
    }

    async smembers(key) {
        const set = this.store.get(key);
        if (!(set instanceof Set)) {
            return [];
        }

        return [...set.values()];
    }

    async srem(key, ...members) {
        const set = this.store.get(key);
        if (!(set instanceof Set)) {
            return 0;
        }

        let removed = 0;
        for (const member of members) {
            if (set.delete(String(member))) {
                removed += 1;
            }
        }

        if (set.size === 0) {
            this.store.delete(key);
            this.clearTimer(key);
        }

        return removed;
    }

    async expire(key, ttlSeconds) {
        if (!this.store.has(key)) {
            return 0;
        }

        const seconds = Number(ttlSeconds);
        if (!Number.isFinite(seconds) || seconds <= 0) {
            return 0;
        }

        this.clearTimer(key);
        const timer = setTimeout(() => {
            this.store.delete(key);
            this.timers.delete(key);
        }, seconds * 1000);
        this.timers.set(key, timer);
        return 1;
    }

    async quit() {
        for (const timer of this.timers.values()) {
            clearTimeout(timer);
        }
        this.timers.clear();
        this.store.clear();
        return 'OK';
    }

    on() {
        return this;
    }
}

export const isRedisConfigured = REDIS_URL.length > 0;
export const redisMode = isRedisConfigured ? 'redis' : 'memory';

const redisOptions = {
    maxRetriesPerRequest: null,
    enableReadyCheck: true,
    retryStrategy(attempts) {
        return Math.min(attempts * 200, 2000);
    },
};

if (REDIS_URL.startsWith('rediss://')) {
    redisOptions.tls = {};
}

export const redis = isRedisConfigured
    ? new Redis(REDIS_URL, redisOptions)
    : new InMemoryRedisShim();

if (isRedisConfigured) {
    redis.on('error', (err) => {
        console.error({
            event: 'redis.client.error',
            message: err.message,
        });
    });
}

export async function closeRedis() {
    if (typeof redis.quit === 'function') {
        await redis.quit();
    }
}

export default redis;
