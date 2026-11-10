import { useCallback, useState } from "react";
import { toast } from "sonner";
import { useAuth } from "@/auth/AuthProvider";
import {
  cleanupAssets,
  deleteUser,
  fetchHealth,
  fetchMe,
  updateAssetModeration,
  updateUserStatus,
} from "@/lib/api";
import { useAssets, useOrganizations, useRefreshDashboard, useStats, useTriadStatus, useUsers, useMonitoring } from "@/hooks/use-dashboard";
import { TriadStatusPanel } from "@/components/TriadStatus";
import { MonitoringPanel } from "@/components/MonitoringPanel";
import { StatsGrid } from "@/components/StatsGrid";
import { QuickActions } from "@/components/QuickActions";
import { UserList } from "@/components/UserList";
import { AssetList } from "@/components/AssetList";
import { notifyMediaSyncResult } from "@/components/MediaSyncDetails";
import { ActivityLog } from "@/components/ActivityLog";
import { EndpointTable } from "@/components/EndpointTable";
import { ChatHistory } from "@/components/ChatHistory";
import { ErrorLog } from "@/components/ErrorLog";
import { AuditLog } from "@/components/AuditLog";
import { AdminTools } from "@/components/AdminTools";
import { OrgPanel } from "@/components/OrgPanel";

export function AdminDashboard() {
  const { user, loggedIn, connected, logs, addLog, clearLogs } = useAuth();
  const userRole = user?.role ?? null;
  const isSuperAdmin = userRole === "SUPER_ADMIN";
  const userCompanyCode = user?.companyCode ?? null;
  const canManageTeam = isSuperAdmin || (userRole === "ADMIN" && !!userCompanyCode);
  const [showChatHistory, setShowChatHistory] = useState(false);
  const [assetModeration, setAssetModeration] = useState<string>();

  const { data: stats } = useStats(loggedIn);
  const { data: users, isLoading: usersLoading } = useUsers(loggedIn);
  const { data: assets, isLoading: assetsLoading } = useAssets(loggedIn, assetModeration);
  const { data: triadStatus, isLoading: triadLoading } = useTriadStatus(loggedIn && isSuperAdmin);
  const monitoring = useMonitoring(loggedIn && isSuperAdmin);
  const { data: organizations, isLoading: orgsLoading } = useOrganizations(loggedIn && canManageTeam);
  const refreshDashboard = useRefreshDashboard();

  const handleAction = useCallback(async (action: string) => {
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
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown error";
      toast.error(message);
      addLog("error", message);
    }
  }, [loggedIn, addLog, refreshDashboard]);

  const handleDeleteUser = useCallback(async (targetUserId: string, targetUserName: string) => {
    try {
      const res = await deleteUser(targetUserId);
      const deleted = res.deleted;
      toast.success(res.message, {
        description: `${deleted.assets} assets, ${deleted.clips} clips, ${deleted.chatMessages} messages removed`,
        duration: 6000,
      });
      addLog("http", `Deleted user: ${targetUserName}`);
      refreshDashboard();
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Failed to delete user");
      addLog("error", `Delete user failed: ${error instanceof Error ? error.message : "Unknown error"}`);
    }
  }, [addLog, refreshDashboard]);

  const handleAssetModeration = useCallback(async (
    assetId: string,
    moderation: "ACTIVE" | "PAUSED" | "FLAGGED_FOR_REMOVAL" | "REMOVED",
    reason?: string,
  ) => {
    try {
      const result = await updateAssetModeration(assetId, { moderation, reason });
      notifyMediaSyncResult(result);
      addLog(result.mediaSyncState === "ERROR" ? "error" : "http", `Asset ${assetId.slice(0, 8)}: ${moderation.toLowerCase()} (${result.mediaSyncState.toLowerCase()})`);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Failed to update asset moderation";
      toast.error(message);
      addLog("error", message);
    } finally {
      refreshDashboard();
    }
  }, [addLog, refreshDashboard]);

  const handleUserStatusChange = useCallback(async (targetUserId: string, status: "ACTIVE" | "SUSPENDED", reason?: string) => {
    try {
      const result = await updateUserStatus(targetUserId, { status, reason });
      toast.success(result.message);
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Failed to update user status");
    } finally {
      refreshDashboard();
    }
  }, [refreshDashboard]);

  return (
    <>
      {isSuperAdmin && (
        <TriadStatusPanel triad={triadStatus} isLoading={triadLoading} wsConnected={connected} iosClients={stats?.iosClients} />
      )}
      {isSuperAdmin && (
        <MonitoringPanel snapshot={monitoring.data} isLoading={monitoring.isLoading} isError={monitoring.isError} />
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
          currentUserId={user?.id}
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
          <OrgPanel organizations={organizations ?? []} isLoading={orgsLoading} onRefresh={() => refreshDashboard()} />
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
    </>
  );
}
