import { describe, expect, it } from 'vitest';
import { getAssetUploadMode, serializeCreatedAsset } from '../lib/asset-serialization.js';
import { cleanupEligibleUploadModes } from '../lib/upload-intents.js';
import { SESSION_TTL_MS } from '../lib/upload-sessions.js';

describe('asset upload mode discovery', () => {
    it.each([
        [{}, 'UNKNOWN'],
        [{ uploadMode: 'ORIGINAL' }, 'ORIGINAL'],
        [{ uploadMode: 'MUX' }, 'MUX'],
        [{ uploadSessions: [{ id: 'legacy-session' }] }, 'ORIGINAL'],
        [{ clips: [{ storageKey: 'retained-original' }] }, 'ORIGINAL'],
        [{ clips: [{ muxUploadId: 'legacy-upload' }] }, 'MUX'],
        [{ uploadMode: 'MUX', uploadSessions: [{ id: 'session' }] }, 'UNKNOWN'],
        [{ uploadMode: 'ORIGINAL', clips: [{ muxUploadId: 'upload' }] }, 'UNKNOWN'],
        [{ clips: [{ storageKey: 'retained-original', muxUploadId: 'legacy-upload' }] }, 'UNKNOWN'],
    ])('reports %s as %s', (asset, expected) => {
        expect(getAssetUploadMode(asset)).toBe(expected);
    });

    it('does not expose intent or storage records in a created asset', () => {
        const asset = {
            id: 'asset-1', uploadMode: 'ORIGINAL',
            clientRequestId: 'private-id', storageKey: 'private-key',
        };
        expect(serializeCreatedAsset(asset)).toMatchObject({ id: 'asset-1', uploadMode: 'ORIGINAL' });
        expect(serializeCreatedAsset(asset)).not.toHaveProperty('clientRequestId');
        expect(serializeCreatedAsset(asset)).not.toHaveProperty('storageKey');
    });

    it('treats a retained original outside the selected clip as conflicting with Mux mode', () => {
        expect(getAssetUploadMode({ uploadMode: 'MUX' }, { hasStoredOriginal: true })).toBe('UNKNOWN');
        expect(getAssetUploadMode({ uploadMode: 'ORIGINAL' }, { hasMuxUpload: true })).toBe('UNKNOWN');
    });
});

describe('original intent cleanup eligibility', () => {
    it('uses the exact session lifetime for an original asset without a session', () => {
        const now = 2_000_000_000_000;
        expect(SESSION_TTL_MS).toBe(24 * 60 * 60 * 1000);
        expect(cleanupEligibleUploadModes(now)).toEqual({
            OR: [
                { uploadMode: null },
                { uploadMode: 'MUX' },
                { uploadMode: 'ORIGINAL', createdAt: { lt: new Date(now - 24 * 60 * 60 * 1000) } },
            ],
        });
    });
});
