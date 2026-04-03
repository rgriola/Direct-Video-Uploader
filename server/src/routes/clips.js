/**
 * Clip Viewer — Public page to view a video clip with metadata.
 * Accessible at GET /clips/:mediasourceId
 */
import prisma from '../lib/prisma.js';
import { MUX_ENV_KEY } from '../lib/mux.js';

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
    /**
     * GET /clips/:mediasourceId
     * Render a public clip viewer page (dark theme, video player + metadata).
     */
    fastify.get('/clips/:mediasourceId', async (request, reply) => {
        const { mediasourceId } = request.params;

        // Reject obviously invalid IDs (e.g. "undefined", empty, non-numeric)
        if (!mediasourceId || mediasourceId === 'undefined' || mediasourceId === 'null') {
            reply.status(404).type('text/html').send(`
                <!DOCTYPE html>
                <html><head><title>Not Found</title>
                <style>body{background:oklch(70.499% 0.11489 254.082);color:oklch(93.014% 0.00759 260.883);font-family:'Outfit',sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
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
                    <style>body{background:oklch(70.499% 0.11489 254.082);color:oklch(93.014% 0.00759 260.883);font-family:'Outfit',sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
                    h1{font-size:1.5rem;opacity:0.7}</style></head>
                    <body><h1>Clip not found</h1></body></html>
                `);
                return;
            }

            // Fetch relations separately (Prisma 7 + pg adapter has issues with include in some contexts)
            const clips = await prisma.clip.findMany({ where: { assetId: asset.id }, orderBy: { createdAt: 'desc' } });
            const formResponse = await prisma.formResponse.findFirst({ where: { assetId: asset.id } });
            const user = await prisma.user.findFirst({ where: { id: asset.userId }, select: { name: true, team: true } });

            asset = { ...asset, clips, formResponse, user };
        } catch (err) {
            fastify.log.error({ err, mediasourceId }, 'Clip viewer DB query failed');
            reply.status(500).type('text/html').send(`
                <!DOCTYPE html>
                <html><head><title>Error</title>
                <style>body{background:oklch(70.499% 0.11489 254.082);color:oklch(93.014% 0.00759 260.883);font-family:'Outfit',sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
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
            --background: oklch(70.499% 0.11489 254.082);
            --foreground: oklch(93.014% 0.00759 260.883);
            --card: oklch(46.562% 0.09735 268.744);
            --card-hover: oklch(44.844% 0.04091 263.273);
            --border: oklch(0.22 0.02 270);
            --border-subtle: oklch(0.17 0.01 270);
            --muted-foreground: oklch(91.646% 0.01404 272.677);
            --secondary: oklch(0.16 0.01 270);
            --accent-blue: #4a9eff;
            --accent-green: #34d399;
            --accent-amber: #fbbf24;
            --accent-red: #f87171;
            --accent-green-glow: rgba(52, 211, 153, 0.15);
            --accent-red-glow: rgba(248, 113, 113, 0.10);
            --radius: 0.875rem;
        }
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
        .status-READY { background: var(--accent-green-glow); color: var(--accent-green); border: 1px solid rgba(52,211,153,0.2); }
        .status-PROCESSING { background: rgba(251,191,36,0.12); color: var(--accent-amber); border: 1px solid rgba(251,191,36,0.2); }
        .status-UPLOADING { background: rgba(74,158,255,0.12); color: var(--accent-blue); border: 1px solid rgba(74,158,255,0.2); }
        .status-ERROR { background: rgba(248,113,113,0.12); color: var(--accent-red); border: 1px solid rgba(248,113,113,0.2); }
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
            background: rgba(248,113,113,0.08);
            border: 1px solid rgba(248,113,113,0.25);
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

        <div class="card">
            ${hasMuxPlayback
                ? `<mux-player
                    stream-type="on-demand"
                    playback-id="${escapeHtml(muxPlaybackId)}"
                    ${MUX_ENV_KEY ? `env-key="${escapeHtml(MUX_ENV_KEY)}"` : ''}
                    metadata-video-title="${escapeHtml(displayTitle)}"
                    accent-color="#4a9eff"
                    preload="auto"
                  ></mux-player>`
                : `<div class="no-video">🎬 Video not yet available</div>`
            }
            <div class="video-bar">
                <span class="status status-${escapeHtml(asset.status)}">${escapeHtml(asset.status)}</span>
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
    </script>
</body>
</html>`;

        reply.type('text/html').send(html);
    });
}
