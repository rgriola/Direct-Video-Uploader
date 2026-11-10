import { spawnSync } from 'node:child_process';
import { lstat, mkdtemp, mkdir, realpath, rm, symlink, utimes, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
    createMonitoringChecks, createMonitoringService, getMonitoringConfig, monitoringFromEnvironment, spaceStatus,
} from '../lib/monitoring.js';

const SOURCE_ID = '12345678-1234-4234-8234-123456789abc';
const BACKUP_ID = '87654321-4321-4321-8321-cba987654321';
const RUN_ID = 'abcdef01-2345-4567-89ab-cdef01234567';
const HOUR = 60 * 60 * 1000;
const NOW = new Date('2026-03-01T12:00:00.000Z');
const iso = offset => new Date(NOW.getTime() + offset).toISOString();
const log = { error: vi.fn() };
let base;
let env;
let config;

function success(offset = -HOUR) {
    return {
        version: 1,
        lastStartedAt: iso(offset - 1000),
        lastCompletedAt: iso(offset),
        lastSuccessAt: iso(offset),
        lastOutcome: 'success',
        currentRunId: null,
    };
}

async function writeState(id, state) {
    await writeFile(path.join(config.stateDir, `${id}.json`), JSON.stringify(state), { mode: 0o600 });
}

function check(id, options) {
    return createMonitoringChecks(config, () => NOW, options).find(item => item.id === id);
}

beforeEach(async () => {
    base = await realpath(await mkdtemp(path.join(os.tmpdir(), 'dvu-monitoring-')));
    const source = path.join(base, 'source');
    const backup = path.join(base, 'backup');
    const database = path.join(base, 'database');
    const state = path.join(base, 'state');
    await Promise.all([source, backup, database, state].map(directory => mkdir(directory, { mode: 0o700 })));
    await writeFile(path.join(source, '.dvu-storage-id'), SOURCE_ID);
    await writeFile(path.join(backup, '.dvu-original-backup-volume-id'), BACKUP_ID);
    env = {
        DVU_MONITORING_ENABLED: 'true',
        DVU_MONITOR_STATE_DIR: state,
        DVU_MONITOR_SOURCE_VOLUME: base,
        STORAGE_LOCAL_ROOT: source,
        DVU_MONITOR_SOURCE_ID: SOURCE_ID,
        DVU_MONITOR_SOURCE_WARNING_FREE_BYTES: '2',
        DVU_MONITOR_SOURCE_CRITICAL_FREE_BYTES: '1',
        DVU_MONITOR_BACKUP_VOLUME: backup,
        DVU_MONITOR_BACKUP_ID: BACKUP_ID,
        DVU_MONITOR_BACKUP_WARNING_FREE_BYTES: '2',
        DVU_MONITOR_BACKUP_CRITICAL_FREE_BYTES: '1',
        DVU_MONITOR_DATABASE_VOLUME: base,
        DVU_MONITOR_DATABASE_DIR: database,
        DVU_MONITOR_DATABASE_WARNING_FREE_BYTES: '2',
        DVU_MONITOR_DATABASE_CRITICAL_FREE_BYTES: '1',
    };
    config = getMonitoringConfig(env);
    log.error.mockReset();
});

afterEach(async () => {
    vi.useRealTimers();
    await rm(base, { recursive: true, force: true });
});

describe('monitoring configuration and volume checks', () => {
    it('is disabled by default and requires explicit, ordered volume thresholds', () => {
        expect(getMonitoringConfig({})).toEqual({ enabled: false });
        expect(config.originalStaleMs).toBe(3 * HOUR);
        expect(config.databaseLocalStaleMs).toBe(36 * HOUR);
        expect(config.databaseOffsiteStaleMs).toBe(216 * HOUR);
        expect(() => getMonitoringConfig({ ...env, DVU_MONITOR_SOURCE_WARNING_FREE_BYTES: '1' })).toThrow(/warning/);
        expect(() => getMonitoringConfig({ ...env, DVU_MONITOR_DATABASE_DIR: 'relative' })).toThrow(/absolute/);
        expect(() => getMonitoringConfig({ ...env, DVU_MONITOR_BACKUP_ID: 'not-an-id' })).toThrow(/UUID/);
        expect(() => getMonitoringConfig({ ...env, DVU_MONITOR_ORIGINAL_STALE_HOURS: '0' })).toThrow(/positive/);
    });

    it('enforces explicit source budget and free-space thresholds when upload limits exist', () => {
        const limits = { ...env, UPLOAD_STORAGE_MAX_BYTES: '1000', UPLOAD_STORAGE_MIN_FREE_BYTES: '3' };
        expect(() => getMonitoringConfig(limits)).toThrow(/WARNING_USED/);
        expect(() => getMonitoringConfig({ ...limits, DVU_MONITOR_SOURCE_WARNING_USED_BYTES: '900' }))
            .toThrow(/minimum/);
        const withLimits = getMonitoringConfig({
            ...limits, DVU_MONITOR_SOURCE_WARNING_USED_BYTES: '900',
            DVU_MONITOR_SOURCE_WARNING_FREE_BYTES: '5', DVU_MONITOR_SOURCE_CRITICAL_FREE_BYTES: '3',
        });
        expect(withLimits.source).toMatchObject({ maxUsed: 1000n, warningUsed: 900n, minFree: 3n });
    });

    it('uses exact free-space boundaries', () => {
        expect(spaceStatus(101n, 100n, 50n)).toBe('ok');
        expect(spaceStatus(100n, 100n, 50n)).toBe('warning');
        expect(spaceStatus(99n, 100n, 50n)).toBe('warning');
        expect(spaceStatus(50n, 100n, 50n)).toBe('critical');
        expect(spaceStatus(49n, 100n, 50n)).toBe('critical');
    });

    it('measures a real source without creating it and rejects a different identity', async () => {
        const source = check('source-space', { inspectVolume: directory => lstat(directory, { bigint: true }) });
        const measured = await source.collect();
        expect(measured.status).toBe('ok');
        expect(BigInt(measured.metrics.freeBytes)).toBeGreaterThan(0n);
        expect(BigInt(measured.metrics.usedBytes)).toBeGreaterThan(0n);
        await writeFile(path.join(config.source.directory, '.dvu-storage-id'), BACKUP_ID);
        await expect(source.collect()).rejects.toThrow(/identity/);
        await rm(config.source.directory, { recursive: true });
        await expect(source.collect()).rejects.toThrow();
        await expect(lstat(config.source.directory)).rejects.toMatchObject({ code: 'ENOENT' });
    });

    it('warns and then becomes critical when the source reaches its configured budget', async () => {
        config.source.warningUsed = 1n;
        config.source.maxUsed = 1000n;
        const source = check('source-space', { inspectVolume: directory => lstat(directory, { bigint: true }) });
        expect((await source.collect()).status).toBe('warning');
        config.source.maxUsed = 2n;
        expect((await source.collect()).status).toBe('critical');
    });

    it('rejects unmounted volumes and checks the external volume marker', async () => {
        await expect(check('original-backup-space').collect()).rejects.toThrow(/not mounted/);
        const inspectVolume = directory => lstat(directory, { bigint: true });
        const backup = check('original-backup-space', { inspectVolume });
        expect((await backup.collect()).status).toBe('ok');
        await writeFile(path.join(config.backup.volume, '.dvu-original-backup-volume-id'), SOURCE_ID);
        await expect(backup.collect()).rejects.toThrow(/identity/);
    });

    it('reports invalid configuration visibly instead of disabling monitoring', async () => {
        const service = monitoringFromEnvironment({ env: { ...env, DVU_MONITOR_SOURCE_ID: 'bad' }, log, clock: () => NOW });
        await service.runOnce();
        expect(service.snapshot().checks[0]).toMatchObject({ id: 'configuration', status: 'critical' });
        expect(log.error).toHaveBeenCalled();
    });
});

describe('backup status checks', () => {
    it('distinguishes never-run, running, fresh, stale, failure, and recovery', async () => {
        const original = check('original-local');
        expect(await original.collect()).toMatchObject({ status: 'warning', message: expect.stringContaining('No backup') });
        await writeState('original-local', { version: 1, lastStartedAt: iso(-HOUR), currentRunId: RUN_ID });
        expect(await original.collect()).toMatchObject({ status: 'warning', running: true });
        await writeState('original-local', success());
        expect(await original.collect()).toMatchObject({ status: 'ok', message: 'Backup verification completed' });
        await writeState('original-local', success(-3 * HOUR));
        expect(await original.collect()).toMatchObject({ status: 'critical', message: expect.stringContaining('stale') });
        await writeState('original-local', {
            ...success(-2 * HOUR), lastCompletedAt: iso(-HOUR), lastFailureAt: iso(-HOUR), lastOutcome: 'failure',
        });
        expect(await original.collect()).toMatchObject({ status: 'critical', message: expect.stringContaining('failed') });
        await writeState('original-local', { ...success(), lastFailureAt: iso(-2 * HOUR) });
        expect(await original.collect()).toMatchObject({ status: 'ok' });
    });

    it('reports a long-running or interrupted run rather than treating it as success', async () => {
        await writeState('original-b2', {
            ...success(-4 * HOUR), lastStartedAt: iso(-3 * HOUR), currentRunId: RUN_ID,
        });
        expect(await check('original-b2').collect()).toMatchObject({
            status: 'critical', running: true, message: expect.stringContaining('not finished'),
        });
    });

    it('uses different local and offsite database freshness limits and verifies archive presence', async () => {
        const local = check('database-local');
        const offsite = check('database-offsite');
        await writeState('database-local', success(-35 * HOUR));
        expect(await local.collect()).toMatchObject({ status: 'warning', message: expect.stringContaining('archive') });
        const archive = path.join(config.database.directory, 'directvideo_2026-03-01_110000.sql.gz.gpg');
        await writeFile(archive, 'synthetic encrypted archive');
        await utimes(archive, NOW, NOW);
        const info = await lstat(archive, { bigint: true });
        const archiveState = {
            name: path.basename(archive), sizeBytes: info.size.toString(), mtimeNs: info.mtimeNs.toString(),
        };
        await writeState('database-local', { ...success(-35 * HOUR), lastArchive: archiveState });
        expect(await local.collect()).toMatchObject({ status: 'ok', message: expect.stringContaining('not verified') });
        await rm(archive);
        expect(await local.collect()).toMatchObject({ status: 'critical', message: expect.stringContaining('missing') });
        await writeState('database-local', { ...success(-36 * HOUR), lastArchive: archiveState });
        expect(await local.collect()).toMatchObject({ status: 'critical', message: expect.stringContaining('stale') });
        await writeState('database-offsite', success(-215 * HOUR));
        expect(await offsite.collect()).toMatchObject({ status: 'warning', message: expect.stringContaining('not confirmed') });
        await writeState('database-offsite', { ...success(-215 * HOUR), stableSourceArchive: true });
        expect(await offsite.collect()).toMatchObject({ status: 'ok', message: expect.stringContaining('not verified') });
        await writeState('database-offsite', { ...success(-216 * HOUR), stableSourceArchive: true });
        expect(await offsite.collect()).toMatchObject({ status: 'critical' });
    });

    it('does not count empty or symlinked database archives', async () => {
        const archive = path.join(config.database.directory, 'directvideo_2026-03-01_110000.sql.gz.gpg');
        await writeFile(archive, '');
        await writeState('database-local', {
            ...success(), lastArchive: { name: path.basename(archive), sizeBytes: '1', mtimeNs: '1' },
        });
        expect((await check('database-local').collect()).status).toBe('critical');
        await rm(archive);
        await symlink(path.join(config.source.directory, '.dvu-storage-id'), archive);
        expect((await check('database-local').collect()).status).toBe('critical');
    });

    it('rejects inconsistent, future, or unreadable receipts instead of showing healthy', async () => {
        const original = check('original-local');
        await writeState('original-local', { version: 1, lastStartedAt: iso(-HOUR), lastSuccessAt: iso(-HOUR) });
        await expect(original.collect()).rejects.toThrow(/inconsistent/);
        await writeState('original-local', success(HOUR));
        await expect(original.collect()).rejects.toThrow(/future/);
        const service = createMonitoringService({ checks: [original], log, clock: () => NOW });
        await service.runOnce();
        expect(service.snapshot().checks[0].status).toBe('unknown');
        expect(log.error).toHaveBeenCalled();
    });

    it('reads receipts produced by the real scheduled-job wrapper', async () => {
        const script = fileURLToPath(new URL('../../../scripts/monitor_job.py', import.meta.url));
        const archive = path.join(config.database.directory, 'directvideo_2026-03-01_110000.sql.gz.gpg');
        const local = spawnSync('python3', [
            script, '--state-dir', config.stateDir, '--check', 'database-local',
            '--created-archive-dir', config.database.directory, '--',
            'python3', '-c', "from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'synthetic archive')",
            archive,
        ], { encoding: 'utf8' });
        expect(local.status, local.stderr).toBe(0);
        const localCheck = createMonitoringChecks(config).find(item => item.id === 'database-local');
        expect(await localCheck.collect()).toMatchObject({ status: 'ok' });
        const result = spawnSync('python3', [
            script, '--state-dir', config.stateDir, '--check', 'database-offsite',
            '--require-archive-dir', config.database.directory, '--',
            'python3', '-c', 'pass',
        ], { encoding: 'utf8' });
        expect(result.status, result.stderr).toBe(0);
        const current = createMonitoringChecks(config).find(item => item.id === 'database-offsite');
        expect(await current.collect()).toMatchObject({ status: 'ok', running: false });
    });
});

describe('monitoring service', () => {
    it('runs independent check providers, publishes snapshots, and exposes stale results', async () => {
        let now = NOW;
        const listener = vi.fn();
        const service = createMonitoringService({
            checks: [
                { id: 'custom-service', label: 'Custom service', category: 'service',
                    collect: async () => ({ status: 'ok', message: 'Available' }) },
                { id: 'broken-service', label: 'Broken service', category: 'service',
                    collect: async () => { throw new Error('private details'); } },
            ],
            log, clock: () => now, intervalMs: 1000,
        });
        const unsubscribe = service.subscribe(listener);
        await service.runOnce();
        expect(service.snapshot().checks).toEqual([
            expect.objectContaining({ id: 'custom-service', status: 'ok' }),
            expect.objectContaining({ id: 'broken-service', status: 'unknown' }),
        ]);
        expect(JSON.stringify(service.snapshot())).not.toContain('private details');
        expect(listener).toHaveBeenCalledTimes(1);
        now = new Date(NOW.getTime() + 2001);
        expect(service.snapshot().stale).toBe(true);
        unsubscribe();
        await service.runOnce();
        expect(listener).toHaveBeenCalledTimes(1);
    });

    it('reports failed subscribers without hiding other check results', async () => {
        const service = createMonitoringService({
            checks: [{ id: 'test', label: 'Test', category: 'service',
                collect: async () => ({ status: 'ok', message: 'Available' }) }],
            log, clock: () => NOW,
        });
        service.subscribe(async () => { throw new Error('private delivery details'); });
        await service.runOnce();
        expect(service.snapshot().checks[0].status).toBe('ok');
        expect(log.error).toHaveBeenCalledWith(expect.anything(), 'Monitoring subscriber failed');
    });

    it('times out a stuck check without starting overlapping attempts', async () => {
        vi.useFakeTimers();
        const collect = vi.fn(() => new Promise(() => {}));
        const service = createMonitoringService({
            checks: [{ id: 'stuck', label: 'Stuck service', category: 'service', collect }],
            log, clock: () => NOW, timeoutMs: 20,
        });
        const first = service.runOnce();
        await vi.advanceTimersByTimeAsync(20);
        await first;
        expect(service.snapshot().checks[0].status).toBe('unknown');
        const second = service.runOnce();
        await vi.advanceTimersByTimeAsync(20);
        await second;
        expect(collect).toHaveBeenCalledTimes(1);
    });

    it('runs periodically and stops cleanly', async () => {
        vi.useFakeTimers();
        const collect = vi.fn(async () => ({ status: 'ok', message: 'Available' }));
        const service = createMonitoringService({
            checks: [{ id: 'periodic', label: 'Periodic service', category: 'service', collect }],
            log, clock: () => NOW, intervalMs: 100,
        });
        service.start();
        await vi.advanceTimersByTimeAsync(0);
        expect(collect).toHaveBeenCalledTimes(1);
        await vi.advanceTimersByTimeAsync(100);
        expect(collect).toHaveBeenCalledTimes(2);
        service.stop();
        await vi.advanceTimersByTimeAsync(200);
        expect(collect).toHaveBeenCalledTimes(2);
    });

    it('can register and remove another live service check', async () => {
        const service = createMonitoringService({ log, clock: () => NOW });
        const unregister = service.registerCheck({
            id: 'additional-service', label: 'Additional service', category: 'service',
            collect: async () => ({ status: 'ok', message: 'Connected' }),
        });
        expect(() => service.registerCheck({
            id: 'additional-service', label: 'Duplicate', category: 'service', collect: async () => ({}),
        })).toThrow(/unique/);
        await service.runOnce();
        expect(service.snapshot().checks[0]).toMatchObject({ id: 'additional-service', status: 'ok' });
        unregister();
        await service.runOnce();
        expect(service.snapshot().checks).toEqual([]);
    });
});
