/* ─── API Client ─── */

let authToken: string | null = null;

export function setToken(token: string) {
  authToken = token;
}

export function getToken(): string | null {
  return authToken;
}

async function api<T>(method: string, path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (authToken) headers["Authorization"] = `Bearer ${authToken}`;

  const opts: RequestInit = { method, headers };
  if (body && (method === "POST" || method === "PUT" || method === "PATCH")) {
    opts.body = JSON.stringify(body);
  }

  const res = await fetch(path, opts);
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
  return api<{ messages: unknown[] }>("GET", "/api/messages");
}

export async function fetchTriadStatus() {
  return api<TriadStatus>("GET", "/api/admin/status");
}

export async function cleanupAssets() {
  return api<{ cleaned: number; message: string; assetIds?: string[] }>("POST", "/api/admin/cleanup-assets");
}
