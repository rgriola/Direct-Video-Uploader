#!/usr/bin/env node
// Last updated: May 11, 2026 - 7:59pm - GitHub Copilot (GPT-5.3-Codex)
/**
 * Triad Dev Launcher
 * Coordinates: Database (Prisma) + Server (Fastify) + Admin Dashboard (Vite)
 *
 * Usage: node scripts/dev.js   (or `npm run dev` from project root)
 */
import { spawn, execSync } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const SERVER_DIR = path.join(ROOT, 'server');
const ADMIN_DIR = path.join(ROOT, 'admin');

// ── Colors ────────────────────────────────────────────────
const C = {
    reset: '\x1b[0m', bold: '\x1b[1m', dim: '\x1b[2m',
    red: '\x1b[31m', green: '\x1b[32m', yellow: '\x1b[33m',
    blue: '\x1b[34m', magenta: '\x1b[35m', cyan: '\x1b[36m',
};

function ts() {
    return new Date().toLocaleTimeString('en-US', { hour12: false });
}
function log(tag, color, msg) {
    console.log(`${C.dim}${ts()}${C.reset} ${color}[${tag}]${C.reset} ${msg}`);
}
const logDB = (m) => log('DB', C.magenta, m);
const logSrv = (m) => log('SERVER', C.cyan, m);
const logAdm = (m) => log('ADMIN', C.blue, m);
const logTri = (m) => log('TRIAD', C.green + C.bold, m);
const logErr = (m) => log('ERROR', C.red, m);

// ── Helpers ───────────────────────────────────────────────
function killPort(port) {
    try {
        const pids = execSync(`lsof -ti :${port} 2>/dev/null`, { encoding: 'utf8' }).trim();
        if (pids) {
            execSync(`kill -9 ${pids.split('\n').join(' ')} 2>/dev/null`);
            return true;
        }
    } catch { /* no process */ }
    return false;
}

function runSync(cmd, cwd) {
    try {
        const output = execSync(cmd, { cwd, encoding: 'utf8', stdio: 'pipe', timeout: 90000 });
        return { ok: true, output };
    } catch (err) {
        return { ok: false, output: err.stderr || err.stdout || err.message };
    }
}

function runProcess(cmd, args, cwd, tag, color, { filter } = {}) {
    const proc = spawn(cmd, args, {
        cwd,
        stdio: ['ignore', 'pipe', 'pipe'],
        env: { ...process.env, FORCE_COLOR: '1' },
    });
    const emit = filter || ((line) => log(tag, color, line));
    proc.stdout.on('data', (d) => {
        d.toString().trim().split('\n').forEach(line => { if (line.trim()) emit(line, 'stdout'); });
    });
    proc.stderr.on('data', (d) => {
        d.toString().trim().split('\n').forEach(line => { if (line.trim()) emit(line, 'stderr'); });
    });
    proc.on('exit', (code) => {
        if (code !== null && code !== 0) logErr(`${tag} exited with code ${code}`);
    });
    return proc;
}

/**
 * Server log filter — summarizes routine pino request logs into periodic
 * one-liners, while passing through important events immediately.
 */
function createServerFilter() {
    let requestCount = 0;
    let errorCount = 0;
    let lastSummaryTime = Date.now();
    let lastErrorMsg = '';
    const SUMMARY_INTERVAL = 15_000; // 15 seconds

    // Dedup: same message within 1s is suppressed unless state changed
    let lastEmittedMsg = '';
    let lastEmittedTime = 0;
    const DEDUP_MS = 1_000; // 1 second

    function emit(msg) {
        const now = Date.now();
        // If identical message within 1s, skip it
        if (msg === lastEmittedMsg && now - lastEmittedTime < DEDUP_MS) return;
        lastEmittedMsg = msg;
        lastEmittedTime = now;
        logSrv(msg);
    }

    // Patterns that should ALWAYS be shown (subject to 1s dedup)
    const showAlways = [
        /✅.*connected/i, /❌.*disconnected/i,
        /📹 Upload started/i, /💬 Slack post/i, /💬 Message from/i,
        /Server running/i, /listening/i,
        /╔|╚|║/, // startup banner
    ];

    // Patterns that are routine polling noise — count but don't print
    const suppress = [
        /incoming request/i, /request completed/i,
        /reqId/, /responseTime/, /statusCode/,
        /^requestId:\s*"/i,
        /"method"/, /"url"/, /"host"/, /"remoteAddress"/,
        /"remotePort"/, /res:|req:/,
        /^\s*"/, /^\s*\{/, /^\s*\}/, // JSON fragments from pino
        /^\s*$/, // blank lines
    ];

    // Known transient errors — count but don't print (pool self-heals)
    const transientError = /connection terminated|connection reset|connection refused|ECONNRESET|ECONNREFUSED|EPIPE|pool error/i;

    // Stack trace lines to suppress (condense errors to single line)
    const stackLine = /^\s*at\s|node_modules|node:internal|caused by:/i;

    return (line, stream) => {
        const stripped = line.replace(/\x1b\[[0-9;]*m/g, '').trim();
        if (!stripped) return;

        // Show stderr during startup, then suppress routine noise
        if (stream === 'stderr') {
            errorCount++;
            // Always show non-empty stderr so startup errors aren't hidden
            if (stripped && !stackLine.test(stripped) && !transientError.test(stripped)) {
                emit(`${C.red}${stripped}${C.reset}`);
            }
            return;
        }

        // Known transient pool errors — silently count, don't print
        if (transientError.test(stripped)) {
            errorCount++;
            return;
        }

        if (/ERROR|FATAL/i.test(stripped) && !/^\s*"/.test(stripped)) {
            const msg = stripped.replace(/\[.*?\]\s*(ERROR|FATAL)\s*\([^)]*\):\s*/, '').trim();
            if (msg && msg !== lastErrorMsg && !transientError.test(msg)) {
                emit(`${C.red}⚠️  ${msg}${C.reset}`);
                lastErrorMsg = msg;
            }
            errorCount++;
            return;
        }

        // Skip stack trace lines
        if (stackLine.test(stripped)) return;

        // Skip pino JSON fragments (err: {, "type": "Error", etc.)
        if (/^(err:|"type"|"message"|"stack"|"code"|"clientVersion")/.test(stripped)) return;

        // Always show important events (deduped to 1/sec)
        if (showAlways.some(p => p.test(stripped))) {
            emit(stripped);
            return;
        }

        // Count suppressed routine logs
        if (suppress.some(p => p.test(stripped))) {
            if (/request completed/i.test(stripped)) {
                requestCount++;
            }
            const now = Date.now();
            if (now - lastSummaryTime >= SUMMARY_INTERVAL && requestCount > 0) {
                const errStr = errorCount > 0 ? `, ${C.red}${errorCount} errors${C.reset}` : '';
                emit(`${C.dim}⚡ ${requestCount} requests served${errStr}${C.reset}`);
                requestCount = 0;
                errorCount = 0;
                lastSummaryTime = now;
            }
            return;
        }

        // WARN lines
        if (/WARN/i.test(stripped)) {
            emit(`${C.yellow}${stripped}${C.reset}`);
            return;
        }

        // Anything else (deduped to 1/sec)
        emit(stripped);
    };
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function checkPort(port, urlPath = '/') {
    try {
        const res = await fetch(`http://localhost:${port}${urlPath}`);
        return res.ok;
    } catch { return false; }
}

// ── Main ──────────────────────────────────────────────────
async function main() {
    console.log(`\n${C.bold}${C.cyan}╔══════════════════════════════════════════════════╗
║  🎬  Fixer — Triad Launcher               ║
╚══════════════════════════════════════════════════╝${C.reset}\n`);

    // ─ Step 1: Kill existing processes ────────────────────
    logTri('Cleaning up existing processes...');
    let killed = false;
    // Kill by port
    const k3 = killPort(3000);
    const k5 = killPort(5173);
    if (k3) { logSrv('Killed existing process on :3000'); killed = true; }
    if (k5) { logAdm('Killed existing process on :5173'); killed = true; }
    // Kill by name — catches orphaned processes not yet bound to a port
    try {
        execSync('pkill -f "node src/index.js" 2>/dev/null');
        killed = true;
    } catch { /* none found */ }
    try {
        execSync('pkill -f "vite.*admin" 2>/dev/null');
        killed = true;
    } catch { /* none found */ }
    if (!killed) logTri('No stale processes found');
    await sleep(killed ? 2000 : 500);

    // ─ Step 2: Start PostgreSQL via Prisma ────────────────
    logDB('Checking Homebrew PostgreSQL...');
    // Use brew --prefix to find pg_isready regardless of PG version
    const pgBin = runSync('brew --prefix postgresql@16', ROOT);
    const pgIsReady = pgBin.ok ? `${pgBin.output.trim()}/bin/pg_isready` : 'pg_isready';
    const dbResult = runSync(`${pgIsReady} -h localhost -p 5432`, ROOT);
    if (dbResult.ok) {
        logDB('PostgreSQL running ✅');
    } else {
        logErr('PostgreSQL is not running — try: brew services start postgresql@16');
        logErr(dbResult.output.trim());
        process.exit(1);
    }

    // ─ Step 3: Push schema ────────────────────────────────
    // Use local binary directly — avoids npx resolution overhead (~5-10s)
    const prismaBin = path.join(SERVER_DIR, 'node_modules', '.bin', 'prisma');
    logDB('Syncing schema (prisma db push)...');
    const pushResult = runSync(`${prismaBin} db push 2>&1`, SERVER_DIR);
    if (pushResult.ok) {
        logDB('Schema synced ✅');
    } else if (pushResult.output.includes('already in sync')) {
        logDB('Schema already in sync ✅');
    } else {
        logErr('Schema push had issues (may be OK if no changes)');
        // Don't exit — often just "already in sync"
    }

    // ─ Step 4: Generate Prisma client (only if schema changed) ───────────
    const schemaPath = path.join(SERVER_DIR, 'prisma', 'schema.prisma');
    const clientPath = path.join(SERVER_DIR, 'node_modules', '.prisma', 'client', 'index.js');
    let needsGenerate = true;
    try {
        const { statSync } = await import('fs');
        const schemaMtime = statSync(schemaPath).mtimeMs;
        const clientMtime = statSync(clientPath).mtimeMs;
        needsGenerate = schemaMtime > clientMtime;
    } catch { /* client doesn't exist yet — generate */ }
    if (needsGenerate) {
        logDB('Generating Prisma client (schema changed)...');
        const genResult = runSync(`${prismaBin} generate 2>&1`, SERVER_DIR);
        if (genResult.ok) {
            logDB('Client generated ✅');
        } else {
            logErr('Prisma generate failed');
        }
    } else {
        logDB('Prisma client up to date — skipping generate ✅');
    }

    // ─ Step 5: Seed if empty ──────────────────────────────
    logDB('Checking seed data...');
    const seedCheck = runSync('node -e "import(\'./src/lib/prisma.js\').then(m=>m.default.user.count()).then(c=>{console.log(c);process.exit(0)})"', SERVER_DIR);
    if (seedCheck.ok && seedCheck.output.trim() === '0') {
        logDB('No users found — running seed...');
        runSync('node src/seed.js', SERVER_DIR);
        logDB('Seed complete ✅');
    } else {
        logDB('Seed data present ✅');
    }

    // ─ Step 6: Start Fastify server ───────────────────────
    logSrv('Starting Fastify server on :3000...');
    const serverFilter = createServerFilter();
    const serverProc = runProcess('node', ['src/index.js'], SERVER_DIR, 'SERVER', C.cyan, { filter: serverFilter });

    let serverReady = false;
    for (let i = 0; i < 40; i++) {
        if (serverProc.exitCode !== null) {
            logErr(`Server process exited with code ${serverProc.exitCode} — check logs above`);
            break;
        }
        await sleep(1000);
        if (await checkPort(3000, '/api/health')) { serverReady = true; break; }
    }
    if (serverReady) {
        logSrv('Fastify running at http://localhost:3000 ✅');
    } else if (serverProc.exitCode === null) {
        logErr('Server did not become ready within 40s — check logs above');
    }

    // ─ Step 7: Start Vite admin dev server ────────────────
    logAdm('Starting Vite dev server on :5173...');
    const adminProc = runProcess('npx', ['vite', '--clearScreen', 'false'], ADMIN_DIR, 'ADMIN', C.blue);

    let adminReady = false;
    for (let i = 0; i < 15; i++) {
        await sleep(1000);
        if (await checkPort(5173, '/')) { adminReady = true; break; }
    }
    if (adminReady) {
        logAdm('Dashboard running at http://localhost:5173 ✅');
    } else {
        logAdm('Vite still starting... (will be available shortly)');
    }

    // ─ Final Status ───────────────────────────────────────
    const dbOk = dbResult.ok;
    const sOk = serverReady;
    const aOk = adminReady;
    const dot = (ok) => ok ? '🟢' : '🔴';
    const st = (ok, yes, no) => ok ? yes : no;

    // Detect LAN IP for physical device connections
    let lanIP = 'unknown';
    try {
        const ifOutput = execSync("ifconfig en0 2>/dev/null | grep 'inet ' | awk '{print $2}'", { encoding: 'utf8' }).trim();
        if (ifOutput) lanIP = ifOutput;
    } catch { /* no en0 */ }

    console.log(`
${C.bold}${C.green}╔══════════════════════════════════════════════════╗
║              T R I A D   S T A T U S             ║
╠══════════════════════════════════════════════════╣
║  ${dot(dbOk)} Database     ${st(dbOk, 'Running ', 'Failed  ')}  PostgreSQL (prisma dev)   ║
║  ${dot(sOk)} Server       ${st(sOk, 'Running ', 'Failed  ')}  http://localhost:3000      ║
║  ${dot(aOk)} Dashboard    ${st(aOk, 'Running ', 'Starting')}  http://localhost:5173      ║
║  ⚪ iOS App      Waiting   No client connected yet  ║
╠══════════════════════════════════════════════════╣
║                                                  ║
║  → Dashboard:  ${C.cyan}http://localhost:5173${C.green}            ║
║  → iOS (LAN):  ${C.yellow}http://${lanIP}:3000${C.green}    ║
║  → Press ${C.yellow}Ctrl+C${C.green} to stop all services             ║
║                                                  ║
╚══════════════════════════════════════════════════╝${C.reset}
`);

    // ─ Graceful shutdown ──────────────────────────────────
    const children = [serverProc, adminProc];
    const cleanup = () => {
        console.log(`\n${C.yellow}[TRIAD] Shutting down all services...${C.reset}`);
        children.forEach(p => { try { p.kill('SIGTERM'); } catch {} });
        // Give processes a moment, then force kill
        setTimeout(() => {
            killPort(3000);
            killPort(5173);
            console.log(`${C.green}[TRIAD] All services stopped. Goodbye! 👋${C.reset}\n`);
            process.exit(0);
        }, 1500);
    };

    process.on('SIGINT', cleanup);
    process.on('SIGTERM', cleanup);
}

main().catch(err => {
    logErr(err.message);
    process.exit(1);
});
