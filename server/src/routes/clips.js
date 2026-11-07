// Last updated: May 9, 2026 - 7:19pm - GPT-5.3-Codex
/**
 * Clip Viewer — Authenticated page to view a video clip with metadata.
 * Requires cookie-based auth (phone + PIN + company code).
 * Accessible at GET /clips/:mediasourceId
 */
import prisma from '../lib/prisma.js';
import { MUX_ENV_KEY } from '../lib/mux.js';
import { verifyPin, hashPin, dbRetry } from '../lib/utils.js';
import { redactCompanyCode, redactPersonName, redactPhoneNumber } from '../lib/redact.js';
import { CLIP_COOKIE_NAME, clipCookieOpts } from '../lib/clipAuth.js';
import { icon } from '../lib/icons.js';
import { isAdminRole } from '../lib/roles.js';

/** Escape HTML special characters to prevent XSS (#5). */
function escapeHtml(str) {
    if (!str) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

/**
 * Compute a video's width/height ratio (as a decimal number) for sizing the
 * player + its loading placeholder identically and without layout shift.
 * Prefers the exact captured resolution (e.g. "1920x1080"); falls back to
 * the coarse client-reported orientation; defaults to 16:9 landscape.
 * Clamped to a sane range so bad/unexpected data can't produce an
 * unusably thin or tall player.
 */
function computeVideoRatio(clip) {
    const fromResolution = (resolution) => {
        const match = /(\d+)\s*[x×]\s*(\d+)/i.exec(resolution || '');
        if (!match) return null;
        const w = parseInt(match[1], 10);
        const h = parseInt(match[2], 10);
        return (w > 0 && h > 0) ? w / h : null;
    };
    const fromOrientation = (orientation) => {
        if (orientation === 'portrait') return 9 / 16;
        if (orientation === 'square') return 1;
        return 16 / 9; // landscape, unknown, or missing
    };
    const ratio = fromResolution(clip?.resolution) ?? fromOrientation(clip?.orientation);
    const clamped = Math.min(Math.max(ratio, 9 / 21), 21 / 9);
    return Math.round(clamped * 10000) / 10000;
}

export default async function clipRoutes(fastify) {

    // ─── Shared Styles ──────────────────────────────────────
    // Values below are sourced from /tokens.css (see <link> in googleFontsHead
    // and each page's <head>) — this block only contains structure/behavior,
    // matching the Admin Dashboard's "Clean Editorial" theme. See /DESIGN.md.
    const loginPageCSS = `
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { background: var(--background); color: var(--foreground); font-family: var(--font-sans);
               display: flex; align-items: center; justify-content: center;
               min-height: 100vh; padding: 24px; }
        .card { background: var(--card); border: 1px solid var(--border-subtle);
                border-radius: var(--radius-2xl); padding: 40px 32px; width: 100%; max-width: 380px; }
        .logo { text-align: center; margin-bottom: 24px; }
        .logo span { font-size: var(--text-3xl); }
        h1 { font-size: var(--text-lg); font-weight: 600; text-align: center; margin-bottom: 24px;
             color: var(--foreground); }
        label { display: block; font-size: var(--text-xs); font-weight: 600; letter-spacing: 0.05em;
                color: var(--muted-foreground); margin-bottom: 6px; text-transform: uppercase; }
        input { width: 100%; padding: 12px 14px; background: var(--secondary);
                border: 1px solid var(--border); border-radius: var(--radius-lg);
                color: var(--foreground); font-family: var(--font-sans); font-size: var(--text-base);
                margin-bottom: 16px; outline: none; transition: border-color 0.2s; }
        input:focus-visible { border-color: var(--ring); }
        input::placeholder { color: var(--muted-foreground); opacity: 0.6; }
        button { width: 100%; padding: 14px; background: var(--accent-blue);
                 color: var(--accent-foreground); border: none; border-radius: var(--radius-lg); font-family: var(--font-sans);
                 font-size: var(--text-base); font-weight: 600; cursor: pointer; transition: opacity 0.2s; }
        button:hover { opacity: 0.9; }
        button:disabled { opacity: 0.5; cursor: not-allowed; }
        .error { background: var(--accent-red-glow); border: 1px solid color-mix(in srgb, var(--accent-red) 30%, transparent);
                 border-radius: var(--radius-md); padding: 10px 14px; margin-bottom: 16px;
                 font-size: var(--text-sm); color: var(--accent-red); }
        .footer { text-align: center; margin-top: 20px; font-size: var(--text-xs);
                  color: var(--muted-foreground); }
    `;
    const googleFontsHead = '<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700&display=swap" rel="stylesheet"><link rel="stylesheet" href="/tokens.css">';

    // ─── Helper: verify clip cookie ─────────────────────────
    async function verifyClipCookie(request, reply) {
        const token = request.cookies?.[CLIP_COOKIE_NAME];
        if (!token) return null;
        try {
            const decoded = fastify.jwt.verify(token);
            request.user = decoded;
            return decoded;
        } catch {
            reply.clearCookie(CLIP_COOKIE_NAME, { path: '/clips' });
            return null;
        }
    }

    // ─── Helper: check org access ───────────────────────────
    // Admins see everything; regular users only see clips from their org
    function canAccessClip(viewer, clipUploaderCompanyCode) {
        if (!viewer) return false;
        if (isAdminRole(viewer.role)) return true;
        if (!viewer.companyCode) return false;
        if (!clipUploaderCompanyCode) return false;
        return viewer.companyCode.toLowerCase() === clipUploaderCompanyCode.toLowerCase();
    }

    /**
     * GET /clips/login
     * Render a login form for the clip viewer.
     */
    fastify.get('/clips/login', async (request, reply) => {
        // Already logged in? Redirect to the clip they wanted
        const user = await verifyClipCookie(request, reply);
        if (user && request.query.redirect) {
            return reply.redirect(request.query.redirect);
        }

        const error = request.query.error || '';
        const redirect = escapeHtml(request.query.redirect || '');
        const csrfToken = await reply.generateCsrf();

        const html = `<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Fixer — Sign In to View Clip</title>
${googleFontsHead}
<style>${loginPageCSS}</style>
</head><body>
<div class="card">
    <div class="logo"><span>${icon('clips', { size: '2em' })}</span></div>
    <h1>Sign in to view this clip</h1>
    ${error ? `<div class="error">${escapeHtml(error)}</div>` : ''}
    <form method="POST" action="/clips/login">
        <input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}" />
        <input type="hidden" name="redirect" value="${redirect}" />
        <label for="companyCode">Company Code</label>
        <input id="companyCode" name="companyCode" type="text" placeholder="ABC or ABCD"
               maxlength="4" pattern="[A-Za-z]{3,4}" required autocomplete="off" />
        <label for="phoneNumber">Phone Number</label>
        <input id="phoneNumber" name="phoneNumber" type="tel" placeholder="10-digit phone"
               maxlength="10" pattern="[0-9]{10}" required autocomplete="tel" />
        <label for="pin">PIN</label>
        <input id="pin" name="pin" type="password" placeholder="••••"
               maxlength="8" required autocomplete="current-password" />
        <button type="submit">Sign In</button>
    </form>
    <div class="footer">Fixer &middot; Secure Clip Viewer</div>
</div>
</body></html>`;

        reply.type('text/html').send(html);
    });

    /**
     * POST /clips/login
     * Validate credentials → set HttpOnly cookie → redirect to clip.
     */
    fastify.post('/clips/login', {
        preValidation: [fastify.csrfProtection],
        config: {
            rateLimit: { max: 5, timeWindow: '1 minute' },
        },
    }, async (request, reply) => {
        const { phoneNumber, pin, companyCode, redirect } = request.body || {};
        const redirectTo = redirect || '/clips/login';

        // Validate inputs
        if (!phoneNumber || !pin || !companyCode) {
            return reply.redirect(`/clips/login?error=${encodeURIComponent('All fields are required')}&redirect=${encodeURIComponent(redirectTo)}`);
        }

        // Look up user
        const user = await dbRetry(() => prisma.user.findUnique({
            where: { phoneNumber },
            include: { organization: true },
        }));

        if (!user || user.status !== 'ACTIVE') {
            return reply.redirect(`/clips/login?error=${encodeURIComponent('Invalid credentials')}&redirect=${encodeURIComponent(redirectTo)}`);
        }

        // Verify PIN
        if (!(await verifyPin(pin, user.pinHash))) {
            return reply.redirect(`/clips/login?error=${encodeURIComponent('Invalid credentials')}&redirect=${encodeURIComponent(redirectTo)}`);
        }

        // Verify company code
        if (!user.companyCode || user.companyCode.toLowerCase() !== companyCode.toLowerCase()) {
            return reply.redirect(`/clips/login?error=${encodeURIComponent('Invalid credentials')}&redirect=${encodeURIComponent(redirectTo)}`);
        }

        // Auto-migrate legacy SHA-256 hash to bcrypt
        if (user.pinHash && !user.pinHash.startsWith('$2')) {
            const bcryptHash = await hashPin(pin);
            await dbRetry(() => prisma.user.update({
                where: { id: user.id },
                data: { pinHash: bcryptHash },
            }));
        }

        // Generate JWT (7-day expiry)
        const token = fastify.jwt.sign(
            {
                id: user.id,
                phoneNumber: user.phoneNumber,
                name: user.name,
                role: user.role || 'USER',
                companyCode: user.companyCode || null,
            },
            { expiresIn: '7d' }
        );

        // Set HttpOnly cookie
        const isSecure = request.protocol === 'https';
        reply.setCookie(CLIP_COOKIE_NAME, token, clipCookieOpts(isSecure));

        request.log.info(
            {
                userName: redactPersonName(user.name),
                phoneNumber: redactPhoneNumber(user.phoneNumber),
                companyCode: redactCompanyCode(user.companyCode),
            },
            'Clip viewer login success'
        );

        // Redirect to the clip they wanted to view
        return reply.redirect(redirectTo.startsWith('/clips/') ? redirectTo : '/clips/login');
    });

    /**
     * POST /clips/logout
     * Clear the clip viewer cookie.
     */
    fastify.post('/clips/logout', async (request, reply) => {
        reply.clearCookie(CLIP_COOKIE_NAME, { path: '/clips' });
        return reply.redirect('/clips/login');
    });

    /**
     * GET /clips/:mediasourceId/status
     * Lightweight JSON endpoint — polled by the clip viewer JS when the video
     * is not yet ready. Requires clip auth cookie.
     */
    fastify.get('/clips/:mediasourceId/status', async (request, reply) => {
        // Auth check
        const viewer = await verifyClipCookie(request, reply);
        if (!viewer) return reply.status(401).send({ error: 'Unauthorized' });

        const { mediasourceId } = request.params;
        if (!mediasourceId || mediasourceId === 'undefined') {
            return reply.status(404).send({ error: 'Not found' });
        }
        const asset = await prisma.asset.findFirst({ where: { mediasourceId } });
        if (!asset) return reply.status(404).send({ error: 'Not found' });

        // Org access check
        const uploader = await prisma.user.findFirst({
            where: { id: asset.userId },
            select: { companyCode: true },
        });
        if (!canAccessClip(viewer, uploader?.companyCode)) {
            return reply.status(403).send({ error: 'Access denied' });
        }

        const clip = await prisma.clip.findFirst({
            where: { assetId: asset.id },
            orderBy: { createdAt: 'desc' },
            select: { muxPlaybackId: true, status: true },
        });

        const ready = !!(clip?.muxPlaybackId);
        return reply.send({
            ready,
            muxPlaybackId: ready ? clip.muxPlaybackId : null,
            status: asset.status,
        });
    });

    /**
     * GET /clips/:mediasourceId
     * Authenticated clip viewer page (shared Dashboard theme via /tokens.css, video player + metadata).
     * Requires cookie auth; org-scoped (admins see all).
     */
    fastify.get('/clips/:mediasourceId', async (request, reply) => {
        const { mediasourceId } = request.params;

        // ── Auth gate ──
        const viewer = await verifyClipCookie(request, reply);
        if (!viewer) {
            return reply.redirect(`/clips/login?redirect=${encodeURIComponent(request.url)}`);
        }

        // Reject obviously invalid IDs (e.g. "undefined", empty, non-numeric)
        if (!mediasourceId || mediasourceId === 'undefined' || mediasourceId === 'null') {
            reply.status(404).type('text/html').send(`
                <!DOCTYPE html>
                <html><head><title>Not Found</title>
                <link rel="stylesheet" href="/tokens.css">
                <style>body{background:var(--background);color:var(--foreground);font-family:var(--font-sans);display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
                h1{font-size:var(--text-2xl);opacity:0.7}</style></head>
                <body><h1>Clip not found</h1></body></html>
            `);
            return;
        }

        let asset;
        try {
            asset = await prisma.asset.findFirst({
                where: { mediasourceId },
            });

            // Clean up the 404 message
            if (!asset) {
                reply.status(404).type('text/html').send(`
                    <!DOCTYPE html>
                    <html><head><title>Not Found</title>
                    <link rel="stylesheet" href="/tokens.css">
                    <style>body{background:var(--background);color:var(--foreground);font-family:var(--font-sans);display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
                    h1{font-size:var(--text-2xl);opacity:0.7}</style></head>
                    <body><h1>Clip not found</h1></body></html>
                `);
                return;
            }

            // Fetch relations separately (Prisma 7 + pg adapter has issues with include in some contexts)
            const clips = await prisma.clip.findMany({ where: { assetId: asset.id }, orderBy: { createdAt: 'desc' } });
            const formResponse = await prisma.formResponse.findFirst({ where: { assetId: asset.id } });
            const user = await prisma.user.findFirst({
                where: { id: asset.userId },
                select: { name: true, team: true, companyCode: true, organization: { select: { companyName: true } } },
            });

            asset = { ...asset, clips, formResponse, user };

            // ── Org-scoped access check ──
            if (!canAccessClip(viewer, user?.companyCode)) {
                reply.status(403).type('text/html').send(`
                    <!DOCTYPE html>
                    <html><head><title>Access Denied</title>
                    <link rel="stylesheet" href="/tokens.css">
                    <style>body{background:var(--background);color:var(--foreground);font-family:var(--font-sans);display:flex;align-items:center;justify-content:center;height:100vh;margin:0;flex-direction:column;gap:12px}
                    h1{font-size:var(--text-2xl);opacity:0.7}p{font-size:var(--text-sm);opacity:0.4}a{color:var(--accent-blue)}</style></head>
                    <body><h1>${icon('locked', { size: '1.2em' })} Access Denied</h1><p>This clip belongs to a different organization.</p>
                    <a href="/clips/login">Sign in with a different account</a></body></html>
                `);
                return;
            }
        } catch (err) {
            fastify.log.error({ err, mediasourceId }, 'Clip viewer DB query failed');
            reply.status(500).type('text/html').send(`
                <!DOCTYPE html>
                <html><head><title>Error</title>
                <link rel="stylesheet" href="/tokens.css">
                <style>body{background:var(--background);color:var(--foreground);font-family:var(--font-sans);display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
                pre{font-size:var(--text-sm);opacity:0.7;max-width:600px;white-space:pre-wrap}</style></head>
                <body><pre>DB Error: ${escapeHtml(err.message)}</pre></body></html>
            `);
            return;
        }

        const clip = asset.clips?.[0];
        const form = asset.formResponse;
        // Width/height ratio for the player + its loading placeholder — computed
        // once here so both the initial render and the "processing → ready"
        // swap (see client script below) size the box identically. This is
        // known from upload-time metadata, independent of Mux encoding status,
        // so the player never changes size once the page has painted.
        const videoRatio = computeVideoRatio(clip);

        // ── Asset-level metadata ──
        const assetRows = [];
        assetRows.push({ icon: 'id', label: 'Asset ID', value: asset.id });
        if (asset.mediasourceId) assetRows.push({ icon: 'activity', label: 'Mediasource ID', value: asset.mediasourceId });
        if (asset.mediasourceUrl) assetRows.push({ icon: 'url', label: 'Mediasource URL', value: asset.mediasourceUrl });
        if (asset.originalFileName) assetRows.push({ icon: 'file', label: 'Original File', value: asset.originalFileName });
        if (asset.user) assetRows.push({ icon: 'user', label: 'Uploaded By', value: `${asset.user.name}${asset.user.team ? ' · ' + asset.user.team : ''}` });
        if (asset.user?.organization?.companyName) assetRows.push({ icon: 'organization', label: 'Organization', value: asset.user.organization.companyName });
        assetRows.push({ icon: 'status', label: 'Status', value: asset.status });
        if (asset.clipCount) assetRows.push({ icon: 'clipCount', label: 'Clip Count', value: String(asset.clipCount) });
        if (asset.totalDuration) {
            const m = Math.floor(asset.totalDuration / 60);
            const s = asset.totalDuration % 60;
            assetRows.push({ icon: 'duration', label: 'Total Duration', value: `${m}:${String(s).padStart(2, '0')}` });
        }
        assetRows.push({ icon: 'date', label: 'Created', value: new Date(asset.createdAt).toLocaleString() });
        assetRows.push({ icon: 'refresh', label: 'Updated', value: new Date(asset.updatedAt).toLocaleString() });

        // ── Clip-level metadata (video technical) ──
        const clipRows = [];
        if (clip) {
            clipRows.push({ icon: 'id', label: 'Clip ID', value: clip.id });
            if (clip.originalFileName) clipRows.push({ icon: 'file', label: 'Original File', value: clip.originalFileName });
            if (clip.codec) clipRows.push({ icon: 'video', label: 'Codec', value: clip.codec });
            if (clip.resolution) clipRows.push({ icon: 'resolution', label: 'Resolution', value: clip.resolution });
            if (clip.orientation) clipRows.push({ icon: 'orientation', label: 'Orientation', value: clip.orientation });
            if (clip.duration) {
                const min = Math.floor(clip.duration / 60);
                const sec = clip.duration % 60;
                clipRows.push({ icon: 'duration', label: 'Duration', value: `${min}:${String(sec).padStart(2, '0')}` });
            }
            if (clip.fileSize) {
                const bytes = Number(clip.fileSize);
                const mb = bytes / 1_000_000;
                clipRows.push({ icon: 'fileSize', label: 'File Size', value: mb >= 1000 ? `${(mb / 1000).toFixed(2)} GB` : `${mb.toFixed(1)} MB` });
            }
            if (clip.deviceModel) clipRows.push({ icon: 'device', label: 'Device', value: clip.deviceModel });
            if (clip.osVersion) clipRows.push({ icon: 'settings', label: 'OS Version', value: clip.osVersion });
            if (clip.capturedAt) clipRows.push({ icon: 'time', label: 'Captured At', value: new Date(clip.capturedAt).toLocaleString() });
            if (clip.gpsLat && clip.gpsLon) {
                const lat = clip.gpsLat.toFixed(6);
                const lon = clip.gpsLon.toFixed(6);
                clipRows.push({ icon: 'gps', label: 'GPS', value: `${lat}, ${lon}`, link: `https://maps.google.com/?q=${lat},${lon}` });
            }
            if (clip.gpsAltitude != null) clipRows.push({ icon: 'altitude', label: 'Altitude', value: `${clip.gpsAltitude.toFixed(1)} m` });
            clipRows.push({ icon: 'status', label: 'Clip Status', value: clip.status });
            if (clip.storageUrl) clipRows.push({ icon: 'storage', label: 'Storage URL', value: clip.storageUrl });
            if (clip.streamUrl) clipRows.push({ icon: 'stream', label: 'Stream URL', value: clip.streamUrl });
            if (clip.muxAssetId) clipRows.push({ icon: 'clips', label: 'Mux Asset ID', value: clip.muxAssetId });
            if (clip.muxPlaybackId) clipRows.push({ icon: 'play', label: 'Mux Playback ID', value: clip.muxPlaybackId });
            if (clip.muxUploadId) clipRows.push({ icon: 'outgoing', label: 'Mux Upload ID', value: clip.muxUploadId });
            clipRows.push({ icon: 'date', label: 'Clip Created', value: new Date(clip.createdAt).toLocaleString() });
        }

        // ── Form response metadata ──
        const formRows = [];
        if (form) {
            formRows.push({ icon: 'id', label: 'Form ID', value: form.id });
            if (form.slug) formRows.push({ icon: 'tag', label: 'Slug / Title', value: form.slug });
            if (form.type) formRows.push({ icon: 'form', label: 'Type', value: form.type });
            if (form.priority) formRows.push({ icon: 'priority', label: 'Priority', value: form.priority });
            if (form.description) formRows.push({ icon: 'description', label: 'Description', value: form.description });
            if (form.extra) formRows.push({ icon: 'assets', label: 'Extra Data', value: JSON.stringify(form.extra) });
            formRows.push({ icon: 'date', label: 'Submitted', value: new Date(form.submittedAt).toLocaleString() });
        }

        // Build HTML helper
        const renderRows = (rows) => rows.map(r => {
            const val = r.link
                ? `<a href="${escapeHtml(r.link)}" target="_blank" rel="noopener" style="color:var(--accent-blue);text-decoration:underline;text-underline-offset:2px">${escapeHtml(r.value)} ${icon('arrowUpRight', { size: '0.85em' })}</a>`
                : escapeHtml(r.value);
            return `<div class="meta-row"><span class="meta-icon">${icon(r.icon)}</span><span class="meta-label">${escapeHtml(r.label)}</span><span class="meta-value">${val}</span></div>`;
        }).join('\n');

        const hasMuxPlayback = !!(clip?.muxPlaybackId);
        const muxPlaybackId = clip?.muxPlaybackId || '';
        const muxEnvKey = MUX_ENV_KEY || '';

        // Display title: form_response.slug or mediasourceId
        const displayTitle = form?.slug || `#${asset.mediasourceId || 'Unknown'}`;
        const displayOwner = asset.user ? `@${asset.user.name}` : '';

        // Mux Player uses a web component — only load when we have a playback ID
        const muxPlayerScript = hasMuxPlayback
            ? `<script src="https://cdn.jsdelivr.net/npm/@mux/mux-player@latest"></script>`
            : '';

        const googleFontsLink = `<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet"><link rel="stylesheet" href="/tokens.css">`;

        // Precomputed copy-link button labels (client-side JS below sets these
        // via innerHTML since they contain the inline icon SVG).
        const copyLinkLabel = `${icon('copy', { size: '0.9em' })} Copy Link`;
        const copyLinkCopiedLabel = `${icon('success', { size: '0.9em' })} Copied!`;

        const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${escapeHtml(displayTitle)} — Mediasource Viewer</title>
    ${googleFontsLink}
    ${muxPlayerScript}
    <style>
        /* Design tokens (colors, radius, type scale) come from /tokens.css —
           the same file the Admin Dashboard links. See /DESIGN.md. This
           block is structure/layout only. */
        *, *::before, *::after { box-sizing: border-box; }
        body, h1, h2, h3, p, div, span { margin: 0; padding: 0; }
        body {
            background: var(--background);
            color: var(--foreground);
            font-family: 'Outfit', sans-serif;
            min-height: 100vh;
            -webkit-text-size-adjust: 100%;
        }
        a { color: var(--muted-foreground); }
        .container {
            max-width: 820px;
            margin: 0 auto;
            padding: 32px 20px 64px;
        }
        /* ── Top nav bar ── */
        .topbar {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding-bottom: 24px;
            margin-bottom: 32px;
            border-bottom: 1px solid var(--border-subtle);
        }
        .topbar-brand {
            display: flex;
            align-items: center;
            gap: 12px;
        }
        .topbar-icon {
            width: 44px;
            height: 44px;
            border-radius: var(--radius-lg);
            overflow: hidden;
            flex-shrink: 0;
            box-shadow: 0 4px 16px color-mix(in srgb, var(--accent-blue) 25%, transparent);
        }
        .topbar-icon img { width: 100%; height: 100%; object-fit: cover; }
        .topbar-title {
            font-size: var(--text-xl);
            font-weight: 700;
            letter-spacing: -0.01em;
        }
        .topbar-sub {
            font-size: var(--text-xs);
            color: var(--muted-foreground);
            margin-top: 2px;
        }
        .topbar-right {
            text-align: right;
        }
        .topbar-right .owner {
            font-size: var(--text-base);
            font-weight: 600;
        }
        .topbar-right .team {
            font-size: var(--text-xs);
            color: var(--muted-foreground);
        }
        /* ── Clip title block ── */
        .clip-title-block {
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            gap: 12px;
            margin-bottom: 20px;
        }
        .clip-title-left { flex: 1; min-width: 0; }
        .clip-title-block h1 {
            font-size: var(--text-2xl);
            font-weight: 700;
            letter-spacing: -0.01em;
            word-break: break-word;
        }
        .clip-title-block .msid {
            font-family: 'JetBrains Mono', monospace;
            font-size: var(--text-xs);
            color: var(--muted-foreground);
            margin-top: 4px;
        }
        .dashboard-link {
            display: inline-flex;
            align-items: center;
            gap: 5px;
            font-size: var(--text-sm);
            font-weight: 500;
            color: var(--accent-blue);
            text-decoration: none;
            white-space: nowrap;
            padding: 6px 12px;
            border: 1px solid var(--border-subtle);
            border-radius: var(--radius-lg);
            background: var(--card);
            flex-shrink: 0;
            margin-top: 4px;
        }
        .dashboard-link:hover { border-color: var(--accent-blue); }
        /* ── Card panel ── */
        .card {
            background: var(--card);
            border: 1px solid var(--border-subtle);
            border-radius: var(--radius-xl);
            overflow: hidden;
            margin-bottom: 20px;
        }
        .card-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 14px 20px;
            border-bottom: 1px solid var(--border-subtle);
        }
        .card-header h3 {
            font-size: var(--text-sm);
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 6px;
        }
        /* ── Video ──
           .video-wrap is sized from --video-ratio (set per-request via inline
           style, computed server-side from the clip's actual resolution/
           orientation — see computeVideoRatio()). This keeps portrait and
           landscape clips correctly letterboxed and capped to a sane share of
           the viewport on both desktop and mobile, instead of the player
           sizing itself from raw video pixels once metadata loads (which is
           what let tall/vertical videos blow past the viewport). */
        .video-wrap {
            --video-max-h: 70vh;
            position: relative;
            width: min(100%, calc(var(--video-max-h) * var(--video-ratio, 1.7778)));
            max-height: var(--video-max-h);
            aspect-ratio: var(--video-ratio, 16 / 9);
            margin: 0 auto;
            background: var(--secondary);
            overflow: hidden;
        }
        .video-wrap mux-player {
            width: 100%;
            height: 100%;
            display: block;
            --media-object-fit: contain;
            --media-object-position: center;
        }
        /* Loading placeholder — shown (a) while Mux is still processing the
           upload, sized identically to the eventual player, and (b) as an
           overlay on top of a just-inserted <mux-player> until it reports
           it's actually ready to paint a frame, so there's always a visible
           "this is loading" signal instead of a blank box. */
        .video-placeholder {
            position: absolute;
            inset: 0;
            z-index: 2;
            width: 100%;
            height: 100%;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            gap: 16px;
            background: var(--secondary);
            color: var(--muted-foreground);
            overflow: hidden;
            transition: opacity 0.25s ease;
        }
        .video-placeholder.is-hidden {
            opacity: 0;
            pointer-events: none;
        }
        /* Subtle animated shimmer across the placeholder */
        .video-placeholder::after {
            content: '';
            position: absolute;
            inset: 0;
            background: linear-gradient(105deg, transparent 40%, color-mix(in srgb, var(--foreground) 4%, transparent) 50%, transparent 60%);
            animation: shimmer 2.4s ease-in-out infinite;
            background-size: 200% 100%;
        }
        @keyframes shimmer {
            0%   { background-position: 200% 0; }
            100% { background-position: -200% 0; }
        }
        .placeholder-icon {
            font-size: var(--text-4xl);
            opacity: 0.4;
            animation: pulse-icon 2s ease-in-out infinite;
        }
        @keyframes pulse-icon {
            0%, 100% { opacity: 0.4; transform: scale(1); }
            50%       { opacity: 0.65; transform: scale(1.08); }
        }
        .placeholder-label {
            font-size: var(--text-sm);
            font-weight: 500;
            letter-spacing: 0.02em;
        }
        .placeholder-sub {
            font-size: var(--text-xs);
            opacity: 0.6;
        }
        .no-video {
            padding: 60px 20px;
            text-align: center;
            color: var(--muted-foreground);
            font-size: var(--text-sm);
        }
        /* ── Video bar (status + copy link) ── */
        .video-bar {
            display: flex;
            align-items: center;
            gap: 8px;
            padding: 12px 20px;
        }
        /* Status pill */
        .status {
            display: inline-block;
            padding: 3px 14px;
            border-radius: var(--radius-full);
            font-size: var(--text-xs);
            font-weight: 600;
            letter-spacing: 0.05em;
        }
        .status-READY     { background: var(--accent-green-glow); color: var(--accent-green); border: 1px solid color-mix(in srgb, var(--accent-green) 25%, transparent); }
        .status-PROCESSING { background: var(--accent-amber-glow); color: var(--accent-amber); border: 1px solid color-mix(in srgb, var(--accent-amber) 25%, transparent); }
        .status-UPLOADING  { background: var(--accent-blue-glow);  color: var(--accent-blue);  border: 1px solid color-mix(in srgb, var(--accent-blue) 25%, transparent); }
        .status-ERROR      { background: var(--accent-red-glow);   color: var(--accent-red);   border: 1px solid color-mix(in srgb, var(--accent-red) 25%, transparent); }
        /* Copy link button */
        .copy-link {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            background: var(--secondary);
            color: var(--foreground);
            border: 1px solid var(--border);
            border-radius: var(--radius-lg);
            padding: 6px 14px;
            font-size: var(--text-xs);
            font-weight: 500;
            cursor: pointer;
            transition: all 0.2s;
            font-family: inherit;
        }
        .copy-link:hover { background: var(--card-hover); border-color: var(--accent-blue); }
        .copy-link:active { transform: scale(0.96); }
        .copy-link.copied {
            background: var(--accent-green-glow);
            color: var(--accent-green);
            border-color: color-mix(in srgb, var(--accent-green) 30%, transparent);
        }
        /* ── Metadata rows ── */
        .meta-row {
            display: grid;
            grid-template-columns: 28px 130px 1fr;
            align-items: center;
            gap: 0 8px;
            padding: 14px 20px;
            border-bottom: 1px solid var(--border-subtle);
        }
        .meta-row:last-child { border-bottom: none; }
        .meta-icon { font-size: var(--text-base); line-height: 1; }
        .meta-label {
            font-size: var(--text-sm);
            color: var(--muted-foreground);
        }
        .meta-value {
            font-size: var(--text-sm);
            font-weight: 500;
            color: var(--foreground);
            min-width: 0;
            overflow-wrap: break-word;
            max-width: 65ch;
        }
        .meta-value a { color: var(--accent-blue); text-underline-offset: 2px; }
        /* Priority badges */
        .priority-critical { color: var(--accent-red); }
        .priority-high { color: var(--accent-amber); }
        .priority-medium { color: var(--accent-green); }
        .priority-low { color: var(--muted-foreground); }
        /* ── Alert banner ── */
        .alert-banner {
            display: flex;
            align-items: center;
            gap: 10px;
            padding: 14px 20px;
            border-radius: var(--radius-xl);
            background: var(--accent-red-glow);
            border: 1px solid color-mix(in srgb, var(--accent-red) 25%, transparent);
            margin-bottom: 20px;
        }
        .alert-banner .alert-icon { font-size: var(--text-xl); flex-shrink: 0; }
        .alert-banner .alert-title {
            font-size: var(--text-sm);
            font-weight: 600;
            color: var(--accent-red);
        }
        .alert-banner .alert-detail {
            font-size: var(--text-sm);
            color: var(--muted-foreground);
        }
        /* ── Footer ── */
        .footer {
            text-align: center;
            padding-top: 32px;
            border-top: 1px solid var(--border-subtle);
            margin-top: 8px;
        }
        .footer .logo {
            font-size: var(--text-sm);
            font-weight: 600;
            color: var(--muted-foreground);
            letter-spacing: 1px;
            opacity: 0.5;
        }
        /* ── Mobile ── */
        @media (max-width: 640px) {
            .container { padding: 16px 16px 48px; }

            /* Mobile viewports are already narrow and often taller-than-wide
               (especially in portrait), so give the player more vertical
               room than on desktop — it's less likely to dominate the page. */
            .video-wrap { --video-max-h: 80vh; }

            .topbar {
                padding-bottom: 16px;
                margin-bottom: 20px;
            }
            .topbar-title { font-size: var(--text-lg); }

            .clip-title-block h1 { font-size: var(--text-lg); }

            /* Card header: allow wrapping */
            .card-header {
                flex-wrap: wrap;
                gap: 6px;
                padding: 12px 16px;
            }

            /* Video bar: stack status + button */
            .video-bar {
                padding: 10px 16px;
                gap: 8px;
            }

            /* Meta rows: collapse to 2-column (icon | label+value stacked) */
            .meta-row {
                grid-template-columns: 28px 1fr;
                gap: 2px 8px;
                padding: 10px 16px;
            }
            .meta-label {
                grid-column: 2;
                font-size: var(--text-xs);
                text-transform: uppercase;
                letter-spacing: 0.5px;
            }
            .meta-value { grid-column: 2; font-size: var(--text-sm); }
            .meta-icon { grid-row: span 2; align-self: start; padding-top: 2px; }

            /* Alert banner */
            .alert-banner { padding: 12px 16px; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="topbar">
            <div class="topbar-brand">
                <div class="topbar-icon"><img src="/fixer-icon.png" alt="Fixer" /></div>
                <div>
                    <div class="topbar-title">Fixer</div>
                    <div class="topbar-sub">Mediasource Viewer</div>
                </div>
            </div>
            ${asset.user ? `<div class="topbar-right">
                <div class="owner">@${escapeHtml(asset.user.name)}</div>
                ${asset.user.team ? `<div class="team">${escapeHtml(asset.user.team)}</div>` : ''}
            </div>` : ''}
        </div>

        <div class="clip-title-block">
            <div class="clip-title-left">
                <h1>${escapeHtml(displayTitle)}</h1>
                ${asset.mediasourceId ? `<div class="msid">#${escapeHtml(asset.mediasourceId)}</div>` : ''}
            </div>
            <a href="/" class="dashboard-link">${icon('arrowLeft', { size: '0.85em' })} Dashboard</a>
        </div>

        <div class="card" id="video-card">
            <div class="video-wrap" style="--video-ratio: ${videoRatio}">
                ${hasMuxPlayback
                    ? `<!-- accent-color below must stay in sync with --accent-blue in tokens.css; a custom-element attribute can't reference a CSS var -->
                  <mux-player
                    id="mux-player-el"
                    stream-type="on-demand"
                    playback-id="${escapeHtml(muxPlaybackId)}"
                    ${MUX_ENV_KEY ? `env-key="${escapeHtml(MUX_ENV_KEY)}"` : ''}
                    metadata-video-title="${escapeHtml(displayTitle)}"
                    accent-color="#4a9eff"
                    preload="auto"
                  ></mux-player>
                  <div class="video-placeholder" id="video-loading">
                    <div class="placeholder-icon">${icon('clips', { size: '2.5em' })}</div>
                    <div class="placeholder-label">Loading video&hellip;</div>
                  </div>`
                    : `<div class="video-placeholder" id="video-placeholder">
                    <div class="placeholder-icon">${icon('clips', { size: '2.5em' })}</div>
                    <div class="placeholder-label">Video Processing</div>
                    <div class="placeholder-sub" id="placeholder-status">${escapeHtml(asset.status)} &mdash; checking every 5s&hellip;</div>
                   </div>`
                }
            </div>
            <div class="video-bar">
                <span class="status status-${escapeHtml(asset.status)}" id="status-pill">${escapeHtml(asset.status)}</span>
                <button class="copy-link" id="copy-link-btn">${copyLinkLabel}</button>
            </div>
        </div>

        ${!form && asset.status === 'READY' ? `
        <div class="alert-banner">
            <span class="alert-icon">${icon('alert')}</span>
            <div>
                <div class="alert-title">NO CONTEXT FORM</div>
                <div class="alert-detail">Slug and description are missing for this asset.</div>
            </div>
        </div>
        ` : ''}

        ${clipRows.length > 0 ? `
        <div class="card">
            <div class="card-header"><h3>${icon('video', { size: '0.9em' })} Video / Clip</h3></div>
            ${renderRows(clipRows)}
        </div>
        ` : ''}

        ${formRows.length > 0 ? `
        <div class="card">
            <div class="card-header"><h3>${icon('form', { size: '0.9em' })} Context Form</h3></div>
            ${renderRows(formRows)}
        </div>
        ` : ''}

        ${clip?.transcript ? `
        <div class="card">
            <div class="card-header"><h3>${icon('transcript', { size: '0.9em' })} Transcript</h3></div>
            <div style="padding:16px">
                <p style="font-size:var(--text-sm);line-height:1.6;color:var(--foreground);white-space:pre-wrap;max-height:300px;overflow-y:auto">${escapeHtml(clip.transcript)}</p>
            </div>
        </div>
        ` : ''}

        ${assetRows.length > 0 ? `
        <div class="card">
            <div class="card-header"><h3>${icon('assets', { size: '0.9em' })} Asset</h3></div>
            ${renderRows(assetRows)}
        </div>
        ` : ''}

        <div class="footer">
            <div class="logo">MEDIASOURCE FIXER</div>
        </div>
    </div>
    <script>
    // Hides a loading-placeholder overlay once its <mux-player> sibling is
    // actually ready to show a frame (or after a safety timeout, in case the
    // event never fires for some reason — better a stale overlay disappears
    // late than one that's stuck forever).
    function hideOverlayWhenReady(player, overlay) {
        if (!player || !overlay) return;
        let done = false;
        const hide = () => {
            if (done) return;
            done = true;
            overlay.classList.add('is-hidden');
            setTimeout(() => overlay.remove(), 300);
        };
        player.addEventListener('loadeddata', hide, { once: true });
        player.addEventListener('error', hide, { once: true });
        setTimeout(hide, 8000);
    }

    // Wire up the loading overlay for the player rendered at page load (if any).
    (function initialOverlay() {
        const player  = document.getElementById('mux-player-el');
        const overlay = document.getElementById('video-loading');
        hideOverlayWhenReady(player, overlay);
    })();

    function copyLink(btn) {
        navigator.clipboard.writeText(window.location.href).then(() => {
            btn.innerHTML = '${copyLinkCopiedLabel}';
            btn.classList.add('copied');
            setTimeout(() => {
                btn.innerHTML = '${copyLinkLabel}';
                btn.classList.remove('copied');
            }, 2000);
        }).catch(() => {
            // Fallback for older browsers
            const tmp = document.createElement('input');
            tmp.value = window.location.href;
            document.body.appendChild(tmp);
            tmp.select();
            document.execCommand('copy');
            document.body.removeChild(tmp);
            btn.innerHTML = '${copyLinkCopiedLabel}';
            btn.classList.add('copied');
            setTimeout(() => {
                btn.innerHTML = '${copyLinkLabel}';
                btn.classList.remove('copied');
            }, 2000);
        });
    }

    // Wired up here (instead of an inline onclick="" attribute) because the
    // production CSP sets script-src-attr 'none' — inline event-handler
    // attributes are silently blocked even though inline <script> tags are
    // allowed, so onclick="copyLink(this)" never fired.
    const copyLinkBtn = document.getElementById('copy-link-btn');
    if (copyLinkBtn) copyLinkBtn.addEventListener('click', () => copyLink(copyLinkBtn));

    // ── Video readiness polling ───────────────────────────────────────
    // Only runs when the placeholder is visible (video not yet ready).
    // Polls /clips/:mediasourceId/status every 5 seconds.
    // When Mux signals ready, loads the SDK and swaps in the real player.
    (function initVideoPoller() {
        const placeholder = document.getElementById('video-placeholder');
        if (!placeholder) return; // Already showing the player — nothing to do

        const mediasourceId = '${escapeHtml(asset.mediasourceId || '')}';
        const envKey        = '${escapeHtml(MUX_ENV_KEY || '')}';
        const videoTitle    = '${escapeHtml(displayTitle)}';
        const statusSub     = document.getElementById('placeholder-status');
        const statusPill    = document.getElementById('status-pill');

        let attempts = 0;
        const MAX_ATTEMPTS = 72; // 72 × 5s = 6 minutes before giving up

        async function checkStatus() {
            try {
                const res  = await fetch('/clips/' + mediasourceId + '/status');
                const data = await res.json();

                // Update the status text while waiting
                if (statusSub) {
                    statusSub.textContent = (data.status || 'PROCESSING') + ' — checking every 5s\u2026';
                }
                if (statusPill) {
                    statusPill.textContent  = data.status || 'PROCESSING';
                    statusPill.className    = 'status status-' + (data.status || 'PROCESSING');
                }

                if (data.ready && data.muxPlaybackId) {
                    // ── Video is ready — load SDK and swap in the player ──
                    clearInterval(poller);

                    // Dynamically load the Mux Player SDK
                    const script = document.createElement('script');
                    script.src = 'https://cdn.jsdelivr.net/npm/@mux/mux-player@latest';
                    script.onload = () => {
                        // Create the mux-player element
                        const player = document.createElement('mux-player');
                        player.setAttribute('stream-type', 'on-demand');
                        player.setAttribute('playback-id', data.muxPlaybackId);
                        if (envKey) player.setAttribute('env-key', envKey);
                        player.setAttribute('metadata-video-title', videoTitle);
                        player.setAttribute('accent-color', '#4a9eff'); // keep in sync with --accent-blue in tokens.css
                        player.setAttribute('preload', 'auto');
                        player.style.width = '100%';
                        player.style.height = '100%';
                        player.style.display = 'block';

                        // Insert the player behind the placeholder (.video-wrap
                        // is already sized from --video-ratio, set at initial
                        // render from the clip's real resolution/orientation —
                        // no aspect-ratio to (re)compute here, so no layout
                        // shift). Re-purpose the placeholder as a "loading
                        // video…" overlay until the player reports a frame is
                        // actually ready, then fade it out.
                        const wrap = placeholder.parentElement;
                        wrap.insertBefore(player, placeholder);
                        placeholder.id = 'video-loading';
                        placeholder.innerHTML =
                            '<div class="placeholder-icon">${icon('clips', { size: '2.5em' })}</div>' +
                            '<div class="placeholder-label">Loading video&hellip;</div>';
                        hideOverlayWhenReady(player, placeholder);

                        // Update status pill to READY
                        if (statusPill) {
                            statusPill.textContent = 'READY';
                            statusPill.className   = 'status status-READY';
                        }
                    };
                    document.head.appendChild(script);
                    return;
                }
            } catch (e) {
                // Network error — silently retry
            }

            attempts++;
            if (attempts >= MAX_ATTEMPTS) {
                clearInterval(poller);
                if (statusSub) statusSub.textContent = 'Processing is taking longer than expected — try refreshing.';
            }
        }

        const poller = setInterval(checkStatus, 5000);
        checkStatus(); // Run immediately on load too
    })();
    </script>

</body>
</html>`;

        reply.type('text/html').send(html);
    });
}
