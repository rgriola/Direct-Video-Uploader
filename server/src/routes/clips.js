// Last updated: May 9, 2026 - 6:07pm
/**
 * Clip Viewer — Authenticated page to view a video clip with metadata.
 * Requires cookie-based auth (phone + PIN + company code).
 * Accessible at GET /clips/:mediasourceId
 */
import prisma from '../lib/prisma.js';
import { MUX_ENV_KEY } from '../lib/mux.js';
import { verifyPin, hashPin, dbRetry } from '../lib/utils.js';

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

export default async function clipRoutes(fastify) {

    // ─── Shared Styles ──────────────────────────────────────
    const loginPageCSS = `
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { background: #0E0F14; color: #E2E4ED; font-family: 'Outfit', sans-serif;
               display: flex; align-items: center; justify-content: center;
               min-height: 100vh; padding: 24px; }
        .card { background: #16171E; border: 1px solid rgba(255,255,255,0.06);
                border-radius: 16px; padding: 40px 32px; width: 100%; max-width: 380px; }
        .logo { text-align: center; margin-bottom: 24px; }
        .logo span { font-size: 28px; }
        h1 { font-size: 1.1rem; font-weight: 600; text-align: center; margin-bottom: 24px;
             color: rgba(226,228,237,0.7); }
        label { display: block; font-size: 0.75rem; font-weight: 600; letter-spacing: 0.05em;
                color: rgba(226,228,237,0.4); margin-bottom: 6px; text-transform: uppercase; }
        input { width: 100%; padding: 12px 14px; background: rgba(255,255,255,0.04);
                border: 1px solid rgba(255,255,255,0.08); border-radius: 10px;
                color: #E2E4ED; font-family: 'Outfit', sans-serif; font-size: 0.95rem;
                margin-bottom: 16px; outline: none; transition: border-color 0.2s; }
        input:focus { border-color: rgba(168,85,247,0.5); }
        input::placeholder { color: rgba(226,228,237,0.2); }
        button { width: 100%; padding: 14px; background: linear-gradient(135deg, #A855F7, #7C3AED);
                 color: white; border: none; border-radius: 10px; font-family: 'Outfit', sans-serif;
                 font-size: 1rem; font-weight: 600; cursor: pointer; transition: opacity 0.2s; }
        button:hover { opacity: 0.9; }
        button:disabled { opacity: 0.5; cursor: not-allowed; }
        .error { background: rgba(239,68,68,0.1); border: 1px solid rgba(239,68,68,0.3);
                 border-radius: 8px; padding: 10px 14px; margin-bottom: 16px;
                 font-size: 0.85rem; color: #F87171; }
        .footer { text-align: center; margin-top: 20px; font-size: 0.7rem;
                  color: rgba(226,228,237,0.2); }
    `;
    const googleFontsHead = '<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700&display=swap" rel="stylesheet">';

    // Cookie options — HttpOnly, 7-day expiry, scoped to /clips
    const COOKIE_NAME = 'fixer_clip_token';
    const cookieOpts = (isSecure) => ({
        path: '/clips',
        httpOnly: true,
        secure: isSecure,
        sameSite: 'lax',
        maxAge: 7 * 24 * 60 * 60, // 7 days in seconds
    });

    // ─── Helper: verify clip cookie ─────────────────────────
    async function verifyClipCookie(request, reply) {
        const token = request.cookies?.[COOKIE_NAME];
        if (!token) return null;
        try {
            const decoded = fastify.jwt.verify(token);
            request.user = decoded;
            return decoded;
        } catch {
            reply.clearCookie(COOKIE_NAME, { path: '/clips' });
            return null;
        }
    }

    // ─── Helper: check org access ───────────────────────────
    // Admins see everything; regular users only see clips from their org
    function canAccessClip(viewer, clipUploaderCompanyCode) {
        if (!viewer) return false;
        if (viewer.role === 'ADMIN') return true;
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
    <div class="logo"><span>🎬</span></div>
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
        reply.setCookie(COOKIE_NAME, token, cookieOpts(isSecure));

        console.log(`🔐 Clip login: ${user.name} (${user.phoneNumber}) [${user.companyCode}]`);

        // Redirect to the clip they wanted to view
        return reply.redirect(redirectTo.startsWith('/clips/') ? redirectTo : '/clips/login');
    });

    /**
     * POST /clips/logout
     * Clear the clip viewer cookie.
     */
    fastify.post('/clips/logout', async (request, reply) => {
        reply.clearCookie(COOKIE_NAME, { path: '/clips' });
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
     * Authenticated clip viewer page (dark theme, video player + metadata).
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
                <style>body{background:#0E0F14;color:#E2E4ED;font-family:'Outfit',sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
                h1{font-size:1.5rem;opacity:0.7}</style></head>
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
                    <style>body{background:#0E0F14;color:#E2E4ED;font-family:'Outfit',sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
                    h1{font-size:1.5rem;opacity:0.7}</style></head>
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
                    <style>body{background:#0E0F14;color:#E2E4ED;font-family:'Outfit',sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;flex-direction:column;gap:12px}
                    h1{font-size:1.5rem;opacity:0.7}p{font-size:0.9rem;opacity:0.4}a{color:#A855F7}</style></head>
                    <body><h1>🔒 Access Denied</h1><p>This clip belongs to a different organization.</p>
                    <a href="/clips/login">Sign in with a different account</a></body></html>
                `);
                return;
            }
        } catch (err) {
            fastify.log.error({ err, mediasourceId }, 'Clip viewer DB query failed');
            reply.status(500).type('text/html').send(`
                <!DOCTYPE html>
                <html><head><title>Error</title>
                <style>body{background:#0E0F14;color:#E2E4ED;font-family:'Outfit',sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
                pre{font-size:0.9rem;opacity:0.7;max-width:600px;white-space:pre-wrap}</style></head>
                <body><pre>DB Error: ${escapeHtml(err.message)}</pre></body></html>
            `);
            return;
        }

        const clip = asset.clips?.[0];
        const form = asset.formResponse;

        // ── Asset-level metadata ──
        const assetRows = [];
        assetRows.push({ icon: '🆔', label: 'Asset ID', value: asset.id });
        if (asset.mediasourceId) assetRows.push({ icon: '📡', label: 'Mediasource ID', value: asset.mediasourceId });
        if (asset.mediasourceUrl) assetRows.push({ icon: '🌐', label: 'Mediasource URL', value: asset.mediasourceUrl });
        if (asset.originalFileName) assetRows.push({ icon: '📄', label: 'Original File', value: asset.originalFileName });
        if (asset.user) assetRows.push({ icon: '👤', label: 'Uploaded By', value: `${asset.user.name}${asset.user.team ? ' · ' + asset.user.team : ''}` });
        if (asset.user?.organization?.companyName) assetRows.push({ icon: '🏢', label: 'Organization', value: asset.user.organization.companyName });
        assetRows.push({ icon: '📊', label: 'Status', value: asset.status });
        if (asset.clipCount) assetRows.push({ icon: '🎞', label: 'Clip Count', value: String(asset.clipCount) });
        if (asset.totalDuration) {
            const m = Math.floor(asset.totalDuration / 60);
            const s = asset.totalDuration % 60;
            assetRows.push({ icon: '⏱', label: 'Total Duration', value: `${m}:${String(s).padStart(2, '0')}` });
        }
        assetRows.push({ icon: '📅', label: 'Created', value: new Date(asset.createdAt).toLocaleString() });
        assetRows.push({ icon: '🔄', label: 'Updated', value: new Date(asset.updatedAt).toLocaleString() });

        // ── Clip-level metadata (video technical) ──
        const clipRows = [];
        if (clip) {
            clipRows.push({ icon: '🆔', label: 'Clip ID', value: clip.id });
            if (clip.originalFileName) clipRows.push({ icon: '📄', label: 'Original File', value: clip.originalFileName });
            if (clip.codec) clipRows.push({ icon: '🎥', label: 'Codec', value: clip.codec });
            if (clip.resolution) clipRows.push({ icon: '📐', label: 'Resolution', value: clip.resolution });
            if (clip.orientation) clipRows.push({ icon: '↔️', label: 'Orientation', value: clip.orientation });
            if (clip.duration) {
                const min = Math.floor(clip.duration / 60);
                const sec = clip.duration % 60;
                clipRows.push({ icon: '⏱', label: 'Duration', value: `${min}:${String(sec).padStart(2, '0')}` });
            }
            if (clip.fileSize) {
                const bytes = Number(clip.fileSize);
                const mb = bytes / 1_000_000;
                clipRows.push({ icon: '📁', label: 'File Size', value: mb >= 1000 ? `${(mb / 1000).toFixed(2)} GB` : `${mb.toFixed(1)} MB` });
            }
            if (clip.deviceModel) clipRows.push({ icon: '📱', label: 'Device', value: clip.deviceModel });
            if (clip.osVersion) clipRows.push({ icon: '⚙️', label: 'OS Version', value: clip.osVersion });
            if (clip.capturedAt) clipRows.push({ icon: '🕐', label: 'Captured At', value: new Date(clip.capturedAt).toLocaleString() });
            if (clip.gpsLat && clip.gpsLon) {
                const lat = clip.gpsLat.toFixed(6);
                const lon = clip.gpsLon.toFixed(6);
                clipRows.push({ icon: '📍', label: 'GPS', value: `${lat}, ${lon}`, link: `https://maps.google.com/?q=${lat},${lon}` });
            }
            if (clip.gpsAltitude != null) clipRows.push({ icon: '⛰️', label: 'Altitude', value: `${clip.gpsAltitude.toFixed(1)} m` });
            clipRows.push({ icon: '📊', label: 'Clip Status', value: clip.status });
            if (clip.storageUrl) clipRows.push({ icon: '💾', label: 'Storage URL', value: clip.storageUrl });
            if (clip.streamUrl) clipRows.push({ icon: '📺', label: 'Stream URL', value: clip.streamUrl });
            if (clip.muxAssetId) clipRows.push({ icon: '🎬', label: 'Mux Asset ID', value: clip.muxAssetId });
            if (clip.muxPlaybackId) clipRows.push({ icon: '▶️', label: 'Mux Playback ID', value: clip.muxPlaybackId });
            if (clip.muxUploadId) clipRows.push({ icon: '📤', label: 'Mux Upload ID', value: clip.muxUploadId });
            clipRows.push({ icon: '📅', label: 'Clip Created', value: new Date(clip.createdAt).toLocaleString() });
        }

        // ── Form response metadata ──
        const formRows = [];
        if (form) {
            formRows.push({ icon: '🆔', label: 'Form ID', value: form.id });
            if (form.slug) formRows.push({ icon: '🏷', label: 'Slug / Title', value: form.slug });
            if (form.type) formRows.push({ icon: '📋', label: 'Type', value: form.type });
            if (form.priority) formRows.push({ icon: '🔺', label: 'Priority', value: form.priority });
            if (form.description) formRows.push({ icon: '📝', label: 'Description', value: form.description });
            if (form.extra) formRows.push({ icon: '📦', label: 'Extra Data', value: JSON.stringify(form.extra) });
            formRows.push({ icon: '📅', label: 'Submitted', value: new Date(form.submittedAt).toLocaleString() });
        }

        // Build HTML helper
        const renderRows = (rows) => rows.map(r => {
            const val = r.link
                ? `<a href="${escapeHtml(r.link)}" target="_blank" rel="noopener" style="color:#ccc;text-decoration:underline;text-underline-offset:2px">${escapeHtml(r.value)} ↗</a>`
                : escapeHtml(r.value);
            return `<div class="meta-row"><span class="meta-icon">${r.icon}</span><span class="meta-label">${escapeHtml(r.label)}</span><span class="meta-value">${val}</span></div>`;
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

        const googleFontsLink = `<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">`;

        const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${escapeHtml(displayTitle)} — Mediasource Viewer</title>
    ${googleFontsLink}
    ${muxPlayerScript}
    <style>
        *, *::before, *::after { box-sizing: border-box; }
        body, h1, h2, h3, p, div, span { margin: 0; padding: 0; }
        :root {
            /* Midnight Studio — matches theme-d-dark.css */
            --background:        #0E0F14;
            --foreground:        #E2E4ED;
            --card:              #161820;
            --card-hover:        #1C1F2A;
            --border:            #2A2D3A;
            --border-subtle:     #1E2029;
            --muted-foreground:  #7B7F96;
            --secondary:         #1C1F2A;
            --accent-blue:       #4F8ECC;
            --accent-green:      #3DA882;
            --accent-amber:      #C8972A;
            --accent-red:        #E05263;
            --accent-purple:     #6C63D6;
            --accent-green-glow: #3DA88214;
            --accent-red-glow:   #E0526314;
            --radius: 0.75rem;
        }
        body {
            background: var(--background);
            background-image: linear-gradient(180deg, #6C63D6 0%, #0E0F14 100%);
            background-attachment: fixed;
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
            border-radius: 10px;
            overflow: hidden;
            flex-shrink: 0;
            box-shadow: 0 4px 16px rgba(74,158,255,0.25);
        }
        .topbar-icon img { width: 100%; height: 100%; object-fit: cover; }
        .topbar-title {
            font-size: 20px;
            font-weight: 700;
            letter-spacing: -0.01em;
        }
        .topbar-sub {
            font-size: 11px;
            color: var(--muted-foreground);
            margin-top: 2px;
        }
        .topbar-right {
            text-align: right;
        }
        .topbar-right .owner {
            font-size: 15px;
            font-weight: 600;
        }
        .topbar-right .team {
            font-size: 12px;
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
            font-size: 22px;
            font-weight: 700;
            letter-spacing: -0.01em;
            word-break: break-word;
        }
        .clip-title-block .msid {
            font-family: 'JetBrains Mono', monospace;
            font-size: 12px;
            color: var(--muted-foreground);
            margin-top: 4px;
        }
        .dashboard-link {
            display: inline-flex;
            align-items: center;
            gap: 5px;
            font-size: 13px;
            font-weight: 500;
            color: var(--accent-blue);
            text-decoration: none;
            white-space: nowrap;
            padding: 6px 12px;
            border: 1px solid var(--border-subtle);
            border-radius: 8px;
            background: var(--card);
            flex-shrink: 0;
            margin-top: 4px;
        }
        .dashboard-link:hover { border-color: var(--accent-blue); }
        /* ── Card panel ── */
        .card {
            background: var(--card);
            border: 1px solid var(--border-subtle);
            border-radius: var(--radius);
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
            font-size: 14px;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 6px;
        }
        /* ── Video ── */
        .video-wrap mux-player {
            width: 100%;
            display: block;
            aspect-ratio: 16/9;
            --media-object-fit: contain;
            --media-object-position: center;
        }
        /* Placeholder shown while Mux is processing — same 16:9 frame */
        .video-placeholder {
            width: 100%;
            aspect-ratio: 16/9;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            gap: 16px;
            background: var(--secondary);
            color: var(--muted-foreground);
            position: relative;
            overflow: hidden;
        }
        /* Subtle animated shimmer across the placeholder */
        .video-placeholder::after {
            content: '';
            position: absolute;
            inset: 0;
            background: linear-gradient(105deg, transparent 40%, rgba(255,255,255,0.04) 50%, transparent 60%);
            animation: shimmer 2.4s ease-in-out infinite;
            background-size: 200% 100%;
        }
        @keyframes shimmer {
            0%   { background-position: 200% 0; }
            100% { background-position: -200% 0; }
        }
        .placeholder-icon {
            font-size: 40px;
            opacity: 0.4;
            animation: pulse-icon 2s ease-in-out infinite;
        }
        @keyframes pulse-icon {
            0%, 100% { opacity: 0.4; transform: scale(1); }
            50%       { opacity: 0.65; transform: scale(1.08); }
        }
        .placeholder-label {
            font-size: 14px;
            font-weight: 500;
            letter-spacing: 0.02em;
        }
        .placeholder-sub {
            font-size: 12px;
            opacity: 0.6;
        }
        .no-video {
            padding: 60px 20px;
            text-align: center;
            color: var(--muted-foreground);
            font-size: 14px;
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
            border-radius: 20px;
            font-size: 11px;
            font-weight: 600;
            letter-spacing: 0.05em;
        }
        .status-READY     { background: var(--accent-green-glow); color: var(--accent-green); border: 1px solid rgba(61,168,130,0.25); }
        .status-PROCESSING { background: #C8972A14;                color: var(--accent-amber); border: 1px solid rgba(200,151,42,0.25); }
        .status-UPLOADING  { background: #4F8ECC14;                color: var(--accent-blue);  border: 1px solid rgba(79,142,204,0.25); }
        .status-ERROR      { background: var(--accent-red-glow);   color: var(--accent-red);   border: 1px solid rgba(224,82,99,0.25); }
        /* Copy link button */
        .copy-link {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            background: var(--secondary);
            color: var(--foreground);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 6px 14px;
            font-size: 12px;
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
            border-color: rgba(52,211,153,0.3);
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
        .meta-icon { font-size: 15px; line-height: 1; }
        .meta-label {
            font-size: 13px;
            color: var(--muted-foreground);
        }
        .meta-value {
            font-size: 13px;
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
            border-radius: var(--radius);
            background: var(--accent-red-glow);
            border: 1px solid rgba(224,82,99,0.25);
            margin-bottom: 20px;
        }
        .alert-banner .alert-icon { font-size: 20px; flex-shrink: 0; }
        .alert-banner .alert-title {
            font-size: 13px;
            font-weight: 600;
            color: var(--accent-red);
        }
        .alert-banner .alert-detail {
            font-size: 13px;
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
            font-size: 13px;
            font-weight: 600;
            color: var(--muted-foreground);
            letter-spacing: 1px;
            opacity: 0.5;
        }
        /* ── Mobile ── */
        @media (max-width: 640px) {
            .container { padding: 16px 16px 48px; }

            .topbar {
                padding-bottom: 16px;
                margin-bottom: 20px;
            }
            .topbar-title { font-size: 17px; }

            .clip-title-block h1 { font-size: 18px; }

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
                font-size: 11px;
                text-transform: uppercase;
                letter-spacing: 0.5px;
            }
            .meta-value { grid-column: 2; font-size: 13px; }
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
            <a href="/" class="dashboard-link">← Dashboard</a>
        </div>

        <div class="card" id="video-card">
            ${hasMuxPlayback
                ? `<mux-player
                    id="mux-player-el"
                    stream-type="on-demand"
                    playback-id="${escapeHtml(muxPlaybackId)}"
                    ${MUX_ENV_KEY ? `env-key="${escapeHtml(MUX_ENV_KEY)}"` : ''}
                    metadata-video-title="${escapeHtml(displayTitle)}"
                    accent-color="#4a9eff"
                    preload="auto"
                  ></mux-player>`
                : `<div class="video-placeholder" id="video-placeholder">
                    <div class="placeholder-icon">🎬</div>
                    <div class="placeholder-label">Video Processing</div>
                    <div class="placeholder-sub" id="placeholder-status">${escapeHtml(asset.status)} &mdash; checking every 5s&hellip;</div>
                   </div>`
            }
            <div class="video-bar">
                <span class="status status-${escapeHtml(asset.status)}" id="status-pill">${escapeHtml(asset.status)}</span>
                <button class="copy-link" onclick="copyLink(this)">📋 Copy Link</button>
            </div>
        </div>

        ${!form && asset.status === 'READY' ? `
        <div class="alert-banner">
            <span class="alert-icon">🚨</span>
            <div>
                <div class="alert-title">NO CONTEXT FORM</div>
                <div class="alert-detail">Slug and description are missing for this asset.</div>
            </div>
        </div>
        ` : ''}

        ${clipRows.length > 0 ? `
        <div class="card">
            <div class="card-header"><h3>🎥 Video / Clip</h3></div>
            ${renderRows(clipRows)}
        </div>
        ` : ''}

        ${formRows.length > 0 ? `
        <div class="card">
            <div class="card-header"><h3>📋 Context Form</h3></div>
            ${renderRows(formRows)}
        </div>
        ` : ''}

        ${clip?.transcript ? `
        <div class="card">
            <div class="card-header"><h3>📝 Transcript</h3></div>
            <div style="padding:16px">
                <p style="font-size:14px;line-height:1.6;color:var(--foreground);white-space:pre-wrap;max-height:300px;overflow-y:auto">${escapeHtml(clip.transcript)}</p>
            </div>
        </div>
        ` : ''}

        ${assetRows.length > 0 ? `
        <div class="card">
            <div class="card-header"><h3>📦 Asset</h3></div>
            ${renderRows(assetRows)}
        </div>
        ` : ''}

        <div class="footer">
            <div class="logo">MEDIASOURCE FIXER</div>
        </div>
    </div>
    <script>
    function copyLink(btn) {
        navigator.clipboard.writeText(window.location.href).then(() => {
            btn.textContent = '✅ Copied!';
            btn.classList.add('copied');
            setTimeout(() => {
                btn.textContent = '📋 Copy Link';
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
            btn.textContent = '✅ Copied!';
            btn.classList.add('copied');
            setTimeout(() => {
                btn.textContent = '📋 Copy Link';
                btn.classList.remove('copied');
            }, 2000);
        });
    }

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
                        player.setAttribute('accent-color', '#4a9eff');
                        player.setAttribute('preload', 'auto');
                        player.style.width = '100%';
                        player.style.display = 'block';
                        player.style.aspectRatio = '16/9';

                        // Swap placeholder → player
                        placeholder.replaceWith(player);

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
