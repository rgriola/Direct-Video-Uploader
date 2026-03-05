/**
 * Clip Viewer — Public page to view a video clip with metadata.
 * Accessible at GET /clips/:slug
 */
import prisma from '../lib/prisma.js';
import { MUX_ENV_KEY } from '../lib/mux.js';
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
     * GET /clips/:slug
     * Render a public clip viewer page (dark theme, video player + metadata).
     */
    fastify.get('/clips/:slug', async (request, reply) => {
        const { slug } = request.params;

        let asset;
        try {
            asset = await prisma.asset.findFirst({
                where: { slug },
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
            fastify.log.error({ err, slug }, 'Clip viewer DB query failed');
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

        // Build metadata rows
        const metaRows = [];
        if (clip?.gpsLat && clip?.gpsLon) metaRows.push({ icon: '📍', label: 'GPS', value: `${clip.gpsLat.toFixed(4)}, ${clip.gpsLon.toFixed(4)}` });
        if (clip?.capturedAt) metaRows.push({ icon: '🕐', label: 'Captured', value: new Date(clip.capturedAt).toLocaleString() });
        if (clip?.deviceModel) metaRows.push({ icon: '📱', label: 'Device', value: `${escapeHtml(clip.deviceModel)}${clip.osVersion ? ' · ' + escapeHtml(clip.osVersion) : ''}` });
        if (clip?.codec) metaRows.push({ icon: '🎥', label: 'Video', value: `${escapeHtml(clip.codec)}${clip.resolution ? ' · ' + escapeHtml(clip.resolution) : ''}` });
        if (clip?.orientation) metaRows.push({ icon: '↔️', label: 'Orientation', value: escapeHtml(clip.orientation) });
        if (clip?.duration) {
            const min = Math.floor(clip.duration / 60);
            const sec = clip.duration % 60;
            metaRows.push({ icon: '⏱', label: 'Duration', value: `${min}:${String(sec).padStart(2, '0')}` });
        }
        if (clip?.fileSize) {
            const mb = Number(clip.fileSize) / 1_000_000;
            metaRows.push({ icon: '📁', label: 'File Size', value: `${mb.toFixed(1)} MB` });
        }

        const metaHTML = metaRows.map(r =>
            `<div class="meta-row"><span class="meta-icon">${r.icon}</span><span class="meta-label">${escapeHtml(r.label)}</span><span class="meta-value">${escapeHtml(r.value)}</span></div>`
        ).join('\n');

        // Form response section
        let formHTML = '';
        if (form) {
            formHTML = `
                <div class="section">
                    <h3>Context Form</h3>
                    <div class="meta-grid">
                        ${form.type ? `<div class="meta-row"><span class="meta-icon">🏷</span><span class="meta-label">Type</span><span class="meta-value">${escapeHtml(form.type)}</span></div>` : ''}
                        ${form.priority ? `<div class="meta-row"><span class="meta-icon">🔺</span><span class="meta-label">Priority</span><span class="meta-value priority-${escapeHtml(form.priority.toLowerCase())}">${escapeHtml(form.priority)}</span></div>` : ''}
                        ${form.description ? `<div class="meta-row"><span class="meta-icon">📝</span><span class="meta-label">Description</span><span class="meta-value">${escapeHtml(form.description)}</span></div>` : ''}
                    </div>
                </div>
            `;
        }

        const videoURL = clip?.storageUrl || '';
        const hasVideo = videoURL && clip?.status === 'READY';
        const hasMuxPlayback = !!(clip?.muxPlaybackId);
        const muxPlaybackId = clip?.muxPlaybackId || '';
        const muxEnvKey = MUX_ENV_KEY || '';
        const hasMuxPlayback = !!clip?.muxPlaybackId;
        const muxPlaybackId = clip?.muxPlaybackId || '';

        // Mux Player uses a web component — only load when we have a playback ID
        const muxPlayerScript = hasMuxPlayback
            ? `<script src="https://cdn.jsdelivr.net/npm/@mux/mux-player@latest"></script>`
            : '';

        const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${escapeHtml(asset.slug)} — Mediasource Viewer</title>
    ${muxPlayerScript}
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            background: #0A0E1A;
            color: #E5E5EA;
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', system-ui, sans-serif;
            min-height: 100vh;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            padding: 24px 16px 64px;
        }
        /* Header */
        .header {
            text-align: center;
            padding: 32px 0 24px;
            border-bottom: 1px solid rgba(255,255,255,0.08);
            margin-bottom: 24px;
        }
        .header .brand {
            font-size: 12px;
            font-weight: 600;
            letter-spacing: 2px;
            text-transform: uppercase;
            color: #007AFF;
            margin-bottom: 8px;
        }
        .header h1 {
            font-size: 24px;
            font-weight: 700;
            color: #fff;
            margin-bottom: 4px;
        }
        .header .msid {
            font-family: 'SF Mono', ui-monospace, monospace;
            font-size: 13px;
            color: #007AFF;
        }
        .header .uploader {
            font-size: 13px;
            color: rgba(255,255,255,0.4);
            margin-top: 6px;
        }
        /* Video */
        .video-wrap {
            background: #000;
            border-radius: 14px;
            overflow: hidden;
            margin-bottom: 24px;
            position: relative;
        }
        .video-wrap video, .video-wrap mux-player {
            width: 100%;
            display: block;
            aspect-ratio: 16/9;
        }
        mux-player {
            --media-object-fit: contain;
            --controls: auto;
        }
        .no-video {
            padding: 60px 20px;
            text-align: center;
            color: rgba(255,255,255,0.3);
            font-size: 14px;
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
            display: flex;
            align-items: center;
            padding: 12px 16px;
            border-bottom: 1px solid rgba(255,255,255,0.04);
        }
        .meta-row:last-child { border-bottom: none; }
        .meta-icon { font-size: 15px; width: 28px; flex-shrink: 0; }
        .meta-label {
            font-size: 13px;
            color: rgba(255,255,255,0.45);
            width: 90px;
            flex-shrink: 0;
        }
        .meta-value {
            font-size: 13px;
            font-weight: 500;
            color: #fff;
        }
        /* Priority badges */
        .priority-critical { color: #FF453A; }
        .priority-high { color: #FF9F0A; }
        .priority-medium { color: #30D158; }
        .priority-low { color: rgba(255,255,255,0.5); }
        /* Status pill */
        .status {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: 600;
            margin-top: 8px;
        }
        .status-READY { background: rgba(48,209,88,0.15); color: #30D158; }
        .status-PROCESSING { background: rgba(255,159,10,0.15); color: #FF9F0A; }
        .status-UPLOADING { background: rgba(0,122,255,0.15); color: #007AFF; }
        .status-ERROR { background: rgba(255,69,58,0.15); color: #FF453A; }
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
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="brand">Mediasource Viewer</div>
            <h1>${escapeHtml(asset.slug)}</h1>
            ${asset.mediasourceId ? `<div class="msid">#${escapeHtml(asset.mediasourceId)}</div>` : ''}
            ${asset.user ? `<div class="uploader">Uploaded by ${escapeHtml(asset.user.name)}${asset.user.team ? ' · ' + escapeHtml(asset.user.team) : ''}</div>` : ''}
            <span class="status status-${escapeHtml(asset.status)}">${escapeHtml(asset.status)}</span>
        </div>

        <div class="video-wrap">
            ${hasMuxPlayback
                ? `<mux-player
                    stream-type="on-demand"
                    playback-id="${escapeHtml(muxPlaybackId)}"
                    ${MUX_ENV_KEY ? `env-key="${escapeHtml(MUX_ENV_KEY)}"` : ''}
                    metadata-video-title="${escapeHtml(asset.slug)}"
                    accent-color="#007AFF"
                    style="width:100%;aspect-ratio:16/9;--media-object-fit:contain;border-radius:14px"
                    preload="auto"
                  ></mux-player>`
                : hasVideo
                    ? `<video controls preload="metadata" playsinline><source src="${escapeHtml(videoURL)}" type="video/quicktime"><source src="${escapeHtml(videoURL)}" type="video/mp4">Your browser does not support video playback.</video>`
                    : `<div class="no-video">🎬 Video not yet available</div>`
            }
        </div>

        ${metaRows.length > 0 ? `
        <div class="section">
            <h3>Video Metadata</h3>
            <div class="meta-grid">${metaHTML}</div>
        </div>
        ` : ''}

        ${formHTML}

        <div class="footer">
            <div class="logo">MEDIASOURCE FIXER</div>
        </div>
    </div>
</body>
</html>`;

        reply.type('text/html').send(html);
    });
}
