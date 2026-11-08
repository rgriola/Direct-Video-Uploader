import { useEffect, useState, useCallback } from "react";
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
  const [showChatHistory, setShowChatHistory] = useState(false);
  const [assetModeration, setAssetModeration] = useState<string>();
  const canManageTeam = isSuperAdmin || (userRole === "ADMIN" && !!userCompanyCode);

  const { data: stats } = useStats(loggedIn);
  const { data: users, isLoading: usersLoading } = useUsers(loggedIn);
  const { data: assets, isLoading: assetsLoading } = useAssets(loggedIn, assetModeration);
  const { data: triadStatus, isLoading: triadLoading } = useTriadStatus(loggedIn && isSuperAdmin);
  const { data: organizations, isLoading: orgsLoading } = useOrganizations(loggedIn && canManageTeam);
  const refreshDashboard = useRefreshDashboard();

  const { connected, socketId, logs, addLog, clearLogs, connect, disconnect } = useSocket(() => {
    refreshDashboard("upload:complete");
  });

  // Restore saved token on mount (avoids re-login on page refresh)
  useEffect(() => {
    const saved = localStorage.getItem(AUTH_TOKEN_KEY);
    if (!saved) return;

    async function restoreSession(token: string) {
      try {
        setToken(token);
        const { user } = await fetchMe();
        if (user) {
          setLoggedIn(true);
          setUserRole(user.role ?? null);
          setUserName(user.name ?? null);
          setUserId(user.id ?? null);
          setUserPhone(user.phoneNumber ?? null);
          setUserCompany(user.companyName ?? null);
          setUserCompanyCode(user.companyCode ?? null);
          addLog("auth", `Session restored: ${user.name}`);
          connect();
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : "";
        // Only clear the saved token on definitive auth rejections (401/403),
        // not on transient network errors — so the session persists through
        // server restarts or brief connectivity issues.
        if (msg === "HTTP 401" || msg === "HTTP 403" || msg === "Unauthorized" || msg === "Admin access required") {
          localStorage.removeItem(AUTH_TOKEN_KEY);
        }
      }
    }

    void restoreSession(saved);
  }, [addLog, connect]);

  const handleLoginSuccess = useCallback((user: User) => {
    // Token is already set in api.ts by the LoginForm; mirror it to localStorage
    const token = getToken();
    if (token) localStorage.setItem(AUTH_TOKEN_KEY, token);
    queryClient.clear();
    setAssetModeration(undefined);
    setLoggedIn(true);
    setUserRole(user.role ?? null);
    setUserName(user.name);
    setUserPhone(user.phoneNumber ?? null);
    setUserId(user.id);
    setUserCompany(user.companyName ?? null);
    setUserCompanyCode(user.companyCode ?? null);
    addLog("auth", `Dashboard auth: ${user.name}`);
    connect();
  }, [addLog, connect, setLoggedIn]);

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
          void logoutClipSession();
        }}
        userName={userName}
        userPhone={userPhone}
        userCompany={userCompany}
      />

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
