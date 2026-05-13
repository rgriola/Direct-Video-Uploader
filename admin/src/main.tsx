// Last updated: May 13, 2026 - 2:20pm - GitHub Copilot (GPT-5.3-Codex)
import * as Sentry from "@sentry/react";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./theme-d-dark.css";

const sentryDsn = import.meta.env.VITE_SENTRY_DSN?.trim();

if (sentryDsn) {
  Sentry.init({
    dsn: sentryDsn,
    environment: import.meta.env.VITE_SENTRY_ENVIRONMENT || import.meta.env.MODE,
    release: import.meta.env.VITE_SENTRY_RELEASE || undefined,
    tracesSampleRate: 0.1,
    sendDefaultPii: false,
  });
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
