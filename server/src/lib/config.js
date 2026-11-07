/**
 * Centralized server configuration.
 * Single source of truth for the production URL and CORS origins.
 */

const isProduction = process.env.NODE_ENV === 'production';
const PORT = parseInt(process.env.PORT || '3000', 10);

/**
 * Public-facing base URL for the server.
 * - Production: reads PUBLIC_URL env var, falls back to ms-fixer.com
 * - Development: http://localhost:<PORT>
 */
export const PUBLIC_URL = isProduction
    ? (process.env.PUBLIC_URL || 'https://ms-fixer.com')
    : `http://localhost:${PORT}`;

/**
 * Extra allowed origins beyond PUBLIC_URL (and its www variant), e.g. a
 * secondary/legacy hostname like the home-server dev subdomain. Comma-separated.
 */
const EXTRA_ORIGINS = isProduction && process.env.EXTRA_CORS_ORIGINS
    ? process.env.EXTRA_CORS_ORIGINS.split(',').map((origin) => origin.trim()).filter(Boolean)
    : [];

/**
 * Allowed CORS origins (includes www variant and any EXTRA_CORS_ORIGINS in production).
 */
export const CORS_ORIGINS = isProduction
    ? [PUBLIC_URL, PUBLIC_URL.replace('://', '://www.'), ...EXTRA_ORIGINS]
    : true;

/**
 * CORS origins for Socket.IO (string array in production, wildcard in dev).
 */
export const WS_CORS_ORIGINS = isProduction
    ? [PUBLIC_URL, PUBLIC_URL.replace('://', '://www.'), ...EXTRA_ORIGINS]
    : '*';
