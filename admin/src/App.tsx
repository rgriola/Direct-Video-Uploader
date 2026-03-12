import { useEffect, useState, useCallback } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Toaster, toast } from "sonner";

import { setToken, getToken, fetchHealth, fetchMe, cleanupAssets } from "@/lib/api";
import { useStats, useUsers, useAssets, useRefreshDashboard, useTriadStatus } from "@/hooks/use-dashboard";
import { useSocket } from "@/hooks/use-socket";

import { Header } from "@/components/Header";
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
  const [refreshing, setRefreshing] = useState(false);
  const [loggedIn, setLoggedIn] = useState(false);
  const [showChatHistory, setShowChatHistory] = useState(false);

  const { data: stats } = useStats(loggedIn);
  const { data: users, isLoading: usersLoading } = useUsers(loggedIn);
  const { data: assets, isLoading: assetsLoading } = useAssets(loggedIn);
  const { data: triadStatus, isLoading: triadLoading } = useTriadStatus(loggedIn);
  const refreshDashboard = useRefreshDashboard();

  const { connected, socketId, logs, addLog, clearLogs, connect } = useSocket(() => {
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

  const handleLoginSuccess = useCallback((userName: string) => {
    // Token is already set in api.ts by the LoginForm; mirror it to localStorage
    const token = getToken();
    if (token) localStorage.setItem(AUTH_TOKEN_KEY, token);
    setLoggedIn(true);
    addLog("auth", `Dashboard auth: ${userName}`);
    connect();
  }, [addLog, connect]);

  const handleRefresh = useCallback(async () => {
    setRefreshing(true);
    refreshDashboard();
    addLog("http", "Dashboard refreshed");
    setTimeout(() => setRefreshing(false), 600);
  }, [refreshDashboard, addLog]);

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

  if (!loggedIn) {
    return <LoginForm onSuccess={handleLoginSuccess} />;
  }

  return (
    <div className="max-w-330 mx-auto px-4 sm:px-6 pt-8 pb-16">
      <Header
        wsConnected={connected}
        onRefresh={handleRefresh}
        refreshing={refreshing}
        iosClients={stats?.iosClients}
      />

      <TriadStatusPanel triad={triadStatus} isLoading={triadLoading} />

      <StatsGrid stats={stats} wsConnected={connected} wsId={socketId} />

      <QuickActions onAction={handleAction} addLog={addLog} />

      {showChatHistory && <ChatHistory onClose={() => setShowChatHistory(false)} />}

      <div className="grid grid-cols-2 gap-6 mb-8 max-[900px]:grid-cols-1">
        <UserList users={users} isLoading={usersLoading} />
        <AssetList assets={assets} isLoading={assetsLoading} />
      </div>

      <div className="grid grid-cols-2 gap-6 mb-8 max-[900px]:grid-cols-1">
        <ActivityLog logs={logs} onClear={clearLogs} />
        <ErrorLog />
      </div>

      <EndpointTable />
    </div>
  );
}
