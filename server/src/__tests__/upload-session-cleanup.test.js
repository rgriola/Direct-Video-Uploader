import Fastify from 'fastify';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { getUploadSessionCleanupConfig } from '../lib/upload-session-cleanup-config.js';
import { createMonitoringService } from '../lib/monitoring.js';
import { createMonitoringAlerts } from '../lib/monitoring-alerts.js';
import {
    scheduleUploadSessionCleanup, startUploadSessionCleanup,
} from '../jobs/upload-session-cleanup.js';

const cleanCycle = { sessions: { failed: 0, scanComplete: true } };

afterEach(() => {
    vi.useRealTimers();
});

describe('upload session cleanup configuration', () => {
    it('is independently opt-in and requires an explicit local root', () => {
        expect(getUploadSessionCleanupConfig({})).toEqual({ enabled: false });
        expect(getUploadSessionCleanupConfig({ UPLOAD_SESSION_CLEANUP_ENABLED: 'false' }))
            .toEqual({ enabled: false });
        expect(() => getUploadSessionCleanupConfig({ UPLOAD_SESSION_CLEANUP_ENABLED: 'yes' }))
            .toThrow(/true or false/);
        expect(() => getUploadSessionCleanupConfig({ UPLOAD_SESSION_CLEANUP_ENABLED: 'true' }))
            .toThrow(/STORAGE_LOCAL_ROOT/);
        expect(() => getUploadSessionCleanupConfig({
            UPLOAD_SESSION_CLEANUP_ENABLED: 'true', STORAGE_LOCAL_ROOT: 'relative/path',
        })).toThrow(/absolute path/);
        expect(() => getUploadSessionCleanupConfig({
            UPLOAD_SESSION_CLEANUP_ENABLED: 'true', STORAGE_LOCAL_ROOT: '/tmp/originals', STORAGE_DRIVER: 's3',
        })).toThrow(/local storage driver/);
        expect(getUploadSessionCleanupConfig({
            UPLOAD_SESSION_CLEANUP_ENABLED: 'true',
            UPLOAD_SESSIONS_ENABLED: 'false',
            STORAGE_LOCAL_ROOT: '/tmp/originals',
        })).toEqual({ enabled: true, storageRoot: '/tmp/originals' });
    });

    it('does not start a worker when disabled', async () => {
        expect(() => startUploadSessionCleanup({}, {})).toThrow(/explicit configuration/);
        const stop = startUploadSessionCleanup({}, { config: { enabled: false } });
        await expect(stop()).resolves.toBeUndefined();
    });
});

describe('upload session cleanup scheduler', () => {
    it('does not overlap cycles and waits for active work before stopping', async () => {
        vi.useFakeTimers();
        let finish;
        const pending = new Promise(resolve => { finish = resolve; });
        const worker = { runOnce: vi.fn(() => pending), close: vi.fn(async () => {}) };
        const log = { info: vi.fn(), error: vi.fn() };
        const stop = scheduleUploadSessionCleanup({ worker, log, intervalMs: 100 });

        await vi.advanceTimersByTimeAsync(0);
        await vi.advanceTimersByTimeAsync(300);
        expect(worker.runOnce).toHaveBeenCalledTimes(1);

        const stopping = stop();
        expect(worker.close).not.toHaveBeenCalled();
        finish(cleanCycle);
        await stopping;
        expect(worker.close).toHaveBeenCalledTimes(1);
        await vi.advanceTimersByTimeAsync(300);
        expect(worker.runOnce).toHaveBeenCalledTimes(1);
        await stop();
        expect(worker.close).toHaveBeenCalledTimes(1);
    });

    it('reports a failed cycle and retries at the next interval', async () => {
        vi.useFakeTimers();
        const worker = {
            runOnce: vi.fn()
                .mockRejectedValueOnce(new AggregateError([new Error('database unavailable')], 'cycle failed'))
                .mockResolvedValueOnce(cleanCycle),
            close: vi.fn(async () => {}),
        };
        const log = { info: vi.fn(), error: vi.fn() };
        const stop = scheduleUploadSessionCleanup({ worker, log, intervalMs: 100 });

        await vi.advanceTimersByTimeAsync(0);
        expect(log.error).toHaveBeenCalledWith(
            { err: { name: 'AggregateError', message: 'cycle failed: database unavailable' } },
            'Upload session cleanup cycle failed',
        );
        await vi.advanceTimersByTimeAsync(100);
        expect(worker.runOnce).toHaveBeenCalledTimes(2);
        await stop();
    });

    it('preserves underlying failures through Fastify error serialization', async () => {
        vi.useFakeTimers();
        const entries = [];
        const fastify = Fastify({
            logger: {
                stream: { write: entry => entries.push(JSON.parse(entry)) },
                serializers: { err: error => ({ message: error.message }) },
            },
        });
        const failure = Object.assign(new Error('root unavailable'), { code: 'STORAGE_UNAVAILABLE' });
        const worker = {
            runOnce: vi.fn().mockRejectedValue(new AggregateError([failure], 'inventory failed')),
            close: vi.fn(async () => {}),
        };
        const stop = scheduleUploadSessionCleanup({ worker, log: fastify.log, intervalMs: 100 });
        await vi.advanceTimersByTimeAsync(0);
        expect(entries.find(entry => entry.msg === 'Upload session cleanup cycle failed').err.message)
            .toBe('inventory failed: root unavailable [STORAGE_UNAVAILABLE]');
        await stop();
        await fastify.close();
    });

    it('reports per-session failures until a full clean scan confirms recovery', async () => {
        vi.useFakeTimers();
        const worker = {
            runOnce: vi.fn()
                .mockResolvedValueOnce({ sessions: { failed: 1, scanComplete: false } })
                .mockResolvedValueOnce({ sessions: { failed: 0, scanComplete: false } })
                .mockResolvedValueOnce(cleanCycle)
                .mockResolvedValueOnce(cleanCycle),
            close: vi.fn(async () => {}),
        };
        const monitoring = createMonitoringService({ clock: () => new Date() });
        const stop = scheduleUploadSessionCleanup({
            worker, monitoring, log: { info: vi.fn(), error: vi.fn() }, intervalMs: 100,
        });
        const status = async () => {
            await monitoring.runOnce();
            return monitoring.snapshot().checks.find(check => check.id === 'original-upload-cleanup').status;
        };

        await vi.advanceTimersByTimeAsync(0);
        expect(await status()).toBe('critical');
        await vi.advanceTimersByTimeAsync(100);
        expect(await status()).toBe('critical');
        await vi.advanceTimersByTimeAsync(100);
        expect(await status()).toBe('critical');
        await vi.advanceTimersByTimeAsync(100);
        expect(await status()).toBe('ok');
        await stop();
    });

    it('reports a stalled cycle and recovers when it finishes', async () => {
        vi.useFakeTimers();
        let finish;
        const pending = new Promise(resolve => { finish = resolve; });
        const worker = {
            runOnce: vi.fn().mockResolvedValueOnce(cleanCycle).mockImplementationOnce(() => pending),
            close: vi.fn(async () => {}),
        };
        const monitoring = createMonitoringService({ clock: () => new Date() });
        const stop = scheduleUploadSessionCleanup({
            worker, monitoring, log: { info: vi.fn(), error: vi.fn() }, intervalMs: 100,
        });

        await vi.advanceTimersByTimeAsync(0);
        await monitoring.runOnce();
        expect(monitoring.snapshot().checks[0].status).toBe('ok');
        await vi.advanceTimersByTimeAsync(300);
        await monitoring.runOnce();
        expect(monitoring.snapshot().checks[0]).toMatchObject({
            status: 'critical', message: expect.stringContaining('freshness'),
        });
        finish(cleanCycle);
        await vi.advanceTimersByTimeAsync(0);
        await monitoring.runOnce();
        expect(monitoring.snapshot().checks[0].status).toBe('ok');
        await stop();
    });

    it('sends configured alerts for cycle failures and confirmed recovery', async () => {
        vi.useFakeTimers();
        const worker = {
            runOnce: vi.fn().mockRejectedValueOnce(new Error('database unavailable'))
                .mockResolvedValue(cleanCycle),
            close: vi.fn(async () => {}),
        };
        const monitoring = createMonitoringService({ clock: () => new Date() });
        const send = vi.fn(async () => ({ ok: true }));
        const alerts = createMonitoringAlerts({ send, repeatMs: 60_000 });
        monitoring.registerCheck(alerts.check);
        monitoring.subscribe(alerts.notify);
        const stop = scheduleUploadSessionCleanup({
            worker, monitoring, log: { info: vi.fn(), error: vi.fn() }, intervalMs: 100,
        });

        await vi.advanceTimersByTimeAsync(0);
        await monitoring.runOnce();
        expect(send).toHaveBeenCalledWith(expect.stringContaining('*Original upload cleanup*: CRITICAL'));
        await vi.advanceTimersByTimeAsync(100);
        await monitoring.runOnce();
        expect(send).toHaveBeenCalledTimes(1);
        await vi.advanceTimersByTimeAsync(100);
        await monitoring.runOnce();
        expect(send).toHaveBeenLastCalledWith(expect.stringContaining('*Original upload cleanup*: recovered'));
        await stop();
    });

    it('does not report a healthy initial cycle before it finishes', async () => {
        vi.useFakeTimers();
        let finish;
        const worker = {
            runOnce: vi.fn(() => new Promise(resolve => { finish = resolve; })),
            close: vi.fn(async () => {}),
        };
        const monitoring = createMonitoringService({ clock: () => new Date() });
        const stop = scheduleUploadSessionCleanup({
            worker, monitoring, log: { info: vi.fn(), error: vi.fn() }, intervalMs: 100,
        });
        const firstCheck = monitoring.runOnce();

        await vi.advanceTimersByTimeAsync(0);
        expect(monitoring.snapshot().checkedAt).toBeNull();
        finish(cleanCycle);
        await firstCheck;
        expect(monitoring.snapshot().checks[0].status).toBe('ok');
        await stop();
    });

    it('reports the first cycle as stale if it never finishes', async () => {
        vi.useFakeTimers();
        let finish;
        const worker = {
            runOnce: vi.fn(() => new Promise(resolve => { finish = resolve; })),
            close: vi.fn(async () => {}),
        };
        const monitoring = createMonitoringService({ clock: () => new Date() });
        const stop = scheduleUploadSessionCleanup({
            worker, monitoring, log: { info: vi.fn(), error: vi.fn() }, intervalMs: 100,
        });
        const firstCheck = monitoring.runOnce();

        await vi.advanceTimersByTimeAsync(300);
        await firstCheck;
        expect(monitoring.snapshot().checks[0]).toMatchObject({
            status: 'critical', message: expect.stringContaining('freshness'),
        });
        finish(cleanCycle);
        await vi.advanceTimersByTimeAsync(0);
        await monitoring.runOnce();
        expect(monitoring.snapshot().checks[0].status).toBe('ok');
        await stop();
    });

    it('surfaces an initial check timeout before the stale threshold', async () => {
        vi.useFakeTimers();
        let finish;
        const worker = {
            runOnce: vi.fn(() => new Promise(resolve => { finish = resolve; })),
            close: vi.fn(async () => {}),
        };
        const monitoring = createMonitoringService({ clock: () => new Date(), timeoutMs: 100 });
        const stop = scheduleUploadSessionCleanup({
            worker, monitoring, log: { info: vi.fn(), error: vi.fn() }, intervalMs: 1_000,
        });
        const firstCheck = monitoring.runOnce();

        await vi.advanceTimersByTimeAsync(100);
        await firstCheck;
        expect(monitoring.snapshot().checks[0].status).toBe('unknown');
        await vi.advanceTimersByTimeAsync(2_900);
        await monitoring.runOnce();
        expect(monitoring.snapshot().checks[0].status).toBe('critical');
        finish(cleanCycle);
        await vi.advanceTimersByTimeAsync(0);
        await monitoring.runOnce();
        expect(monitoring.snapshot().checks[0].status).toBe('ok');
        await stop();
    });
});
