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
                <style>body{background:#0A0E1A;color:#fff;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
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
                    <style>body{background:#0A0E1A;color:#fff;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
                    h1{font-size:1.5rem;opacity:0.7}</style></head>
                    <body><h1>Clip not found</h1></body></html>
                `);
                return;
            }

            // Fetch relations separately (Prisma 7 + pg adapter has issues with include in some contexts)
            const clips = await prisma.clip.findMany({ where: { assetId: asset.id } });
            const formResponse = await prisma.formResponse.findFirst({ where: { assetId: asset.id } });
            const user = await prisma.user.findFirst({ where: { id: asset.userId }, select: { name: true, team: true } });

            asset = { ...asset, clips, formResponse, user };
        } catch (err) {
            fastify.log.error({ err, mediasourceId }, 'Clip viewer DB query failed');
            reply.status(500).type('text/html').send(`
                <!DOCTYPE html>
                <html><head><title>Error</title>
                <style>body{background:#0A0E1A;color:#fff;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
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

        const videoURL = clip?.storageUrl || '';
        const hasVideo = !!videoURL;
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

        const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${escapeHtml(displayTitle)} — Mediasource Viewer</title>
    ${muxPlayerScript}
    <style>
        *, *::before, *::after { box-sizing: border-box; }
        body, h1, h2, h3, p, div, span { margin: 0; padding: 0; }
        body {
            background: #0A0E1A;
            color: #E5E5EA;
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', system-ui, sans-serif;
            min-height: 100vh;
            -webkit-text-size-adjust: 100%;
        }
        a { color: #ccc; }
        .container {
            max-width: 800px;
            margin: 0 auto;
            padding: 24px 20px 64px;
        }
        /* Header — split layout */
        .header {
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            padding: 24px 0 16px;
            border-bottom: 1px solid rgba(255,255,255,0.08);
            margin-bottom: 20px;
        }
        .header-left {
            display: flex;
            flex-direction: column;
            gap: 4px;
        }
        .header-left .brand {
            font-size: 11px;
            font-weight: 600;
            letter-spacing: 2px;
            text-transform: uppercase;
            color: rgba(255,255,255,0.35);
        }
        .header-left h1 {
            font-size: 22px;
            font-weight: 700;
            color: #fff;
            word-break: break-word;
        }
        .header-left .msid {
            font-family: 'SF Mono', ui-monospace, monospace;
            font-size: 13px;
            color: rgba(255,255,255,0.5);
        }
        .header-right {
            text-align: right;
            flex-shrink: 0;
            padding-top: 4px;
        }
        .header-right .owner {
            font-size: 15px;
            font-weight: 600;
            color: #fff;
        }
        .header-right .team {
            font-size: 12px;
            color: rgba(255,255,255,0.4);
        }
        /* Video */
        .video-wrap {
            background: #000;
            border-radius: 14px;
            overflow: hidden;
            margin-bottom: 8px;
            position: relative;
        }
        .video-wrap video {
            width: 100%;
            display: block;
            aspect-ratio: 16/9;
        }
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
            color: rgba(255,255,255,0.3);
            font-size: 14px;
        }
        /* Below video — status + copy link */
        .video-bar {
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 8px 0 20px;
        }
        /* Status pill */
        .status {
            display: inline-block;
            padding: 4px 14px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: 600;
            vertical-align: middle;
        }
        .status-READY { background: rgba(48,209,88,0.15); color: #30D158; }
        .status-PROCESSING { background: rgba(255,159,10,0.15); color: #FF9F0A; }
        .status-UPLOADING { background: rgba(0,122,255,0.15); color: #7ABAFF; }
        .status-ERROR { background: rgba(255,69,58,0.15); color: #FF453A; }
        /* Copy link button */
        .copy-link {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            background: rgba(255,255,255,0.08);
            color: #fff;
            border: 1px solid rgba(255,255,255,0.15);
            border-radius: 8px;
            padding: 5px 12px;
            font-size: 12px;
            font-weight: 500;
            cursor: pointer;
            transition: all 0.2s;
            font-family: inherit;
        }
        .copy-link:hover { background: rgba(255,255,255,0.14); }
        .copy-link:active { transform: scale(0.96); }
        .copy-link.copied {
            background: rgba(48,209,88,0.15);
            color: #30D158;
            border-color: rgba(48,209,88,0.3);
        }
        /* Sections */
        .section {
            margin-bottom: 24px;
        }
        .section h3 {
            font-size: 11px;
            font-weight: 600;
            letter-spacing: 1.5px;
            text-transform: uppercase;
            color: rgba(255,255,255,0.35);
            margin-bottom: 10px;
            padding-left: 4px;
        }
        /* Metadata */
        .meta-grid {
            background: rgba(255,255,255,0.04);
            border-radius: 14px;
            overflow: hidden;
        }
        .meta-row {
            display: grid;
            grid-template-columns: 28px 120px 1fr;
            align-items: center;
            gap: 0 8px;
            padding: 12px 16px;
            border-bottom: 1px solid rgba(255,255,255,0.04);
        }
        .meta-row:last-child { border-bottom: none; }
        .meta-icon { font-size: 15px; line-height: 1; }
        .meta-label {
            font-size: 13px;
            color: rgba(255,255,255,0.45);
        }
        .meta-value {
            font-size: 13px;
            font-weight: 500;
            color: #fff;
            min-width: 0;
            overflow-wrap: break-word;
        }
        /* Priority badges */
        .priority-critical { color: #FF453A; }
        .priority-high { color: #FF9F0A; }
        .priority-medium { color: #30D158; }
        .priority-low { color: rgba(255,255,255,0.5); }
        /* Alert banner */
        .alert-banner {
            display: flex;
            align-items: center;
            gap: 10px;
            padding: 14px 18px;
            border-radius: 12px;
            background: rgba(255,69,58,0.10);
            border: 1px solid rgba(255,69,58,0.25);
            margin-bottom: 24px;
        }
        .alert-banner .alert-icon { font-size: 20px; flex-shrink: 0; }
        .alert-banner .alert-title {
            font-size: 14px;
            font-weight: 600;
            color: #FF453A;
        }
        .alert-banner .alert-detail {
            font-size: 13px;
            color: rgba(255,255,255,0.5);
        }
        /* Footer */
        .footer {
            text-align: center;
            padding-top: 32px;
            border-top: 1px solid rgba(255,255,255,0.06);
            margin-top: 16px;
        }
        .footer .logo {
            font-size: 13px;
            font-weight: 600;
            color: rgba(255,255,255,0.25);
            letter-spacing: 1px;
        }
        /* ── Mobile ── */
        @media (max-width: 480px) {
            .container { padding: 16px 14px 48px; }
            .header { padding: 16px 0 12px; margin-bottom: 16px; flex-direction: column; gap: 8px; }
            .header-right { text-align: left; }
            .header-left h1 { font-size: 18px; }
            .video-wrap { border-radius: 10px; }
            .meta-row {
                grid-template-columns: 28px 1fr;
                gap: 2px 8px;
                padding: 10px 12px;
            }
            .meta-label {
                grid-column: 2;
                font-size: 11px;
                text-transform: uppercase;
                letter-spacing: 0.5px;
            }
            .meta-value {
                grid-column: 2;
                font-size: 13px;
            }
            .meta-icon { grid-row: span 2; align-self: start; padding-top: 2px; }
            .meta-grid { border-radius: 10px; }
            .section h3 { margin-bottom: 8px; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="header-left">
                <div class="brand">Mediasource Viewer</div>
                <h1>${escapeHtml(displayTitle)}</h1>
                ${asset.mediasourceId ? `<div class="msid">#${escapeHtml(asset.mediasourceId)}</div>` : ''}
            </div>
            ${asset.user ? `<div class="header-right">
                <div class="owner">@${escapeHtml(asset.user.name)}</div>
                ${asset.user.team ? `<div class="team">${escapeHtml(asset.user.team)}</div>` : ''}
            </div>` : ''}
        </div>

        <div class="video-wrap">
            ${hasMuxPlayback
                ? `<mux-player
                    stream-type="on-demand"
                    playback-id="${escapeHtml(muxPlaybackId)}"
                    ${MUX_ENV_KEY ? `env-key="${escapeHtml(MUX_ENV_KEY)}"` : ''}
                    metadata-video-title="${escapeHtml(displayTitle)}"
                    accent-color="#007AFF"
                    preload="auto"
                  ></mux-player>`
                : hasVideo
                    ? `<video controls preload="metadata" playsinline><source src="${escapeHtml(videoURL)}" type="video/quicktime"><source src="${escapeHtml(videoURL)}" type="video/mp4">Your browser does not support video playback.</video>`
                    : `<div class="no-video">🎬 Video not yet available</div>`
            }
        </div>

        <div class="video-bar">
            <span class="status status-${escapeHtml(asset.status)}">${escapeHtml(asset.status)}</span>
            <button class="copy-link" onclick="copyLink(this)">📋 Copy Link</button>
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
        <div class="section">
            <h3>Video / Clip</h3>
            <div class="meta-grid">${renderRows(clipRows)}</div>
        </div>
        ` : ''}

        ${formRows.length > 0 ? `
        <div class="section">
            <h3>Context Form</h3>
            <div class="meta-grid">${renderRows(formRows)}</div>
        </div>
        ` : ''}

        ${assetRows.length > 0 ? `
        <div class="section">
            <h3>Asset</h3>
            <div class="meta-grid">${renderRows(assetRows)}</div>
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
