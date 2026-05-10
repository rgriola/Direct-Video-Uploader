// Last updated: May 9, 2026 - 6:55pm - GPT-5.3-Codex
import { describe, expect, it } from 'vitest';
import {
    redactCompanyCode,
    redactPersonName,
    redactPhoneNumber,
    redactToken,
    redactValue,
} from '../lib/redact.js';

describe('lib/redact', () => {
    it('redacts generic values with configurable visible prefix/suffix', () => {
        expect(redactValue('ABCDEFGHIJ')).toBe('AB******IJ');
        expect(redactValue('ABCDEFGHIJ', { visibleStart: 1, visibleEnd: 1 })).toBe('A********J');
        expect(redactValue('ABC', { visibleStart: 2, visibleEnd: 2 })).toBe('***');
        expect(redactValue(null)).toBeNull();
    });

    it('redacts phone numbers to the last 4 digits', () => {
        expect(redactPhoneNumber('(505) 555-1234')).toBe('***-***-1234');
        expect(redactPhoneNumber('12')).toBe('****');
        expect(redactPhoneNumber('')).toBeNull();
    });

    it('redacts company code and token with purpose-specific masks', () => {
        expect(redactCompanyCode('CNN')).toBe('C*N');
        expect(redactCompanyCode('AB')).toBe('**');
        expect(redactToken('abcdefgh12345678')).toBe('abcd********5678');
        expect(redactToken(null)).toBeNull();
    });

    it('redacts person names while preserving first letter', () => {
        expect(redactPersonName('Rod')).toBe('R**');
        expect(redactPersonName(' R ')).toBe('*');
        expect(redactPersonName('   ')).toBeNull();
        expect(redactPersonName(null)).toBeNull();
    });
});
