import { signCapability, verifyCapability } from './signed-capabilities.js';

function claims(operationId, expires) {
    return ['mux-original-read-v1', operationId, expires];
}

export function signMuxOriginalRead(secret, operationId, expires) {
    return signCapability(secret, claims(operationId, expires));
}

export function verifyMuxOriginalRead(secret, operationId, expires, signature) {
    return verifyCapability(secret, claims(operationId, expires), signature);
}
