import { constants } from 'node:fs';
import { lstat, open, statfs } from 'node:fs/promises';
import path from 'node:path';
import { createLocalStorageDriver } from './storage/local-driver.js';

const INTERVAL_MS = 5 * 60 * 1000;
const CHECK_TIMEOUT_MS = 60 * 1000;
const MAX_STATE_BYTES = 16384;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CHECK_ID = /^[a-z][a-z0-9-]{0,63}$/;
const STATUSES = new Set(['ok', 'warning', 'critical', 'unknown']);

function absolute(value, name) {
    if (typeof value !== 'string' || !path.isAbsolute(value)) {
        throw new Error(`${name} must be an absolute path`);
    }
    return path.resolve(value);
}

function positiveBytes(value, name) {
    if (typeof value !== 'string' || !/^[1-9][0-9]*$/.test(value)) {
        throw new Error(`${name} must be a positive decimal byte count`);
    }
    const result = BigInt(value);
    if (result > 9_223_372_036_854_775_807n) throw new Error(`${name} is too large`);
    return result;
}

function hours(value, name, fallback) {
    const text = value || String(fallback);
    if (!/^[1-9][0-9]*$/.test(text)) throw new Error(`${name} must be a positive number of hours`);
    const result = Number(text);
    if (!Number.isSafeInteger(result) || result > 24 * 365) throw new Error(`${name} is too large`);
    return result * 60 * 60 * 1000;
}

function identity(value, name) {
    if (typeof value !== 'string' || !UUID.test(value)) throw new Error(`${name} must be a UUID`);
    return value.toLowerCase();
}

function within(volume, directory, name) {
    const relative = path.relative(volume, directory);
    if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
        throw new Error(`${name} must be inside its configured volume`);
    }
}

function volumeConfig(env, key, label, root) {
    const volume = absolute(env[`DVU_MONITOR_${key}_VOLUME`], `DVU_MONITOR_${key}_VOLUME`);
    const directory = absolute(root ?? volume, `${label} directory`);
    within(volume, directory, label);
    const warning = positiveBytes(env[`DVU_MONITOR_${key}_WARNING_FREE_BYTES`], `${label} warning`);
    const critical = positiveBytes(env[`DVU_MONITOR_${key}_CRITICAL_FREE_BYTES`], `${label} critical`);
    if (warning <= critical) throw new Error(`${label} warning must exceed its critical free-space threshold`);
    return { volume, directory, warning, critical };
}

export function getMonitoringConfig(env = process.env) {
    const enabled = env.DVU_MONITORING_ENABLED || 'false';
    if (!['true', 'false'].includes(enabled)) throw new Error('DVU_MONITORING_ENABLED must be true or false');
    if (enabled === 'false') return { enabled: false };

    const stateDir = absolute(env.DVU_MONITOR_STATE_DIR, 'DVU_MONITOR_STATE_DIR');
    const source = volumeConfig(env, 'SOURCE', 'Source storage', env.STORAGE_LOCAL_ROOT);
    source.identity = identity(env.DVU_MONITOR_SOURCE_ID, 'DVU_MONITOR_SOURCE_ID');
    const backup = volumeConfig(env, 'BACKUP', 'Original backup');
    backup.identity = identity(env.DVU_MONITOR_BACKUP_ID, 'DVU_MONITOR_BACKUP_ID');
    const database = volumeConfig(env, 'DATABASE', 'Database backup', env.DVU_MONITOR_DATABASE_DIR);
    if (!env.STORAGE_LOCAL_ROOT || !env.DVU_MONITOR_DATABASE_DIR) {
        throw new Error('Source and database backup directories must be configured');
    }
    if (env.UPLOAD_STORAGE_MAX_BYTES) {
        source.maxUsed = positiveBytes(env.UPLOAD_STORAGE_MAX_BYTES, 'UPLOAD_STORAGE_MAX_BYTES');
        source.warningUsed = positiveBytes(
            env.DVU_MONITOR_SOURCE_WARNING_USED_BYTES, 'DVU_MONITOR_SOURCE_WARNING_USED_BYTES'
        );
        if (source.warningUsed >= source.maxUsed) throw new Error('Source used-space warning must be below its limit');
    }
    if (env.UPLOAD_STORAGE_MIN_FREE_BYTES) {
        source.minFree = positiveBytes(env.UPLOAD_STORAGE_MIN_FREE_BYTES, 'UPLOAD_STORAGE_MIN_FREE_BYTES');
        if (source.critical < source.minFree) {
            throw new Error('Source critical free-space threshold must meet the upload minimum');
        }
    }

    return {
        enabled: true, stateDir, source, backup, database,
        originalStaleMs: hours(env.DVU_MONITOR_ORIGINAL_STALE_HOURS, 'Original freshness', 3),
        databaseLocalStaleMs: hours(env.DVU_MONITOR_DATABASE_LOCAL_STALE_HOURS, 'Local database freshness', 36),
        databaseOffsiteStaleMs: hours(env.DVU_MONITOR_DATABASE_OFFSITE_STALE_HOURS, 'Offsite database freshness', 216),
    };
}

function sameDirectory(left, right) {
    return left.dev === right.dev && left.ino === right.ino;
}

async function directoryInfo(directory) {
    const info = await lstat(directory, { bigint: true });
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Monitoring directory is unavailable');
    return info;
}

async function volumeIdentity(volume) {
    const info = await directoryInfo(volume);
    if (volume !== path.parse(volume).root) {
        const parent = await directoryInfo(path.dirname(volume));
        if (info.dev === parent.dev) throw new Error('Monitoring volume is not mounted');
    }
    return info;
}

async function validateDirectoryChain(volume, directory, device) {
    let current = volume;
    for (const component of path.relative(volume, directory).split(path.sep).filter(Boolean)) {
        current = path.join(current, component);
        const info = await directoryInfo(current);
        if (info.dev !== device) throw new Error('Monitoring directory is on an unexpected filesystem');
    }
    return directoryInfo(directory);
}

async function readPrivateFile(filename, limit, { privateFile = false } = {}) {
    const handle = await open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
        const info = await handle.stat();
        if (!info.isFile() || info.size > limit
            || (privateFile && (info.uid !== process.getuid() || (info.mode & 0o077) !== 0))) {
            throw new Error('Monitoring file is invalid');
        }
        const data = Buffer.alloc(limit + 1);
        let length = 0;
        while (length < data.length) {
            const { bytesRead } = await handle.read(data, length, data.length - length, null);
            if (bytesRead === 0) break;
            length += bytesRead;
        }
        if (length > limit) throw new Error('Monitoring file is too large');
        return data.subarray(0, length).toString('utf8');
    } finally {
        await handle.close();
    }
}

async function verifyBackupMarker(volume, expected) {
    const value = (await readPrivateFile(path.join(volume, '.dvu-original-backup-volume-id'), 256)).trim();
    if (!UUID.test(value) || value.toLowerCase() !== expected) {
        throw new Error('Original backup volume identity does not match');
    }
}

export function spaceStatus(free, warning, critical) {
    if (free <= critical) return 'critical';
    if (free <= warning) return 'warning';
    return 'ok';
}

function worstStatus(left, right) {
    const rank = { ok: 0, warning: 1, critical: 2, unknown: 3 };
    return rank[left] >= rank[right] ? left : right;
}

function spaceMessage(status) {
    if (status === 'critical') return 'Storage has reached a critical threshold';
    if (status === 'warning') return 'Storage has reached a warning threshold';
    return 'Storage is within configured thresholds';
}

function makeVolumeCheck(id, label, settings, kind, inspectVolume) {
    const driver = kind === 'source' ? createLocalStorageDriver({ root: settings.directory }) : null;
    return {
        id, label, category: 'storage',
        async collect() {
            const before = await inspectVolume(settings.volume);
            const rootBefore = await validateDirectoryChain(settings.volume, settings.directory, before.dev);
            if (kind === 'backup') await verifyBackupMarker(settings.volume, settings.identity);

            let free;
            let used;
            if (driver) {
                const snapshot = await driver.getCapacitySnapshot({ create: false });
                if (snapshot.identity !== settings.identity) throw new Error('Original storage identity does not match');
                free = snapshot.availableBytes;
                used = snapshot.usedBytes;
            } else {
                const filesystem = await statfs(settings.directory, { bigint: true });
                if (filesystem.bsize <= 0n || filesystem.bavail < 0n) throw new Error('Invalid filesystem capacity');
                free = filesystem.bavail * filesystem.bsize;
            }

            const rootAfter = await validateDirectoryChain(settings.volume, settings.directory, before.dev);
            const after = await inspectVolume(settings.volume);
            if (!sameDirectory(before, after) || !sameDirectory(rootBefore, rootAfter)) {
                throw new Error('Monitoring volume changed during measurement');
            }
            if (kind === 'backup') await verifyBackupMarker(settings.volume, settings.identity);

            let status = spaceStatus(free, settings.warning, settings.critical);
            if (used !== undefined && settings.maxUsed !== undefined) {
                const usedStatus = used >= settings.maxUsed ? 'critical' : used >= settings.warningUsed ? 'warning' : 'ok';
                status = worstStatus(status, usedStatus);
            }
            return {
                status,
                message: spaceMessage(status),
                metrics: {
                    freeBytes: free.toString(),
                    ...(used !== undefined ? { usedBytes: used.toString() } : {}),
                    ...(settings.maxUsed !== undefined ? { limitBytes: settings.maxUsed.toString() } : {}),
                },
            };
        },
    };
}

function parseTime(value) {
    if (typeof value !== 'string') throw new Error('Monitoring timestamp is invalid');
    const parsed = Date.parse(value);
    if (!Number.isFinite(parsed) || new Date(parsed).toISOString() !== value) {
        throw new Error('Monitoring timestamp is invalid');
    }
    return parsed;
}

async function readBackupState(stateDir, id) {
    const directory = await lstat(stateDir);
    if (!directory.isDirectory() || directory.isSymbolicLink()
        || directory.uid !== process.getuid() || (directory.mode & 0o077) !== 0) {
        throw new Error('Monitoring state directory is not private');
    }
    try {
        const raw = await readPrivateFile(path.join(stateDir, `${id}.json`), MAX_STATE_BYTES, { privateFile: true });
        const state = JSON.parse(raw);
        if (!state || Array.isArray(state) || typeof state !== 'object' || state.version !== 1) {
            throw new Error('Monitoring state is invalid');
        }
        return state;
    } catch (error) {
        if (error.code === 'ENOENT') return null;
        throw error;
    }
}

function evaluateBackup(state, staleMs, now, verified) {
    if (!state) return { status: 'warning', message: 'No backup run has been recorded' };
    const dates = {};
    for (const field of ['lastStartedAt', 'lastCompletedAt', 'lastSuccessAt', 'lastFailureAt']) {
        if (state[field] !== undefined) {
            dates[field] = parseTime(state[field]);
            if (dates[field] > now + 60_000) throw new Error('Monitoring timestamp is in the future');
        }
    }
    if (dates.lastStartedAt === undefined
        || (state.currentRunId != null && (typeof state.currentRunId !== 'string' || !UUID.test(state.currentRunId)))
        || (state.lastOutcome !== undefined && !['success', 'failure'].includes(state.lastOutcome))
        || ((state.lastOutcome === undefined) !== (dates.lastCompletedAt === undefined))
        || ((dates.lastSuccessAt !== undefined || dates.lastFailureAt !== undefined)
            && dates.lastCompletedAt === undefined)
        || (state.lastOutcome === 'success' && dates.lastSuccessAt !== dates.lastCompletedAt)
        || (state.lastOutcome === 'failure' && dates.lastFailureAt !== dates.lastCompletedAt)
        || (dates.lastSuccessAt !== undefined && dates.lastSuccessAt > dates.lastCompletedAt)
        || (dates.lastFailureAt !== undefined && dates.lastFailureAt > dates.lastCompletedAt)) {
        throw new Error('Monitoring state is inconsistent');
    }
    const running = state.currentRunId != null;
    const lastSuccessAt = state.lastSuccessAt ?? null;
    const details = { lastSuccessAt, running };
    if (running && now - dates.lastStartedAt >= staleMs) {
        return { status: 'critical', message: 'A backup run has not finished within the freshness limit', ...details };
    }
    if (state.lastOutcome === 'failure') {
        return { status: 'critical', message: 'The most recent backup run failed', ...details };
    }
    if (dates.lastSuccessAt === undefined) {
        return { status: 'warning', message: 'No successful backup run has been recorded', ...details };
    }
    if (now - dates.lastSuccessAt >= staleMs) {
        return { status: 'critical', message: 'The last successful backup is stale', ...details };
    }
    return {
        status: 'ok',
        message: verified ? 'Backup verification completed' : 'Backup job completed; restore is not verified',
        ...details,
    };
}

async function hasRecordedDatabaseArchive(directory, archive, staleMs, now) {
    if (!archive || typeof archive !== 'object' || Array.isArray(archive)
        || typeof archive.name !== 'string'
        || !/^directvideo_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.sql\.gz\.gpg$/.test(archive.name)
        || typeof archive.sizeBytes !== 'string' || !/^[1-9][0-9]*$/.test(archive.sizeBytes)
        || typeof archive.mtimeNs !== 'string' || !/^[0-9]+$/.test(archive.mtimeNs)) {
        throw new Error('Database archive metadata is invalid');
    }
    try {
        const info = await lstat(path.join(directory, archive.name), { bigint: true });
        const modified = Number(info.mtimeNs / 1_000_000n);
        return info.isFile() && !info.isSymbolicLink() && info.size.toString() === archive.sizeBytes
            && info.mtimeNs.toString() === archive.mtimeNs
            && modified <= now + 60_000 && now - modified < staleMs;
    } catch (error) {
        if (error.code === 'ENOENT') return false;
        throw error;
    }
}

function makeBackupCheck(id, label, stateDir, staleMs, verified, clock, archiveDir) {
    return {
        id, label, category: 'backup',
        async collect() {
            const now = clock().getTime();
            const state = await readBackupState(stateDir, id);
            const result = evaluateBackup(state, staleMs, now, verified);
            if (archiveDir && result.status === 'ok') {
                if (!state.lastArchive) {
                    return { ...result, status: 'warning', message: 'Backup completed without a recorded archive' };
                }
                if (!await hasRecordedDatabaseArchive(archiveDir, state.lastArchive, staleMs, now)) {
                    return { ...result, status: 'critical', message: 'The recorded database archive is missing or changed' };
                }
            }
            if (id === 'database-offsite' && result.status === 'ok' && state.stableSourceArchive !== true) {
                return {
                    ...result, status: 'warning',
                    message: 'Sync completed, but a stable source archive was not confirmed',
                };
            }
            return result;
        },
    };
}

export function createMonitoringChecks(config, clock = () => new Date(), { inspectVolume = volumeIdentity } = {}) {
    return [
        makeVolumeCheck('source-space', 'Original storage', config.source, 'source', inspectVolume),
        makeVolumeCheck('original-backup-space', 'Original backup drive', config.backup, 'backup', inspectVolume),
        makeVolumeCheck('database-backup-space', 'Database backup drive', config.database, 'database', inspectVolume),
        makeBackupCheck('original-local', 'Original backup: local', config.stateDir, config.originalStaleMs, true, clock),
        makeBackupCheck('original-b2', 'Original backup: B2', config.stateDir, config.originalStaleMs, true, clock),
        makeBackupCheck(
            'database-local', 'Database backup: local', config.stateDir,
            config.databaseLocalStaleMs, false, clock, config.database.directory
        ),
        makeBackupCheck('database-offsite', 'Database backup: offsite', config.stateDir, config.databaseOffsiteStaleMs, false, clock),
    ];
}

export function createMonitoringService({
    enabled = true, checks = [], log, clock = () => new Date(), intervalMs = INTERVAL_MS,
    timeoutMs = CHECK_TIMEOUT_MS,
} = {}) {
    const seen = new Set();
    const registered = [];
    function registerCheck(check) {
        if (!check || !CHECK_ID.test(check.id) || seen.has(check.id) || typeof check.label !== 'string'
            || !['storage', 'backup', 'service'].includes(check.category) || typeof check.collect !== 'function') {
            throw new TypeError('Monitoring checks must have unique identifiers, labels, categories, and collectors');
        }
        seen.add(check.id);
        registered.push(check);
        return () => {
            const index = registered.indexOf(check);
            if (index !== -1) {
                registered.splice(index, 1);
                seen.delete(check.id);
            }
        };
    }
    for (const check of checks) registerCheck(check);
    let snapshot = { enabled, checkedAt: null, checks: [] };
    let running = false;
    let timer;
    const listeners = new Set();
    const pending = new Map();
    const pendingListeners = new Map();

    async function collect(check) {
        let task = pending.get(check);
        if (!task) {
            task = Promise.resolve().then(() => check.collect());
            pending.set(check, task);
            task.then(
                () => { if (pending.get(check) === task) pending.delete(check); },
                () => { if (pending.get(check) === task) pending.delete(check); }
            );
        }
        let timeout;
        try {
            const result = await Promise.race([
                task,
                new Promise((_, reject) => {
                    timeout = setTimeout(() => reject(new Error('Monitoring check timed out')), timeoutMs);
                }),
            ]);
            if (!result || !STATUSES.has(result.status) || typeof result.message !== 'string') {
                throw new Error('Monitoring check returned an invalid result');
            }
            return { ...result, id: check.id, label: check.label, category: check.category };
        } catch (error) {
            log?.error({ checkId: check.id, errorCode: error.code }, 'Monitoring check failed');
            return {
                id: check.id, label: check.label, category: check.category,
                status: 'unknown', message: 'Monitoring check could not be completed',
            };
        } finally {
            clearTimeout(timeout);
        }
    }

    async function runOnce() {
        if (!enabled || running) return;
        running = true;
        try {
            const results = await Promise.all(registered.map(collect));
            snapshot = { enabled: true, checkedAt: clock().toISOString(), checks: results };
            await Promise.all([...listeners].map(async listener => {
                let task = pendingListeners.get(listener);
                if (!task) {
                    task = Promise.resolve().then(() => listener(snapshot));
                    pendingListeners.set(listener, task);
                    task.then(
                        () => { if (pendingListeners.get(listener) === task) pendingListeners.delete(listener); },
                        () => { if (pendingListeners.get(listener) === task) pendingListeners.delete(listener); }
                    );
                }
                let timeout;
                try {
                    await Promise.race([
                        task,
                        new Promise((_, reject) => {
                            timeout = setTimeout(() => reject(new Error('Monitoring subscriber timed out')), timeoutMs);
                        }),
                    ]);
                } catch (error) {
                    log?.error({ errorCode: error.code }, 'Monitoring subscriber failed');
                } finally {
                    clearTimeout(timeout);
                }
            }));
        } finally {
            running = false;
        }
    }

    return {
        runOnce,
        start() {
            if (!enabled || timer) return;
            void runOnce();
            timer = setInterval(() => { void runOnce(); }, intervalMs);
        },
        stop() {
            if (timer) clearInterval(timer);
            timer = undefined;
        },
        registerCheck,
        subscribe(listener) {
            if (typeof listener !== 'function') throw new TypeError('Monitoring subscriber must be a function');
            listeners.add(listener);
            return () => listeners.delete(listener);
        },
        snapshot() {
            const age = snapshot.checkedAt ? clock().getTime() - Date.parse(snapshot.checkedAt) : 0;
            const stale = age > intervalMs * 2 || age < -60_000;
            return { ...snapshot, stale: Boolean(stale) };
        },
    };
}

export function monitoringFromEnvironment({ env = process.env, log, clock } = {}) {
    try {
        const config = getMonitoringConfig(env);
        return createMonitoringService({
            enabled: config.enabled,
            checks: config.enabled ? createMonitoringChecks(config, clock) : [],
            log, clock,
        });
    } catch (error) {
        log?.error({ err: { message: error.message } }, 'Monitoring configuration is invalid');
        return createMonitoringService({
            checks: [{
                id: 'configuration', label: 'Monitoring configuration', category: 'service',
                collect: async () => ({ status: 'critical', message: 'Monitoring configuration is invalid' }),
            }],
            log, clock,
        });
    }
}
