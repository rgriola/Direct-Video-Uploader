// Last updated: May 13, 2026 - 2:20pm - GitHub Copilot (GPT-5.3-Codex)
/// <reference types="vite/client" />

interface ImportMetaEnv {
	readonly VITE_SERVER_ORIGIN?: string;
	readonly VITE_SENTRY_DSN?: string;
	readonly VITE_SENTRY_ENVIRONMENT?: string;
	readonly VITE_SENTRY_RELEASE?: string;
}

interface ImportMeta {
	readonly env: ImportMetaEnv;
}
