// Last updated: May 9, 2026 - 6:55pm - GPT-5.3-Codex
import { afterEach, describe, expect, it, vi } from 'vitest';

const originalNodeEnv = process.env.NODE_ENV;
const originalPublicUrl = process.env.PUBLIC_URL;
const originalPort = process.env.PORT;

async function loadConfig({ nodeEnv, publicUrl, port }) {
    if (nodeEnv === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = nodeEnv;

    if (publicUrl === undefined) delete process.env.PUBLIC_URL;
    else process.env.PUBLIC_URL = publicUrl;

    if (port === undefined) delete process.env.PORT;
    else process.env.PORT = port;

    vi.resetModules();
    return import('../lib/config.js');
}

afterEach(() => {
    if (originalNodeEnv === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = originalNodeEnv;

    if (originalPublicUrl === undefined) delete process.env.PUBLIC_URL;
    else process.env.PUBLIC_URL = originalPublicUrl;

    if (originalPort === undefined) delete process.env.PORT;
    else process.env.PORT = originalPort;

    vi.resetModules();
});

describe('lib/config', () => {
    it('uses localhost and wildcard CORS in development', async () => {
        const config = await loadConfig({
            nodeEnv: 'development',
            publicUrl: undefined,
            port: '4321',
        });

        expect(config.PUBLIC_URL).toBe('http://localhost:4321');
        expect(config.CORS_ORIGINS).toBe(true);
        expect(config.WS_CORS_ORIGINS).toBe('*');
    });

    it('uses default production URL and www variant', async () => {
        const config = await loadConfig({
            nodeEnv: 'production',
            publicUrl: undefined,
            port: undefined,
        });

        expect(config.PUBLIC_URL).toBe('https://ms-fixer.com');
        expect(config.CORS_ORIGINS).toEqual([
            'https://ms-fixer.com',
            'https://www.ms-fixer.com',
        ]);
        expect(config.WS_CORS_ORIGINS).toEqual([
            'https://ms-fixer.com',
            'https://www.ms-fixer.com',
        ]);
    });

    it('uses PUBLIC_URL override in production', async () => {
        const config = await loadConfig({
            nodeEnv: 'production',
            publicUrl: 'https://custom.example.com',
            port: undefined,
        });

        expect(config.PUBLIC_URL).toBe('https://custom.example.com');
        expect(config.CORS_ORIGINS).toEqual([
            'https://custom.example.com',
            'https://www.custom.example.com',
        ]);
    });
});
