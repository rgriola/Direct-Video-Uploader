// Last updated: May 13, 2026 - 1:32pm - GitHub Copilot (GPT-5.3-Codex)
import { useEffect, useState, useCallback, type FormEvent } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Toaster, toast } from "sonner";

import { fetchHealth, fetchMe, cleanupAssets, deleteUser, logoutWebSession, login, setToken, clearToken } from "@/lib/api";
import { useStats, useUsers, useAssets, useRefreshDashboard, useTriadStatus, useOrganizations } from "@/hooks/use-dashboard";
import { useSocket } from "@/hooks/use-socket";

import { Header } from "@/components/Header";
import { TriadStatusPanel } from "@/components/TriadStatus";
import { StatsGrid } from "@/components/StatsGrid";
import { QuickActions } from "@/components/QuickActions";
import { UserList } from "@/components/UserList";
import { AssetList } from "@/components/AssetList";
import { ActivityLog } from "@/components/ActivityLog";
import { EndpointTable } from "@/components/EndpointTable";
import { ChatHistory } from "@/components/ChatHistory";
import { ErrorLog } from "@/components/ErrorLog";
import { AdminTools } from "@/components/AdminTools";
import { OrgPanel } from "@/components/OrgPanel";
import type { UserRole } from "@/lib/types";

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 10_000, retry: 1 } },
});

const AUTH_REQUIRED_MESSAGES = new Set(["HTTP 401", "HTTP 403", "Unauthorized", "Admin access required"]);
const DASHBOARD_ROLES = new Set<UserRole>(["SUPER_ADMIN", "ORG_ADMIN"]);
const ADMIN_AUTH_TOKEN_KEY = "fixer_admin_token";

function readStoredAdminToken() {
  if (typeof window === "undefined") return null;
  const token = window.localStorage.getItem(ADMIN_AUTH_TOKEN_KEY)?.trim();
  return token || null;
}

function writeStoredAdminToken(token: string) {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(ADMIN_AUTH_TOKEN_KEY, token);
}

function clearStoredAdminToken() {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(ADMIN_AUTH_TOKEN_KEY);
}

function normalizeRootRedirectPath(value: string | null | undefined, fallback = "/") {
  if (!value) return fallback;
  const trimmed = value.trim();
  if (!trimmed.startsWith("/")) return fallback;
  if (trimmed.startsWith("//")) return fallback;
  return trimmed;
}

function readRootRedirectTarget() {
  if (typeof window === "undefined") return "/";
  const params = new URLSearchParams(window.location.search);
  return normalizeRootRedirectPath(params.get("redirect"), "/");
}

function readRootLoginError() {
  if (typeof window === "undefined") return null;
  const params = new URLSearchParams(window.location.search);
  const message = params.get("error")?.trim();
  return message || null;
}

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <Dashboard />
      <Toaster
        position="bottom-right"
        theme="dark"
        toastOptions={{
          style: {
            background: "var(--secondary)",
            border: "1px solid var(--border)",
            color: "var(--foreground)",
            fontFamily: "var(--font-sans)",
          },
        }}
      />
    </QueryClientProvider>
  );
}

function Dashboard() {
  const [loggedIn, setLoggedIn] = useState(false);
  const [authChecked, setAuthChecked] = useState(false);
  const [userRole, setUserRole] = useState<UserRole | null>(null);
  const [userName, setUserName] = useState<string | null>(null);
  const [userPhone, setUserPhone] = useState<string | null>(null);
  const [userId, setUserId] = useState<string | null>(null);
  const [userCompany, setUserCompany] = useState<string | null>(null);
  const [showChatHistory, setShowChatHistory] = useState(false);
  const [companyCode, setCompanyCode] = useState("");
  const [phoneNumber, setPhoneNumber] = useState("");
  const [pin, setPin] = useState("");
  const [authSubmitting, setAuthSubmitting] = useState(false);
  const [authError, setAuthError] = useState<string | null>(() => readRootLoginError());
  const [rootRedirectTarget] = useState(() => readRootRedirectTarget());

  const { data: stats, error: statsError } = useStats(loggedIn);
  const { data: users, isLoading: usersLoading, error: usersError } = useUsers(loggedIn);
  const { data: assets, isLoading: assetsLoading, error: assetsError } = useAssets(loggedIn);
  const { data: triadStatus, isLoading: triadLoading, error: triadError } = useTriadStatus(loggedIn);
  const { data: organizations, isLoading: orgsLoading, error: organizationsError } = useOrganizations(loggedIn);
  const refreshDashboard = useRefreshDashboard();

  const { connected, logs, addLog, clearLogs, connect } = useSocket(() => {
    refreshDashboard("upload:complete");
  });

  // Restore dashboard session from either stored bearer token or existing web cookie.
  useEffect(() => {
    let active = true;

    async function restoreSession() {
      const storedToken = readStoredAdminToken();
      if (storedToken) {
        setToken(storedToken);
      }

      try {
        const { user } = await fetchMe();
        if (!user) {
          throw new Error("Unauthorized");
        }

        const role = (user.role ?? "EDITOR") as UserRole;
        if (!DASHBOARD_ROLES.has(role)) {
          if (active) {
            if (rootRedirectTarget !== "/") {
              window.location.assign(rootRedirectTarget);
              return;
            }

            setAuthError((previous) => previous || "Signed in. Open your clip link to continue.");
          }
          return;
        }

        if (!active) return;

        setLoggedIn(true);
          setUserRole(role);
        setUserName(user.name ?? null);
        setUserId(user.id ?? null);
        setUserPhone(user.phoneNumber ?? null);
        setUserCompany(user.companyName ?? null);
        setAuthError(null);
        addLog("auth", `Session restored: ${user.name}`);
        connect();
      } catch (err) {
        if (!active) return;

        const msg = err instanceof Error ? err.message : "";
        if (AUTH_REQUIRED_MESSAGES.has(msg)) {
          clearToken();
          clearStoredAdminToken();
          setAuthError((previous) => previous || null);
          return;
        }

        setAuthError(msg || "Unable to verify login session");
        toast.error("Dashboard session check failed", {
          description: msg || "Unable to verify login session",
        });
      } finally {
        if (active) {
          setAuthChecked(true);
        }
      }
    }

    void restoreSession();

    return () => {
      active = false;
    };
  }, [addLog, connect, rootRedirectTarget]);

  // If any dashboard polling query receives auth errors, immediately self-heal
  // to the root login state to stop repeated unauthorized request loops.
  useEffect(() => {
    if (!loggedIn) return;

    const hasAuthPollingError = [statsError, usersError, assetsError, triadError, organizationsError]
      .some((error) => error instanceof Error && AUTH_REQUIRED_MESSAGES.has(error.message));

    if (!hasAuthPollingError) return;

    clearToken();
    clearStoredAdminToken();
    void logoutWebSession().catch(() => undefined);

    setLoggedIn(false);
    setUserRole(null);
    setUserName(null);
    setUserPhone(null);
    setUserId(null);
    setUserCompany(null);
    setShowChatHistory(false);
    setAuthChecked(true);
    setAuthError("Session expired. Please sign in again.");
    addLog("auth", "Session expired; returned to root login.");
  }, [
    loggedIn,
    statsError,
    usersError,
    assetsError,
    triadError,
    organizationsError,
    addLog,
  ]);

  const handleRootLogin = useCallback(async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    const normalizedPhone = phoneNumber.replace(/\D/g, "").slice(0, 10);
    const normalizedPin = pin.trim();
    const normalizedCompanyCode = companyCode.replace(/[^a-zA-Z]/g, "").toUpperCase().slice(0, 4);

    if (normalizedPhone.length !== 10 || normalizedPin.length < 4) {
      setAuthError("Enter a valid 10-digit phone number and PIN.");
      return;
    }

    setAuthSubmitting(true);
    setAuthError(null);

    try {
      const result = await login(normalizedPhone, normalizedPin, normalizedCompanyCode || undefined);
      const role = (result.user.role ?? "EDITOR") as UserRole;

      setToken(result.token);
      writeStoredAdminToken(result.token);

      if (rootRedirectTarget !== "/") {
        window.location.assign(rootRedirectTarget);
        return;
      }

      if (!DASHBOARD_ROLES.has(role)) {
        setPin("");
        setAuthError("Signed in. Open your clip link to continue.");
        return;
      }

      setLoggedIn(true);
      setUserRole(role);
      setUserName(result.user.name ?? null);
      setUserId(result.user.id ?? null);
      setUserPhone(result.user.phoneNumber ?? null);
      setUserCompany(result.user.companyName ?? null);
      setPin("");
      setAuthError(null);

      addLog("auth", `Signed in: ${result.user.name}`);
      connect();
    } catch (err) {
      const msg = err instanceof Error ? err.message : "Unable to sign in";
      setAuthError(msg);
      toast.error("Sign-in failed", {
        description: msg,
      });
    } finally {
      setAuthSubmitting(false);
      setAuthChecked(true);
    }
  }, [phoneNumber, pin, companyCode, addLog, connect, rootRedirectTarget]);

  const handleAction = useCallback(
    async (action: string) => {
      try {
        switch (action) {
          case "health": {
            addLog("http", "GET /api/health");
            const res = await fetchHealth();
            toast(`Health: ${res.status}`, { description: `${res.service} v${res.version}` });
            addLog("http", `Health: ${res.status} — ${res.service} v${res.version}`);
            break;
          }
          case "me": {
            if (!loggedIn) { toast.error("Not logged in — is the server running?"); return; }
            addLog("http", "GET /api/auth/me");
            const res = await fetchMe();
            toast(`${res.user?.name ?? "Error"}`, { description: res.user?.team ?? "" });
            addLog("http", `Profile: ${res.user?.name ?? "Error"}`);
            break;
          }
          case "messages": {
            if (!loggedIn) { toast.error("Not logged in — is the server running?"); return; }
            addLog("http", "GET /api/messages");
            setShowChatHistory(true);
            break;
          }
          case "cleanup": {
            addLog("http", "POST /api/admin/cleanup-assets");
            const res = await cleanupAssets();
            toast(res.message, { description: res.cleaned > 0 ? `IDs: ${res.assetIds?.map(id => id.slice(0, 8)).join(", ")}` : undefined });
            addLog("http", res.message);
            if (res.cleaned > 0) refreshDashboard();
            break;
          }
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : "Unknown error";
        toast.error(msg);
        addLog("error", msg);
      }
    },
    [loggedIn, addLog],
  );

  const handleDeleteUser = useCallback(
    async (targetUserId: string, targetUserName: string) => {
      try {
        const res = await deleteUser(targetUserId);
        const d = res.deleted;
        toast.success(res.message, {
          description: `${d.assets} assets, ${d.clips} clips, ${d.chatMessages} messages removed`,
          duration: 6000,
        });
        addLog("http", `Deleted user: ${targetUserName}`);
        refreshDashboard();
      } catch (err) {
        toast.error(err instanceof Error ? err.message : "Failed to delete user");
        addLog("error", `Delete user failed: ${err instanceof Error ? err.message : "Unknown error"}`);
        throw err;
      }
    },
    [addLog, refreshDashboard],
  );

  if (!loggedIn) {
    return (
      <div className="min-h-screen flex items-center justify-center p-6">
        <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) px-6 py-6 max-w-md w-full">
          <div className="mx-auto mb-4 w-16 h-16 rounded-2xl overflow-hidden shadow-[0_8px_32px_rgba(74,158,255,0.3)]">
            <img src="/fixer-icon.png" alt="Fixer motorcycle icon" className="w-full h-full object-cover" />
          </div>
          <h1 className="text-lg font-semibold text-(--foreground) text-center">Fixer Login</h1>
          <p className="mt-2 text-sm text-(--muted-foreground) text-center">
            {authChecked ? "Sign in from root to continue." : "Restoring session..."}
          </p>

          {authError && (
            <div className="mt-4 border border-red-400/35 bg-red-500/10 rounded-lg p-3 text-xs text-red-200">
              {authError}
            </div>
          )}

          <form className="mt-4 space-y-3" onSubmit={handleRootLogin}>
            <div>
              <label htmlFor="root-phone" className="block text-xs font-semibold uppercase tracking-wide text-(--muted-foreground) mb-1">
                Phone Number
              </label>
              <input
                id="root-phone"
                type="tel"
                inputMode="numeric"
                autoComplete="tel"
                placeholder="10-digit phone"
                maxLength={10}
                value={phoneNumber}
                onChange={(event) => setPhoneNumber(event.target.value.replace(/\D/g, "").slice(0, 10))}
                className="w-full px-3 py-2 rounded-md border border-(--border-subtle) bg-(--secondary) text-(--foreground)"
                disabled={authSubmitting}
                required
              />
            </div>

            <div>
              <label htmlFor="root-company" className="block text-xs font-semibold uppercase tracking-wide text-(--muted-foreground) mb-1">
                Company Code (Non-Admin)
              </label>
              <input
                id="root-company"
                type="text"
                autoComplete="off"
                placeholder="ABC or ABCD"
                maxLength={4}
                value={companyCode}
                onChange={(event) => setCompanyCode(event.target.value.replace(/[^a-zA-Z]/g, "").toUpperCase().slice(0, 4))}
                className="w-full px-3 py-2 rounded-md border border-(--border-subtle) bg-(--secondary) text-(--foreground)"
                disabled={authSubmitting}
              />
            </div>

            <div>
              <label htmlFor="root-pin" className="block text-xs font-semibold uppercase tracking-wide text-(--muted-foreground) mb-1">
                PIN
              </label>
              <input
                id="root-pin"
                type="password"
                autoComplete="current-password"
                placeholder="PIN"
                maxLength={8}
                value={pin}
                onChange={(event) => setPin(event.target.value)}
                className="w-full px-3 py-2 rounded-md border border-(--border-subtle) bg-(--secondary) text-(--foreground)"
                disabled={authSubmitting}
                required
              />
            </div>

            <button
              type="submit"
              disabled={authSubmitting || !authChecked}
              className="w-full px-4 py-2 rounded-md bg-blue-600 hover:bg-blue-500 disabled:opacity-60 disabled:cursor-not-allowed text-white font-semibold"
            >
              {authSubmitting ? "Signing in..." : "Sign In"}
            </button>
          </form>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-330 mx-auto px-4 sm:px-6 pt-5 sm:pt-8 pb-12 sm:pb-16">
      <Header
        onLogout={() => {
          void logoutWebSession().catch(() => undefined).finally(() => {
            clearToken();
            clearStoredAdminToken();
            setLoggedIn(false);
            setUserRole(null);
            setUserName(null);
            setUserPhone(null);
            setUserId(null);
            setUserCompany(null);
            setPhoneNumber("");
            setCompanyCode("");
            setPin("");
            setShowChatHistory(false);
            setAuthChecked(true);
            setAuthError(null);
          });
        }}
        userName={userName}
        userPhone={userPhone}
        userCompany={userCompany}
        userRole={userRole}
      />

      <TriadStatusPanel
        triad={triadStatus}
        isLoading={triadLoading}
        wsConnected={connected}
        iosClients={stats?.iosClients}
      />

      <StatsGrid stats={stats} />

      {showChatHistory && <ChatHistory onClose={() => setShowChatHistory(false)} />}

      <div className="grid grid-cols-2 gap-6 mb-8 max-[900px]:grid-cols-1">
        <UserList
          users={users}
          isLoading={usersLoading}
          onDeleteUser={userRole === "SUPER_ADMIN" ? handleDeleteUser : undefined}
          currentUserId={userId ?? undefined}
          currentUserRole={userRole ?? undefined}
          organizations={organizations}
          onRefresh={() => refreshDashboard()}
        />
        <AssetList assets={assets} isLoading={assetsLoading} />
      </div>

      {/* Organizations panel — admin only */}
      {userRole === "SUPER_ADMIN" && (
        <div className="mb-8">
          <OrgPanel
            organizations={organizations ?? []}
            isLoading={orgsLoading}
            onRefresh={() => refreshDashboard()}
          />
        </div>
      )}

      <QuickActions onAction={handleAction} addLog={addLog} />

      <div className="grid grid-cols-2 gap-6 mb-8 max-[900px]:grid-cols-1">
        <ActivityLog logs={logs} onClear={clearLogs} />
        <ErrorLog />
      </div>

      <EndpointTable />

      {userRole === "SUPER_ADMIN" && (
        <div className="mt-8">
          <AdminTools onReset={() => { refreshDashboard(); addLog("http", "Nuclear reset executed"); }} />
        </div>
      )}

      <footer className="mt-16 pt-6 border-t border-(--border-subtle) flex flex-wrap items-center justify-between gap-3">
        <p className="text-xs text-(--foreground)">© 2025 Sea Lion Media LLC. All rights reserved.</p>
        <div className="flex items-center gap-4">
          <a
            href="/privacy-policy.html"
            target="_blank"
            rel="noopener noreferrer"
            className="text-xs text-(--foreground) hover:underline"
          >
            Privacy Policy
          </a>
          <a
            href="/privacy-policy.html#support"
            target="_blank"
            rel="noopener noreferrer"
            className="text-xs text-(--foreground) hover:underline"
          >
            Support
          </a>
        </div>
      </footer>
    </div>
  );
}
