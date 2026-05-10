// Last updated: May 9, 2026 - 6:40pm - GPT-5.3-Codex
/**
 * PII redaction helpers for logs and alerts.
 */

export function redactValue(value, { visibleStart = 2, visibleEnd = 2 } = {}) {
    if (value == null) return null;
    const text = String(value);
    if (text.length <= visibleStart + visibleEnd) return '*'.repeat(text.length);
    return `${text.slice(0, visibleStart)}${'*'.repeat(text.length - visibleStart - visibleEnd)}${text.slice(-visibleEnd)}`;
}

export function redactPhoneNumber(phoneNumber) {
    if (!phoneNumber) return null;
    const digits = String(phoneNumber).replace(/\D/g, '');
    if (digits.length < 4) return '****';
    return `***-***-${digits.slice(-4)}`;
}

export function redactCompanyCode(companyCode) {
    if (!companyCode) return null;
    return redactValue(companyCode, { visibleStart: 1, visibleEnd: 1 });
}

export function redactToken(token) {
    if (!token) return null;
    return redactValue(token, { visibleStart: 4, visibleEnd: 4 });
}

export function redactPersonName(name) {
    if (!name) return null;
    const text = String(name).trim();
    if (!text) return null;
    if (text.length === 1) return '*';
    return `${text[0]}${'*'.repeat(Math.max(1, text.length - 1))}`;
}
