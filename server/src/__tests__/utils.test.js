// Last updated: May 9, 2026 - 6:55pm - GPT-5.3-Codex
import crypto from 'crypto';
import { describe, expect, it, vi } from 'vitest';
import {
    dbRetry,
    generateMediasourceId,
    hashPin,
    hashPinLegacy,
    notifyUserSockets,
    parseClientMetadata,
    serializeClip,
    verifyPin,
} from '../lib/utils.js';

describe('lib/utils', () => {
    it('hashes and verifies bcrypt pins', async () => {
        const hash = await hashPin('1234');

        expect(hash.startsWith('$2')).toBe(true);
        await expect(verifyPin('1234', hash)).resolves.toBe(true);
        await expect(verifyPin('9999', hash)).resolves.toBe(false);
    });

    it('verifies legacy SHA-256 pin hashes', async () => {
        const legacyHash = crypto.createHash('sha256').update('1234').digest('hex');

        expect(hashPinLegacy('1234')).toBe(legacyHash);
        await expect(verifyPin('1234', legacyHash)).resolves.toBe(true);
        await expect(verifyPin('0000', legacyHash)).resolves.toBe(false);
    });

    it('generates mediasource id from sequence when db calls succeed', async () => {
        const prismaClient = {
            $executeRawUnsafe: vi.fn().mockResolvedValue(undefined),
            $queryRawUnsafe: vi.fn().mockResolvedValue([{ val: 100000001n }]),
        };

        const id = await generateMediasourceId(prismaClient);

        expect(id).toBe('100000001');
        expect(prismaClient.$executeRawUnsafe).toHaveBeenCalledOnce();
        expect(prismaClient.$queryRawUnsafe).toHaveBeenCalledOnce();
    });

    it('falls back to random mediasource id when db calls fail', async () => {
        const prismaClient = {
            $executeRawUnsafe: vi.fn().mockRejectedValue(new Error('db unavailable')),
            $queryRawUnsafe: vi.fn(),
        };

        const id = await generateMediasourceId(prismaClient);

        expect(id).toMatch(/^\d{9}$/);
        expect(prismaClient.$queryRawUnsafe).not.toHaveBeenCalled();
    });

    it('retries timeout errors in dbRetry', async () => {
        const fn = vi
            .fn()
            .mockRejectedValueOnce(new Error('connection timeout while waiting'))
            .mockResolvedValueOnce('ok');

        const result = await dbRetry(fn, 1);

        expect(result).toBe('ok');
        expect(fn).toHaveBeenCalledTimes(2);
    });

    it('does not retry non-timeout errors in dbRetry', async () => {
        const fn = vi.fn().mockRejectedValue(new Error('validation failed'));

        await expect(dbRetry(fn, 2)).rejects.toThrow('validation failed');
        expect(fn).toHaveBeenCalledTimes(1);
    });

    it('parses client metadata with defaults and coercion', () => {
        const parsed = parseClientMetadata({
            gpsLat: '35.09',
            gpsLon: '-106.61',
            gpsAltitude: '1600.5',
            capturedAt: '2026-05-09T18:00:00.000Z',
            duration: '42',
            deviceModel: 'iPhone Test',
            osVersion: 'iOS Test',
            codec: 'H264',
            resolution: '1920x1080',
            orientation: 'portrait',
        });

        expect(parsed.gpsLat).toBeCloseTo(35.09);
        expect(parsed.gpsLon).toBeCloseTo(-106.61);
        expect(parsed.gpsAltitude).toBeCloseTo(1600.5);
        expect(parsed.duration).toBe(42);
        expect(parsed.deviceModel).toBe('iPhone Test');
        expect(parsed.osVersion).toBe('iOS Test');
        expect(parsed.codec).toBe('H264');
        expect(parsed.resolution).toBe('1920x1080');
        expect(parsed.orientation).toBe('portrait');
        expect(parsed.capturedAt).toBeInstanceOf(Date);

        const defaults = parseClientMetadata();
        expect(defaults.deviceModel).toBe('Unknown Device');
        expect(defaults.osVersion).toBe('Unknown OS');
        expect(defaults.codec).toBe('Unknown');
        expect(defaults.resolution).toBe('Unknown');
        expect(defaults.orientation).toBe('landscape');
        expect(defaults.duration).toBe(0);
        expect(defaults.capturedAt).toBeInstanceOf(Date);
    });

    it('serializes BigInt clip file size to string', () => {
        const clip = {
            id: 'clip-1',
            fileSize: 123456789n,
        };

        expect(serializeClip(clip)).toEqual({
            id: 'clip-1',
            fileSize: '123456789',
        });
        expect(serializeClip({ id: 'clip-2', fileSize: null }).fileSize).toBeNull();
    });

    it('emits upload complete and form request events to the owner room', () => {
        const emitted = [];
        const io = {
            to: vi.fn((socketId) => ({
                emit: vi.fn((event, payload) => {
                    emitted.push({ socketId, event, payload });
                }),
            })),
        };

        const capturedAt = new Date('2026-05-09T18:00:00.000Z');
        notifyUserSockets(io, 'user-1', {
            assetId: 'asset-1',
            asset: {
                mediasourceId: '123456789',
                mediasourceUrl: 'https://example.com/clip',
                originalFileName: 'video.mov',
            },
            userName: 'Test User',
            metadata: {
                gpsLat: 35.09,
                codec: 'H264',
                deviceModel: 'iPhone',
                capturedAt,
                duration: 42,
            },
            clip: {
                id: 'clip-1',
                storageUrl: '/tmp/video.mov',
                fileSize: 100,
            },
            messageText: 'ignored by helper',
        });

        expect(io.to).toHaveBeenCalledOnce();
        expect(io.to).toHaveBeenCalledWith('user:user-1');
        expect(emitted).toHaveLength(2);
        expect(emitted.filter((e) => e.event === 'upload:complete')).toHaveLength(1);
        expect(emitted.filter((e) => e.event === 'form:request')).toHaveLength(1);

        const formRequest = emitted.find((e) => e.event === 'form:request');
        expect(formRequest.payload.assetId).toBe('asset-1');
        expect(formRequest.payload.capturedAt).toBe(capturedAt);
    });

});
