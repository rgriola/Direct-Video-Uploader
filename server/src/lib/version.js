import { readFileSync } from 'fs';

// server/package.json is the single source of truth for the server version.
const packageJson = JSON.parse(
    readFileSync(new URL('../../package.json', import.meta.url), 'utf8'),
);

export const SERVER_VERSION = packageJson.version;
