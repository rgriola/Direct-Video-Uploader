import { UploadSessionError } from './upload-sessions.js';
import { StorageError } from './storage/local-driver.js';

const ERROR_STATUS = {
    INVALID_ARGUMENT: 400,
    NOT_FOUND: 404,
    EXPIRED: 410,
    ACCOUNT_SUSPENDED: 403,
    ASSET_NOT_ACTIVE: 409,
    INVALID_STATE: 409,
    CLIP_CHANGED: 409,
    SESSION_EXISTS: 409,
    SESSION_BUSY: 409,
    INCOMPLETE_UPLOAD: 409,
    INTEGRITY_MISMATCH: 422,
    STORAGE_UNAVAILABLE: 503,
    STORAGE_CHANGED: 503,
    STORAGE_CAPACITY_EXCEEDED: 507,
    PART_CONFLICT: 409,
    PART_SIZE_MISMATCH: 400,
    PART_TOO_LARGE: 413,
    IDEMPOTENCY_CONFLICT: 409,
    INTENT_CANCELLED: 410,
    INTENT_REMOVED: 410,
    INTENT_INCONSISTENT: 503,
};

export async function handleErrors(reply, work, { closeConnection = false } = {}) {
    try {
        return await work();
    } catch (error) {
        if ((error instanceof UploadSessionError || error instanceof StorageError) && ERROR_STATUS[error.code]) {
            if (error.code === 'STORAGE_UNAVAILABLE' || error.code === 'STORAGE_CHANGED') {
                reply.request.log.error({ err: { message: error.message } }, 'Original storage is unavailable');
            }
            if (error.code === 'STORAGE_CAPACITY_EXCEEDED') {
                reply.request.log.warn({ code: error.code }, 'Original storage capacity is insufficient');
            }
            if (error.code === 'INTENT_INCONSISTENT') {
                reply.request.log.error({ code: error.code }, 'Original upload intent is inconsistent');
            }
            if (closeConnection) reply.header('Connection', 'close');
            return reply.status(ERROR_STATUS[error.code]).send({ error: error.message });
        }
        if (error?.code === 'ENOSPC' || error?.code === 'EDQUOT') {
            reply.request.log.error({ code: error.code }, 'Original storage write failed for lack of space');
            if (closeConnection) reply.header('Connection', 'close');
            return reply.status(507).send({ error: 'Original storage has insufficient free space' });
        }
        throw error;
    }
}
