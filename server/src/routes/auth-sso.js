// Last updated: May 12, 2026 - 3:52pm - GitHub Copilot (GPT-5.3-Codex)
/**
 * SSO auth routes (Phase 2.2).
 * Provides org SSO discovery, SP metadata, SSO start redirect, and SAML callback session issuance.
 */
import crypto from 'node:crypto';
import prisma from '../lib/prisma.js';
import { hashPin } from '../lib/utils.js';
import { createSession } from '../lib/session-store.js';
import { Role, normalizeRole } from '../lib/rbac.js';

const DEFAULT_SAML_ATTRIBUTE_MAPPING = Object.freeze({
    email: 'email',
    name: 'name',
    phoneNumber: 'phoneNumber',
    role: 'role',
});

const WEB_SESSION_COOKIE_NAME = 'fixer_clip_token';
const WEB_SESSION_COOKIE_MAX_AGE_SECONDS = 7 * 24 * 60 * 60;

function normalizeCompanyCode(value) {
    if (typeof value !== 'string') return null;
    const normalized = value.trim().toUpperCase();
    return normalized || null;
}

function normalizePhoneDigits(value) {
    if (typeof value !== 'string') return null;
    const digits = value.replace(/\D/g, '').slice(0, 10);
    return digits.length === 10 ? digits : null;
}

function getOrigin(request) {
    const forwardedHost = request.headers?.['x-forwarded-host'];
    const forwardedProto = request.headers?.['x-forwarded-proto'];
    const hostHeader = Array.isArray(forwardedHost) ? forwardedHost[0] : forwardedHost;
    const protoHeader = Array.isArray(forwardedProto) ? forwardedProto[0] : forwardedProto;
    const host = (hostHeader || request.headers?.host || 'localhost:3000').toString().split(',')[0].trim();
    const proto = (protoHeader || request.protocol || 'http').toString().split(',')[0].trim();
    return `${proto}://${host}`;
}

function buildSsoStartUrl(request, companyCode, redirectUri) {
    const url = new URL('/api/auth/sso/start', getOrigin(request));
    url.searchParams.set('companyCode', companyCode);
    if (redirectUri) {
        url.searchParams.set('redirectUri', redirectUri);
    }
    return url.toString();
}

function encodeRelayState(payload) {
    return Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
}

function decodeRelayState(encoded) {
    if (typeof encoded !== 'string' || encoded.trim() === '') return {};

    try {
        const decoded = Buffer.from(encoded, 'base64url').toString('utf8');
        const parsed = JSON.parse(decoded);
        return parsed && typeof parsed === 'object' ? parsed : {};
    } catch {
        return {};
    }
}

function pickMappedAttribute(attributes, key) {
    if (!attributes || typeof attributes !== 'object' || !key) return null;

    const value = attributes[key];
    if (Array.isArray(value)) {
        return typeof value[0] === 'string' ? value[0] : null;
    }

    return typeof value === 'string' ? value : null;
}

function parseAttributeMapping(rawMapping) {
    if (!rawMapping || typeof rawMapping !== 'object' || Array.isArray(rawMapping)) {
        return { ...DEFAULT_SAML_ATTRIBUTE_MAPPING };
    }

    const mapping = { ...DEFAULT_SAML_ATTRIBUTE_MAPPING };
    for (const [key, value] of Object.entries(rawMapping)) {
        if (typeof value === 'string' && value.trim()) {
            mapping[key] = value.trim();
        }
    }

    return mapping;
}

function parseOptionalJsonObject(rawValue) {
    if (!rawValue) return null;
    if (typeof rawValue === 'object' && !Array.isArray(rawValue)) return rawValue;

    if (typeof rawValue !== 'string') return null;

    try {
        const parsed = JSON.parse(rawValue);
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
            return parsed;
        }
        return null;
    } catch {
        return null;
    }
}

function normalizeRedirectUri(rawValue) {
    if (typeof rawValue !== 'string') return null;
    const trimmed = rawValue.trim();
    if (!trimmed) return null;

    // Allow explicit app callback scheme plus secure web callbacks.
    if (trimmed.startsWith('fixer://')) return trimmed;
    if (trimmed.startsWith('https://')) return trimmed;

    return null;
}

function buildMetadataXml(entityId, acsUrl) {
    return `<?xml version="1.0" encoding="UTF-8"?>
<EntityDescriptor xmlns="urn:oasis:names:tc:SAML:2.0:metadata" entityID="${entityId}">
  <SPSSODescriptor protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol" AuthnRequestsSigned="false" WantAssertionsSigned="false">
    <NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress</NameIDFormat>
    <AssertionConsumerService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="${acsUrl}" index="0" isDefault="true" />
  </SPSSODescriptor>
</EntityDescriptor>`;
}

function syntheticPhoneFromSeed(seed) {
    const digest = crypto.createHash('sha256').update(seed).digest('hex');
    const digits = digest
        .split('')
        .map((char) => {
            const value = Number.parseInt(char, 16);
            return Number.isFinite(value) ? String(value % 10) : '0';
        })
        .join('');

    return `9${digits.slice(0, 9)}`;
}

function webSessionCookieOptions(request) {
    const forwardedProto = request.headers?.['x-forwarded-proto'];
    const protoHeader = Array.isArray(forwardedProto) ? forwardedProto[0] : forwardedProto;
    const isSecure = (protoHeader || request.protocol || '').toString().includes('https');

    return {
        path: '/',
        httpOnly: true,
        secure: isSecure,
        sameSite: 'lax',
        maxAge: WEB_SESSION_COOKIE_MAX_AGE_SECONDS,
    };
}

export default async function authSsoRoutes(fastify) {
    /**
     * GET /api/auth/sso/metadata
     * Exposes SP metadata for enterprise IdP setup (Okta / Azure AD / Entra).
     */
    fastify.get('/api/auth/sso/metadata', async (request, reply) => {
        const origin = getOrigin(request);
        const entityId = process.env.SAML_SP_ENTITY_ID || `${origin}/api/auth/sso/metadata`;
        const acsUrl = process.env.SAML_SP_ACS_URL || `${origin}/api/auth/sso/saml`;

        reply.type('application/samlmetadata+xml');
        return buildMetadataXml(entityId, acsUrl);
    });

    /**
     * GET /api/auth/sso/config/:companyCode
     * Public SSO discovery endpoint for login clients (iOS/web) to detect SSO-enabled orgs.
     */
    fastify.get('/api/auth/sso/config/:companyCode', {
        schema: {
            params: {
                type: 'object',
                required: ['companyCode'],
                properties: {
                    companyCode: { type: 'string', minLength: 3, maxLength: 4 },
                },
            },
        },
    }, async (request, reply) => {
        const companyCode = normalizeCompanyCode(request.params.companyCode);
        const org = await prisma.organization.findUnique({
            where: { companyCode },
            select: {
                companyCode: true,
                companyName: true,
                ssoEnabled: true,
                samlMetadataUrl: true,
                samlEntityId: true,
                samlAttributeMapping: true,
            },
        });

        if (!org) {
            return reply.status(404).send({ error: 'Organization not found' });
        }

        return {
            companyCode: org.companyCode,
            companyName: org.companyName,
            ssoEnabled: !!org.ssoEnabled,
            samlEntityId: org.samlEntityId || null,
            samlMetadataUrl: org.samlMetadataUrl || null,
            samlAttributeMapping: org.samlAttributeMapping || null,
            startUrl: buildSsoStartUrl(request, org.companyCode, null),
        };
    });

    /**
     * GET /api/auth/sso/start
     * Starts SSO for an org.
     * In dev it redirects to a simulated IdP form. In production it forwards to configured IdP metadata URL.
     */
    fastify.get('/api/auth/sso/start', {
        schema: {
            querystring: {
                type: 'object',
                required: ['companyCode'],
                properties: {
                    companyCode: { type: 'string', minLength: 3, maxLength: 4 },
                    redirectUri: { type: 'string' },
                },
            },
        },
    }, async (request, reply) => {
        const companyCode = normalizeCompanyCode(request.query.companyCode);
        const redirectUri = normalizeRedirectUri(request.query.redirectUri);

        const org = await prisma.organization.findUnique({
            where: { companyCode },
            select: {
                companyCode: true,
                companyName: true,
                ssoEnabled: true,
                samlMetadataUrl: true,
            },
        });

        if (!org || !org.ssoEnabled) {
            return reply.status(404).send({ error: 'SSO is not enabled for this organization' });
        }

        const relayState = encodeRelayState({
            companyCode: org.companyCode,
            redirectUri,
            nonce: crypto.randomUUID(),
        });

        if (process.env.NODE_ENV !== 'production') {
            return reply.redirect(`/api/auth/sso/dev-login?state=${encodeURIComponent(relayState)}`);
        }

        if (!org.samlMetadataUrl) {
            return reply.status(400).send({ error: 'SSO metadata URL is not configured' });
        }

        const target = new URL(org.samlMetadataUrl);
        target.searchParams.set('RelayState', relayState);
        return reply.redirect(target.toString());
    });

    /**
     * GET /api/auth/sso/dev-login
     * Local SSO simulator to exercise iOS/web flow without an external IdP.
     */
    fastify.get('/api/auth/sso/dev-login', async (request, reply) => {
        if (process.env.NODE_ENV === 'production') {
            return reply.status(404).send({ error: 'Not found' });
        }

        const state = typeof request.query.state === 'string' ? request.query.state : '';
        const relayState = decodeRelayState(state);
        const companyCode = normalizeCompanyCode(relayState.companyCode) || '';

        const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Fixer Dev SSO</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0b1020; color: #e8eefc; margin: 0; padding: 32px; }
    .card { max-width: 480px; margin: 0 auto; background: #121a2f; border: 1px solid #283556; border-radius: 14px; padding: 24px; }
    h1 { margin-top: 0; font-size: 22px; }
    p { color: #b6c2df; }
    label { display: block; margin-top: 14px; margin-bottom: 6px; font-size: 13px; color: #b6c2df; }
    input { width: 100%; box-sizing: border-box; padding: 10px 12px; border-radius: 8px; border: 1px solid #364977; background: #0e1530; color: #e8eefc; }
    button { margin-top: 18px; width: 100%; border: none; background: #377dff; color: white; border-radius: 10px; padding: 12px; font-weight: 700; cursor: pointer; }
    .meta { margin-top: 10px; font-size: 12px; color: #9caed6; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Fixer Dev SSO</h1>
    <p>Use this local simulator to complete the Phase 2.2 SSO callback flow.</p>
    <form method="POST" action="/api/auth/sso/saml">
      <input type="hidden" name="state" value="${state}" />
      <label for="companyCode">Company Code</label>
      <input id="companyCode" name="companyCode" value="${companyCode}" required maxlength="4" />

      <label for="email">Email</label>
      <input id="email" name="email" type="email" placeholder="reporter@example.com" required />

      <label for="name">Display Name</label>
      <input id="name" name="name" placeholder="Field Reporter" />

      <label for="phoneNumber">Phone Number (optional)</label>
      <input id="phoneNumber" name="phoneNumber" placeholder="5055551234" />

      <button type="submit">Complete SSO</button>
    </form>
    <div class="meta">RelayState present: ${state ? 'yes' : 'no'}</div>
  </div>
</body>
</html>`;

        reply.type('text/html');
        return html;
    });

    /**
     * POST /api/auth/sso/saml
     * Assertion consumer callback. Accepts normalized identity claims and issues Fixer JWT session.
     */
    fastify.post('/api/auth/sso/saml', {
        schema: {
            body: {
                type: 'object',
                properties: {
                    state: { type: 'string' },
                    RelayState: { type: 'string' },
                    companyCode: { type: 'string' },
                    email: { type: 'string' },
                    name: { type: 'string' },
                    phoneNumber: { type: 'string' },
                    role: { type: 'string' },
                    redirectUri: { type: 'string' },
                    attributes: {
                        anyOf: [
                            { type: 'object', additionalProperties: true },
                            { type: 'string' },
                        ],
                    },
                },
            },
        },
        config: {
            rateLimit: { max: 20, timeWindow: '1 minute' },
        },
    }, async (request, reply) => {
        const rawState = request.body?.state || request.body?.RelayState;
        const relayState = decodeRelayState(rawState);

        const companyCode = normalizeCompanyCode(request.body?.companyCode || relayState.companyCode);
        if (!companyCode) {
            return reply.status(400).send({ error: 'companyCode is required' });
        }

        const org = await prisma.organization.findUnique({
            where: { companyCode },
            select: {
                companyCode: true,
                companyName: true,
                ssoEnabled: true,
                samlAttributeMapping: true,
            },
        });

        if (!org || !org.ssoEnabled) {
            return reply.status(403).send({ error: 'SSO is not enabled for this organization' });
        }

        const attributes = parseOptionalJsonObject(request.body?.attributes) || {};
        const mapping = parseAttributeMapping(org.samlAttributeMapping);

        const mappedEmail = pickMappedAttribute(attributes, mapping.email);
        const mappedName = pickMappedAttribute(attributes, mapping.name);
        const mappedPhone = pickMappedAttribute(attributes, mapping.phoneNumber);
        const mappedRole = pickMappedAttribute(attributes, mapping.role);

        const email = String(request.body?.email || mappedEmail || '').trim().toLowerCase() || null;
        const name = String(request.body?.name || mappedName || '').trim() || null;
        const requestedRole = normalizeRole(request.body?.role || mappedRole) || Role.EDITOR;

        let phoneNumber = normalizePhoneDigits(request.body?.phoneNumber || mappedPhone);
        if (!phoneNumber && email) {
            phoneNumber = syntheticPhoneFromSeed(`${companyCode}:${email}`);
        }

        if (!email && !phoneNumber) {
            return reply.status(400).send({ error: 'SSO callback must include email or phoneNumber' });
        }

        let user = null;

        if (phoneNumber) {
            user = await prisma.user.findUnique({ where: { phoneNumber } });
        }

        if (!user && email) {
            user = await prisma.user.findFirst({ where: { email, companyCode } });
        }

        if (user) {
            user = await prisma.user.update({
                where: { id: user.id },
                data: {
                    email: email || user.email || null,
                    name: name || user.name,
                    companyCode,
                    role: normalizeRole(user.role) || requestedRole,
                    status: 'ACTIVE',
                },
            });
        } else {
            const generatedPin = String(crypto.randomInt(0, 9999)).padStart(4, '0');
            user = await prisma.user.create({
                data: {
                    phoneNumber,
                    name: name || (email ? email.split('@')[0] : 'SSO User'),
                    email,
                    team: null,
                    companyCode,
                    pinHash: await hashPin(generatedPin),
                    role: requestedRole,
                    status: 'ACTIVE',
                },
            });
        }

        const normalizedRole = normalizeRole(user.role) || Role.EDITOR;
        const jti = crypto.randomUUID();
        const token = fastify.jwt.sign(
            {
                id: user.id,
                phoneNumber: user.phoneNumber,
                name: user.name,
                role: normalizedRole,
                companyCode: user.companyCode || null,
                jti,
            },
            { expiresIn: '7d' }
        );

        try {
            await createSession({ userId: user.id, jti });
        } catch (err) {
            request.log.error(
                { err: { message: err.message }, userId: user.id },
                'Failed to create SSO login session'
            );
            return reply.status(503).send({ error: 'Unable to establish session' });
        }

        reply.setCookie(WEB_SESSION_COOKIE_NAME, token, webSessionCookieOptions(request));
        reply.clearCookie(WEB_SESSION_COOKIE_NAME, { path: '/clips' });

        const redirectUri = normalizeRedirectUri(request.body?.redirectUri || relayState.redirectUri);
        if (redirectUri) {
            const target = new URL(redirectUri);
            target.searchParams.set('token', token);
            target.searchParams.set('companyCode', companyCode);
            return reply.redirect(target.toString());
        }

        return {
            token,
            user: {
                id: user.id,
                name: user.name,
                phoneNumber: user.phoneNumber,
                email: user.email,
                team: user.team,
                role: normalizedRole,
                companyCode: user.companyCode || null,
                companyName: org.companyName,
            },
            sso: {
                companyCode,
                provider: 'SAML',
            },
        };
    });
}
