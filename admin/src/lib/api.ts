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

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly retryAfterSeconds: number | null = null,
    readonly code: string | null = null,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export async function api<T>(method: string, path: string, body?: unknown): Promise<T> {
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
    let code: string | null = null;
    try {
      const body = await res.json() as { error?: string; code?: string };
      if (body?.error) message = body.error;
      if (typeof body?.code === "string") code = body.code;
    } catch { /* ignore parse failure */ }
    const retryAfter = Number(res.headers.get("Retry-After"));
    throw new ApiError(message, res.status, Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : null, code);
  }
  return res.json() as Promise<T>;
}

/* ─── Typed API calls ─── */

import type { Stats, User, SessionUser, Asset, TriadStatus, Organization, MediaIssue, MediaSyncState, MonitoringSnapshot } from "./types";

export async function fetchHealth() {
  return api<{ status: string; service: string; version: string }>("GET", "/api/health");
}

export async function login(phoneNumber: string, pin: string) {
  // Mark as admin login so server doesn't update lastLoginAt
  return api<{ token: string; user: SessionUser }>("POST", "/api/auth/login", {
    phoneNumber,
    pin,
    clientType: "admin",
  });
}

/**
 * Clear the shared Clip Viewer cookie that `/api/auth/login` sets alongside
 * the Dashboard's bearer token, so logging out of the Dashboard also signs
 * the browser out of the Clip Viewer. Best-effort: logout should still
 * proceed locally even if this network call fails.
 */
export async function logoutClipSession() {
  try {
    await fetch("/clips/logout", { method: "POST" });
  } catch {
    // Ignore — local logout (clearing the bearer token) still happens.
  }
}

export async function fetchMe() {
  return api<{ user: SessionUser | null }>("GET", "/api/auth/me");
}

export async function fetchStats() {
  return api<Stats>("GET", "/api/admin/stats");
}

export async function fetchUsers() {
  return api<{ users: User[] }>("GET", "/api/admin/users");
}

export async function fetchAssets(moderation?: string) {
  const query = moderation ? `?moderation=${encodeURIComponent(moderation)}` : "";
  return api<{ assets: Asset[] }>("GET", `/api/admin/assets${query}`);
}

export async function fetchUploadCapabilities() {
  return api<{ originalUploads: boolean }>("GET", "/api/upload-capabilities");
}

export async function submitAssetForm(
  assetId: string,
  form: { slug: string; type: string; description: string; priority: string },
) {
  return api<unknown>("POST", `/api/assets/${encodeURIComponent(assetId)}/form`, form);
}

export async function fetchMyAssets() {
  return api<{ assets: Asset[] }>("GET", "/api/assets/mine");
}

export async function fetchMessages() {
  return api<{ messages: unknown[] }>("GET", "/api/admin/messages");
}

export async function fetchTriadStatus() {
  return api<TriadStatus>("GET", "/api/admin/status");
}

export async function fetchMonitoring() {
  return api<MonitoringSnapshot>("GET", "/api/admin/monitoring");
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

export async function createUser(data: { name: string; phoneNumber: string; email?: string; team?: string; companyCode?: string }) {
  return api<{ user: { id: string; name: string; phoneNumber: string }; message: string }>("POST", "/api/admin/users", data);
}

export async function deleteUser(userId: string) {
  return api<{
    message: string;
    deleted: { assets: number; clips: number; chatMessages: number; errorLogs: number; muxAssets: number; localFiles: number };
  }>("DELETE", `/api/admin/users/${userId}`);
}

export async function updateUser(userId: string, data: { companyCode?: string | null; name?: string; team?: string; email?: string }) {
  return api<{ user: User; message: string }>("PATCH", `/api/admin/users/${userId}`, data);
}

export async function updateUserStatus(userId: string, data: { status: "ACTIVE" | "SUSPENDED"; reason?: string }) {
  return api<{ user: Pick<User, "id" | "status">; message: string }>("PATCH", `/api/admin/users/${userId}/status`, data);
}

export async function updateAssetModeration(
  assetId: string,
  data: { moderation: "ACTIVE" | "PAUSED" | "FLAGGED_FOR_REMOVAL" | "REMOVED"; reason?: string },
) {
  return api<MediaSyncResponse & { asset: Pick<Asset, "id" | "moderation"> }>(
    "PATCH", `/api/admin/assets/${assetId}/moderation`, data,
  );
}

export interface MediaSyncResponse {
  mediaSyncState: MediaSyncState;
  message: string;
}

export async function confirmMuxPlaybackCreation(assetId: string, operationId: string, reason: string) {
  return api<MediaSyncResponse>("POST", `/api/admin/assets/${assetId}/media-sync/confirm-create`, {
    operationId,
    confirmed: true,
    reason,
  });
}

export async function fetchMediaIssues() {
  return api<{ issues: MediaIssue[]; hasMore: boolean }>("GET", "/api/admin/media-issues");
}

export interface RetiredMuxCursor {
  operationId: string;
  muxAssetId: string;
}

export interface RetiredMuxEvent extends RetiredMuxCursor {
  firstSeenAt: string;
  attempt: { originalMuxAssetId: string | null };
}

export async function fetchRetiredMuxEvents(cursor: RetiredMuxCursor | null) {
  const query = cursor
    ? `?${new URLSearchParams({ afterOperationId: cursor.operationId, afterMuxAssetId: cursor.muxAssetId })}`
    : "";
  return api<{ events: RetiredMuxEvent[]; nextCursor: RetiredMuxCursor | null }>(
    "GET", `/api/admin/retired-mux-events${query}`,
  );
}

export interface AuditLog {
  id: string;
  actorUserId: string;
  targetType: "USER" | "ASSET";
  targetId: string;
  action: string;
  reason?: string | null;
  createdAt: string;
}

export async function fetchAuditLogs() {
  return api<{ logs: AuditLog[] }>("GET", "/api/admin/audit-logs?limit=50");
}

/* ─── Organization API ─── */

export async function fetchOrganizations() {
  return api<{ organizations: Organization[] }>("GET", "/api/admin/organizations");
}

export async function createOrganization(data: { companyName: string; companyCode: string }) {
  return api<{ organization: Organization; message: string }>("POST", "/api/admin/organizations", data);
}

export async function updateOrganization(code: string, data: { companyName?: string; companyCode?: string }) {
  return api<{ organization: Organization; message: string }>("PUT", `/api/admin/organizations/${code}`, data);
}

export async function deleteOrganization(code: string) {
  return api<{ message: string }>("DELETE", `/api/admin/organizations/${code}`);
}
