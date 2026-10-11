/**
 * Shared constants for the Clip Viewer's cookie-based auth.
 * Used by both `routes/clips.js` (sets/reads the cookie for its own
 * /clips/login form) and `routes/auth.js` (sets the same cookie on a
 * successful Dashboard/API login so a single sign-in unifies both surfaces).
 */

export const CLIP_COOKIE_NAME = 'fixer_clip_token';

/** Cookie options — HttpOnly, 7-day expiry, scoped to /clips. */
export function clipCookieOpts(isSecure) {
    return {
        path: '/clips',
        httpOnly: true,
        secure: isSecure,
        sameSite: 'lax',
        maxAge: 7 * 24 * 60 * 60, // 7 days in seconds
    };
}
