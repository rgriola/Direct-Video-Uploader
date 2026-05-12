// Last updated: May 12, 2026 - 3:35pm - GitHub Copilot (GPT-5.3-Codex)

export const Role = Object.freeze({
    SUPER_ADMIN: 'SUPER_ADMIN',
    ORG_ADMIN: 'ORG_ADMIN',
    EDITOR: 'EDITOR',
    VIEWER: 'VIEWER',
});

const LEGACY_ROLE_MAP = Object.freeze({
    ADMIN: Role.SUPER_ADMIN,
    USER: Role.EDITOR,
});

const ROLE_SET = new Set(Object.values(Role));

export const ROLE_VALUES = Object.freeze(Object.values(Role));

export function normalizeRole(role) {
    if (typeof role !== 'string') return null;

    const normalized = role.trim().toUpperCase();
    if (!normalized) return null;

    if (LEGACY_ROLE_MAP[normalized]) {
        return LEGACY_ROLE_MAP[normalized];
    }

    return ROLE_SET.has(normalized) ? normalized : null;
}

export function isSuperAdmin(role) {
    return normalizeRole(role) === Role.SUPER_ADMIN;
}

export function isOrgAdmin(role) {
    return normalizeRole(role) === Role.ORG_ADMIN;
}

export function isDashboardAdmin(role) {
    const normalized = normalizeRole(role);
    return normalized === Role.SUPER_ADMIN || normalized === Role.ORG_ADMIN;
}
