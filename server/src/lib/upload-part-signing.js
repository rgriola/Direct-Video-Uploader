import { signCapability, verifyCapability } from './signed-capabilities.js';

function claims({ ownerId, sessionId, partNumber, sizeBytes, expires }) {
    return ['upload-part-v1', ownerId, sessionId, partNumber, sizeBytes, expires];
}

export function signUploadPart(secret, values) {
    return signCapability(secret, claims(values));
}

export function verifyUploadPart(secret, values, signature) {
    return verifyCapability(secret, claims(values), signature);
}
