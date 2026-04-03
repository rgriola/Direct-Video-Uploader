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
 * Allowed CORS origins (includes www variant in production).
 */
export const CORS_ORIGINS = isProduction
    ? [PUBLIC_URL, PUBLIC_URL.replace('://', '://www.')]
    : true;

/**
 * CORS origins for Socket.IO (string array in production, wildcard in dev).
 */
export const WS_CORS_ORIGINS = isProduction
    ? [PUBLIC_URL, PUBLIC_URL.replace('://', '://www.')]
    : '*';
