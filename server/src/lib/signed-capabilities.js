import { createHmac, timingSafeEqual } from 'node:crypto';

export function signCapability(secret, claims) {
    return createHmac('sha256', secret).update(claims.join('\n')).digest('hex');
}

export function verifyCapability(secret, claims, signature) {
    if (typeof signature !== 'string' || !/^[a-f0-9]{64}$/.test(signature)) return false;
    const expected = Buffer.from(signCapability(secret, claims), 'hex');
    return timingSafeEqual(expected, Buffer.from(signature, 'hex'));
}
