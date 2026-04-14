/* ─── API Client ─── */

let authToken: string | null = null;

export function setToken(token: string) {
  authToken = token;
}

export function getToken(): string | null {
  return authToken;
}

export function clearToken() {
  authToken = null;
}

async function api<T>(method: string, path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = {};
  if (authToken) headers["Authorization"] = `Bearer ${authToken}`;

  const opts: RequestInit = { method, headers };
  if (body && (method === "POST" || method === "PUT" || method === "PATCH")) {
    headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }

  const res = await fetch(path, opts);
  if (!res.ok) {
    let message = `HTTP ${res.status}`;
    try {
      const body = await res.json() as { error?: string };
      if (body?.error) message = body.error;
    } catch { /* ignore parse failure */ }
    throw new Error(message);
  }
  return res.json() as Promise<T>;
}

/* ─── Typed API calls ─── */

import type { Stats, User, Asset, TriadStatus } from "./types";

export async function fetchHealth() {
  return api<{ status: string; service: string; version: string }>("GET", "/api/health");
}

export async function login(phoneNumber: string, pin: string) {
  // Mark as admin login so server doesn't update lastLoginAt
  return api<{ token: string; user: User }>("POST", "/api/auth/login", {
    phoneNumber,
    pin,
    clientType: "admin",
  });
}

export async function fetchMe() {
  return api<{ user: User }>("GET", "/api/auth/me");
}

export async function fetchStats() {
  return api<Stats>("GET", "/api/admin/stats");
}

export async function fetchUsers() {
  return api<{ users: User[] }>("GET", "/api/admin/users");
}

export async function fetchAssets() {
  return api<{ assets: Asset[] }>("GET", "/api/admin/assets");
}

export async function fetchMessages() {
  return api<{ messages: unknown[] }>("GET", "/api/admin/messages");
}

export async function fetchTriadStatus() {
  return api<TriadStatus>("GET", "/api/admin/status");
}

export async function cleanupAssets() {
  return api<{ cleaned: number; message: string; assetIds?: string[] }>("POST", "/api/admin/cleanup-assets");
}

export async function fetchErrors() {
  return api<{ errors: Array<{ id: string; source: string; category: string; message: string; severity: string; createdAt: string; userId?: string | null }> }>("GET", "/api/admin/errors");
}

export async function nuclearReset() {
  return api<{
    message: string;
    deleted: { assets: number; clips: number; formResponses: number; chatMessages: number; errorLogs: number };
    mux: { deleted: number; failed: number; skipped: boolean };
  }>("POST", "/api/admin/nuclear-reset");
}

export async function createUser(data: { name: string; phoneNumber: string; email?: string; team?: string }) {
  return api<{ user: { id: string; name: string; phoneNumber: string }; message: string }>("POST", "/api/admin/users", data);
}

export async function deleteUser(userId: string) {
  return api<{
    message: string;
    deleted: { assets: number; clips: number; chatMessages: number; errorLogs: number; muxAssets: number; localFiles: number };
  }>("DELETE", `/api/admin/users/${userId}`);
}
