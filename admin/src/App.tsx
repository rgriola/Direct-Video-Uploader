import { Fragment, useEffect, useState, useCallback, useRef } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Toaster, toast } from "sonner";

import {
  setToken,
  getToken,
  fetchHealth,
  fetchMe,
  cleanupAssets,
  deleteUser,
  updateAssetModeration,
  updateUserStatus,
  logoutClipSession,
} from "@/lib/api";
import { useStats, useUsers, useAssets, useRefreshDashboard, useTriadStatus, useOrganizations } from "@/hooks/use-dashboard";
import { useSocket } from "@/hooks/use-socket";

import { Header } from "@/components/Header";
import { clearToken } from "@/lib/api";
import { LoginForm } from "@/components/LoginForm";
import { TriadStatusPanel } from "@/components/TriadStatus";
import { StatsGrid } from "@/components/StatsGrid";
import { QuickActions } from "@/components/QuickActions";
import { UserList } from "@/components/UserList";
import { AssetList } from "@/components/AssetList";
import { ActivityLog } from "@/components/ActivityLog";
import { EndpointTable } from "@/components/EndpointTable";
import { ChatHistory } from "@/components/ChatHistory";
import { ErrorLog } from "@/components/ErrorLog";
import { AuditLog } from "@/components/AuditLog";
import { AdminTools } from "@/components/AdminTools";
import { OrgPanel } from "@/components/OrgPanel";
import type { User } from "@/lib/types";

const AUTH_TOKEN_KEY = "fixer_admin_token";

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 10_000, retry: 1 } },
});

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
  const [userRole, setUserRole] = useState<string | null>(null);
  const isSuperAdmin = userRole === "SUPER_ADMIN";
  const [userName, setUserName] = useState<string | null>(null);
  const [userPhone, setUserPhone] = useState<string | null>(null);
  const [userId, setUserId] = useState<string | null>(null);
  const [userCompany, setUserCompany] = useState<string | null>(null);
  const [userCompanyCode, setUserCompanyCode] = useState<string | null>(null);
  const [refreshingAccess, setRefreshingAccess] = useState(false);
  const [accessError, setAccessError] = useState<string | null>(null);
  const authGeneration = useRef(0);
  const [dashboardSession, setDashboardSession] = useState(0);
  const [showChatHistory, setShowChatHistory] = useState(false);
  const [assetModeration, setAssetModeration] = useState<string>();
  const canManageTeam = isSuperAdmin || (userRole === "ADMIN" && !!userCompanyCode);

  const queriesEnabled = loggedIn && !refreshingAccess;
  const { data: stats } = useStats(queriesEnabled);
  const { data: users, isLoading: usersLoading } = useUsers(queriesEnabled);
  const { data: assets, isLoading: assetsLoading } = useAssets(queriesEnabled, assetModeration);
  const { data: triadStatus, isLoading: triadLoading } = useTriadStatus(queriesEnabled && isSuperAdmin);
  const { data: organizations, isLoading: orgsLoading } = useOrganizations(queriesEnabled && canManageTeam);
  const refreshDashboard = useRefreshDashboard();

  const applyUser = useCallback((user: User) => {
    setUserRole(user.role ?? null);
    setUserName(user.name ?? null);
    setUserId(user.id ?? null);
    setUserPhone(user.phoneNumber ?? null);
    setUserCompany(user.companyName ?? null);
    setUserCompanyCode(user.companyCode ?? null);
  }, []);

  const forgetSession = useCallback(() => {
    authGeneration.current += 1;
    clearToken();
    localStorage.removeItem(AUTH_TOKEN_KEY);
    queryClient.clear();
    setAssetModeration(undefined);
    setLoggedIn(false);
    setUserRole(null);
    setUserName(null);
    setUserPhone(null);
    setUserId(null);
    setUserCompany(null);
    setUserCompanyCode(null);
    setShowChatHistory(false);
    setRefreshingAccess(false);
    setAccessError(null);
    void logoutClipSession();
  }, []);

  const clearScopedDashboard = useCallback(() => {
    authGeneration.current += 1;
    queryClient.clear();
    setUserRole(null);
    setUserCompany(null);
    setUserCompanyCode(null);
    setAssetModeration(undefined);
    setShowChatHistory(false);
    setAccessError(null);
    setRefreshingAccess(true);
  }, []);

  const reloadAccess = useCallback(() => {
    const token = getToken();
    if (!token) return;
    clearScopedDashboard();
    const generation = authGeneration.current;
    void fetchMe().then(({ user }) => {
      if (authGeneration.current !== generation || getToken() !== token) return;
      if (!user) throw new Error("Account unavailable");
      applyUser(user);
      setRefreshingAccess(false);
    }).catch((error: unknown) => {
      if (authGeneration.current !== generation || getToken() !== token) return;
      setAccessError(error instanceof Error ? error.message : "Could not verify dashboard access.");
    });
  }, [applyUser, clearScopedDashboard]);

  const { connected, socketId, logs, addLog, clearLogs, connect, disconnect, retryConnection } = useSocket({
    onAssetChange: () => refreshDashboard("upload:complete"),
    onAuthorizationLost: () => {
      clearLogs();
      clearScopedDashboard();
    },
    onReconnected: () => {
      clearLogs();
      reloadAccess();
    },
    onConnectionError: (error) => {
      if (["Account unavailable", "Invalid token", "Authentication required"].includes(error.message)) {
        forgetSession();
        toast.error("Your session expired or your account is unavailable. Sign in again.");
      } else {
        setAccessError("Could not connect to live updates. Retry the connection or sign in again.");
      }
    },
  });

  // Restore saved token on mount (avoids re-login on page refresh)
  useEffect(() => {
    const saved = localStorage.getItem(AUTH_TOKEN_KEY);
    if (!saved) return;
    const generation = ++authGeneration.current;

    async function restoreSession(token: string) {
      try {
        setToken(token);
        const { user } = await fetchMe();
        if (authGeneration.current !== generation || getToken() !== token) return;
        if (!user) throw new Error("Account unavailable");
        setLoggedIn(true);
        applyUser(user);
        addLog("auth", `Session restored: ${user.name}`);
        connect();
      } catch (err) {
        if (authGeneration.current !== generation || getToken() !== token) return;
        const msg = err instanceof Error ? err.message : "";
        // Only clear the saved token on definitive auth rejections (401/403),
        // not on transient network errors — so the session persists through
        // server restarts or brief connectivity issues.
        if (["HTTP 401", "HTTP 403", "Unauthorized", "Admin access required", "Account suspended", "Account unavailable"].includes(msg)) {
          clearToken();
          localStorage.removeItem(AUTH_TOKEN_KEY);
          toast.error("Your session expired or your account is unavailable. Sign in again.");
        }
      }
    }

    void restoreSession(saved);
  }, [addLog, applyUser, connect]);

  const handleLoginSuccess = useCallback((user: User) => {
    authGeneration.current += 1;
    // Token is already set in api.ts by the LoginForm; mirror it to localStorage
    const token = getToken();
    if (token) localStorage.setItem(AUTH_TOKEN_KEY, token);
    queryClient.clear();
    setAssetModeration(undefined);
    setShowChatHistory(false);
    setDashboardSession((session) => session + 1);
    setRefreshingAccess(false);
    setAccessError(null);
    setLoggedIn(true);
    applyUser(user);
    clearLogs();
    addLog("auth", `Dashboard auth: ${user.name}`);
    connect();
  }, [addLog, applyUser, clearLogs, connect]);

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

  const handleAssetModeration = useCallback(
    async (
      assetId: string,
      moderation: "ACTIVE" | "PAUSED" | "FLAGGED_FOR_REMOVAL" | "REMOVED",
      reason?: string,
    ) => {
      try {
        const result = await updateAssetModeration(assetId, { moderation, reason });
        toast.success(result.message);
        addLog("http", `Asset ${assetId.slice(0, 8)}: ${moderation.toLowerCase()}`);
      } catch (err) {
        const message = err instanceof Error ? err.message : "Failed to update asset moderation";
        toast.error(message);
        addLog("error", message);
      } finally {
        refreshDashboard();
      }
    },
    [addLog, refreshDashboard],
  );

  const handleUserStatusChange = useCallback(async (targetUserId: string, status: "ACTIVE" | "SUSPENDED", reason?: string) => {
    try {
      const result = await updateUserStatus(targetUserId, { status, reason });
      toast.success(result.message);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to update user status");
    } finally {
      refreshDashboard();
    }
  }, [refreshDashboard]);

  if (!loggedIn) {
    return <LoginForm onSuccess={handleLoginSuccess} />;
  }

  return (
    <div className="max-w-330 mx-auto px-4 sm:px-6 pt-5 sm:pt-8 pb-12 sm:pb-16">
      <Header
        onLogout={() => {
          disconnect();
          forgetSession();
        }}
        userName={userName}
        userPhone={userPhone}
        userCompany={userCompany}
      />

      {(refreshingAccess || accessError) && (
        <div className="mb-6">
          <p role={accessError ? "alert" : "status"}>{accessError ?? "Refreshing dashboard access..."}</p>
          {accessError && (
            <button type="button" className="underline" onClick={() => {
              setAccessError(null);
              if (connected) reloadAccess();
              else retryConnection();
            }}>
              Retry access check
            </button>
          )}
        </div>
      )}

      {!refreshingAccess && (
        <Fragment key={dashboardSession}>
      {isSuperAdmin && (
        <TriadStatusPanel
          triad={triadStatus}
          isLoading={triadLoading}
          wsConnected={connected}
          iosClients={stats?.iosClients}
        />
      )}

      {userRole === "ADMIN" && !userCompanyCode && (
        <p role="alert" className="mb-6 text-(--accent-amber)">
          This Team Admin account needs an organization before it can manage team members.
          Contact a Super Admin.
        </p>
      )}

      <StatsGrid stats={stats} />

      {showChatHistory && <ChatHistory onClose={() => setShowChatHistory(false)} />}

      <div className="grid grid-cols-2 gap-6 mb-8 max-[900px]:grid-cols-1">
        <UserList
          users={users}
          isLoading={usersLoading}
          onDeleteUser={isSuperAdmin ? handleDeleteUser : undefined}
          canManageStatus={canManageTeam}
          onUserStatusChange={handleUserStatusChange}
          currentUserId={userId ?? undefined}
          organizations={organizations}
          onRefresh={() => refreshDashboard()}
        />
        <AssetList
          assets={assets}
          isLoading={assetsLoading}
          viewerRole={userRole}
          moderationFilter={assetModeration}
          onModerationFilterChange={setAssetModeration}
          onModerate={canManageTeam ? handleAssetModeration : undefined}
        />
      </div>

      {isSuperAdmin && (
        <div className="mb-8">
          <OrgPanel
            organizations={organizations ?? []}
            isLoading={orgsLoading}
            onRefresh={() => refreshDashboard()}
          />
        </div>
      )}

      <QuickActions onAction={handleAction} addLog={addLog} canCleanup={isSuperAdmin} />

      <div className="grid grid-cols-2 gap-6 mb-8 max-[900px]:grid-cols-1">
        <ActivityLog logs={logs} onClear={clearLogs} />
        {isSuperAdmin && <ErrorLog />}
      </div>

      {isSuperAdmin && <div className="mb-8"><AuditLog /></div>}

      <EndpointTable />

      {canManageTeam && (
        <div className="mt-8">
          <AdminTools
            onReset={() => { refreshDashboard(); addLog("http", "Nuclear reset executed"); }}
            canReset={isSuperAdmin}
            companyCode={isSuperAdmin ? undefined : userCompanyCode ?? undefined}
          />
        </div>
      )}
        </Fragment>
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
