// Last updated: May 12, 2026 - 3:35pm - GitHub Copilot (GPT-5.3-Codex)
import { useEffect, useState, useCallback, useRef } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Toaster, toast } from "sonner";

import { fetchHealth, fetchMe, cleanupAssets, deleteUser, logoutWebSession } from "@/lib/api";
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

function buildRedirectTarget() {
  if (typeof window === "undefined") return "/";
  return `${window.location.pathname}${window.location.search}${window.location.hash}` || "/";
}

function backendOrigin() {
  if (typeof window === "undefined") return "http://localhost:3000";

  const configured = import.meta.env.VITE_SERVER_ORIGIN?.trim();
  if (configured) {
    return configured.replace(/\/$/, "");
  }

  if (window.location.hostname === "localhost") {
    return `${window.location.protocol}//127.0.0.1:3000`;
  }

  if (window.location.port === "5173") {
    return `${window.location.protocol}//${window.location.hostname}:3000`;
  }

  return window.location.origin;
}

function buildWebLoginUrl() {
  if (typeof window === "undefined") return "/clips/login?redirect=%2F";
  const target = buildRedirectTarget();
  return `/clips/login?redirect=${encodeURIComponent(target)}`;
}

function buildDirectLoginUrl() {
  const target = buildRedirectTarget();
  return `${backendOrigin()}/clips/login?redirect=${encodeURIComponent(target)}`;
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
  const [loginRedirectFailed, setLoginRedirectFailed] = useState(false);
  const [loginFallbackHref, setLoginFallbackHref] = useState<string>(buildDirectLoginUrl());
  const loginRedirectTimerRef = useRef<number | null>(null);

  const { data: stats } = useStats(loggedIn);
  const { data: users, isLoading: usersLoading } = useUsers(loggedIn);
  const { data: assets, isLoading: assetsLoading } = useAssets(loggedIn);
  const { data: triadStatus, isLoading: triadLoading } = useTriadStatus(loggedIn);
  const { data: organizations, isLoading: orgsLoading } = useOrganizations(loggedIn);
  const refreshDashboard = useRefreshDashboard();

  const { connected, logs, addLog, clearLogs, connect } = useSocket(() => {
    refreshDashboard("upload:complete");
  });

  const redirectToLogin = useCallback(() => {
    const loginUrl = buildWebLoginUrl();
    setLoginRedirectFailed(false);
    setLoginFallbackHref(buildDirectLoginUrl());

    if (loginRedirectTimerRef.current) {
      window.clearTimeout(loginRedirectTimerRef.current);
    }

    window.location.assign(loginUrl);

    // If navigation fails (for example backend/proxy is down), stay on page and show a manual link.
    loginRedirectTimerRef.current = window.setTimeout(() => {
      setLoginRedirectFailed(true);
    }, 1500);
  }, []);

  useEffect(() => {
    return () => {
      if (loginRedirectTimerRef.current) {
        window.clearTimeout(loginRedirectTimerRef.current);
      }
    };
  }, []);

  // Restore web session from HttpOnly cookie (shared clip viewer + dashboard login).
  useEffect(() => {
    let active = true;

    async function restoreSession() {
      try {
        const { user } = await fetchMe();
        if (!user) {
          throw new Error("Unauthorized");
        }

        const role = (user.role ?? "EDITOR") as UserRole;
        if (!DASHBOARD_ROLES.has(role)) {
          await logoutWebSession().catch(() => undefined);
          if (active) {
            redirectToLogin();
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
        addLog("auth", `Session restored: ${user.name}`);
        connect();
      } catch (err) {
        if (!active) return;

        const msg = err instanceof Error ? err.message : "";
        if (AUTH_REQUIRED_MESSAGES.has(msg)) {
          await logoutWebSession().catch(() => undefined);
          if (active) {
            redirectToLogin();
          }
          return;
        }

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
  }, [addLog, connect, redirectToLogin]);

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
        <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) px-6 py-5 text-center max-w-md w-full">
          <p className="text-sm text-(--foreground)">
            {authChecked ? "Redirecting to login..." : "Restoring session..."}
          </p>

          {authChecked && loginRedirectFailed && (
            <div className="mt-4 border border-red-400/35 bg-red-500/10 rounded-lg p-3 text-left">
              <p className="text-xs text-red-200 mb-2">
                Unable to reach login page. Make sure the server is running on localhost:3000.
              </p>
              <a
                href={loginFallbackHref}
                className="text-xs text-blue-300 hover:text-blue-200 underline"
              >
                Open login directly
              </a>
            </div>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-330 mx-auto px-4 sm:px-6 pt-5 sm:pt-8 pb-12 sm:pb-16">
      <Header
        onLogout={() => {
          void logoutWebSession().catch(() => undefined).finally(() => {
            setLoggedIn(false);
            setUserRole(null);
            setUserName(null);
            setUserPhone(null);
            setUserCompany(null);
            redirectToLogin();
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
