import Fastify from 'fastify';
import { mkdtemp, rmdir, symlink, unlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const prismaMock = { clip: { findMany: vi.fn() } };
vi.mock('../lib/prisma.js', () => ({ default: prismaMock }));

let app;
let root;
const active = {
    asset: { moderation: 'ACTIVE', mediaPlaybackReset: false, mediaCreateOperationId: null },
};

beforeAll(async () => {
    root = await mkdtemp(path.join(os.tmpdir(), 'dvu-local-upload-test-'));
    await writeFile(path.join(root, 'video file.mp4'), 'video-content');
    await symlink(path.join(root, 'video file.mp4'), path.join(root, 'alias.mp4'));
    app = Fastify({ logger: false });
    const { default: localUploadRoutes } = await import('../routes/local-uploads.js');
    await app.register(localUploadRoutes, { root });
});

beforeEach(() => {
    prismaMock.clip.findMany.mockReset();
    prismaMock.clip.findMany.mockResolvedValue([active]);
});

afterAll(async () => {
    await app?.close();
    await unlink(path.join(root, 'alias.mp4'));
    await unlink(path.join(root, 'video file.mp4'));
    await rmdir(root);
});

describe('legacy local upload access', () => {
    it('serves a known active file without caching', async () => {
        const response = await app.inject({ method: 'GET', url: '/uploads/video%20file.mp4' });
        expect(response.statusCode).toBe(200);
        expect(response.body).toBe('video-content');
        expect(response.headers['cache-control']).toBe('no-store');
        expect(prismaMock.clip.findMany).toHaveBeenCalledWith(expect.objectContaining({
            where: { storageUrl: '/uploads/video file.mp4' },
        }));
    });

    it.each([
        ['paused', { ...active.asset, moderation: 'PAUSED' }],
        ['flagged', { ...active.asset, moderation: 'FLAGGED_FOR_REMOVAL' }],
        ['removed', { ...active.asset, moderation: 'REMOVED' }],
        ['playback reset', { ...active.asset, mediaPlaybackReset: true }],
        ['unknown playback creation', { ...active.asset, mediaCreateOperationId: 'operation-1' }],
    ])('blocks %s media even when the file exists', async (_label, asset) => {
        prismaMock.clip.findMany.mockResolvedValueOnce([{ asset }]);
        const response = await app.inject({ method: 'GET', url: '/uploads/video%20file.mp4' });
        expect(response.statusCode).toBe(404);
        expect(response.body).not.toContain('video-content');
    });

    it('blocks unreferenced files and a file shared with a moderated asset', async () => {
        prismaMock.clip.findMany.mockResolvedValueOnce([]);
        expect((await app.inject({ method: 'GET', url: '/uploads/video%20file.mp4' })).statusCode).toBe(404);
        prismaMock.clip.findMany.mockResolvedValueOnce([active, { asset: { ...active.asset, moderation: 'PAUSED' } }]);
        expect((await app.inject({ method: 'GET', url: '/uploads/video%20file.mp4' })).statusCode).toBe(404);
    });

    it('blocks symlink aliases and path traversal', async () => {
        expect((await app.inject({ method: 'GET', url: '/uploads/alias.mp4' })).statusCode).toBe(404);
        const traversal = await app.inject({ method: 'GET', url: '/uploads/%2e%2e/video%20file.mp4' });
        expect([403, 404]).toContain(traversal.statusCode);
    });

    it('fails closed when the database is unavailable', async () => {
        prismaMock.clip.findMany.mockRejectedValueOnce(new Error('database unavailable'));
        const response = await app.inject({ method: 'GET', url: '/uploads/video%20file.mp4' });
        expect(response.statusCode).toBe(500);
        expect(response.body).not.toContain('video-content');
    });
});
