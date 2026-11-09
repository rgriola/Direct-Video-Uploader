import { createHmac, timingSafeEqual } from 'node:crypto';

function digest(secret, { ownerId, sessionId, partNumber, sizeBytes, expires }) {
    return createHmac('sha256', secret)
        .update(['upload-part-v1', ownerId, sessionId, partNumber, sizeBytes, expires].join('\n'))
        .digest('hex');
}

export function signUploadPart(secret, claims) {
    return digest(secret, claims);
}

export function verifyUploadPart(secret, claims, signature) {
    if (typeof signature !== 'string' || !/^[a-f0-9]{64}$/.test(signature)) return false;
    const expected = Buffer.from(digest(secret, claims), 'hex');
    return timingSafeEqual(expected, Buffer.from(signature, 'hex'));
}
