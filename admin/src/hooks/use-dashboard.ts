/* ─── TanStack React Query hooks ─── */

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { fetchStats, fetchUsers, fetchAssets, fetchMyAssets, fetchTriadStatus, fetchOrganizations, fetchMonitoring, fetchUploadCapabilities } from "@/lib/api";

export function useStats(enabled = true) {
  return useQuery({
    queryKey: ["stats"],
    queryFn: fetchStats,
    refetchInterval: 10_000,
    enabled,
  });
}

export function useUsers(enabled = true) {
  return useQuery({
    queryKey: ["users"],
    queryFn: async () => {
      const data = await fetchUsers();
      return data.users;
    },
    refetchInterval: 15_000,
    enabled,
  });
}

export function useAssets(enabled = true, moderation?: string) {
  return useQuery({
    queryKey: ["assets", moderation ?? "default"],
    queryFn: async () => {
      const data = await fetchAssets(moderation);
      return data.assets;
    },
    refetchInterval: 15_000,
    enabled,
  });
}

export function useMyAssets(enabled = true) {
  return useQuery({
    queryKey: ["my-assets"],
    queryFn: async () => {
      const data = await fetchMyAssets();
      return data.assets;
    },
    refetchInterval: 15_000,
    enabled,
  });
}

export function useUploadCapabilities(enabled = true) {
  return useQuery({
    queryKey: ["upload-capabilities"],
    queryFn: fetchUploadCapabilities,
    staleTime: 60_000,
    enabled,
  });
}

export function useOrganizations(enabled = true) {
  return useQuery({
    queryKey: ["organizations"],
    queryFn: async () => {
      const data = await fetchOrganizations();
      return data.organizations;
    },
    refetchInterval: 30_000,
    enabled,
  });
}

export function useTriadStatus(enabled = true) {
  return useQuery({
    queryKey: ["triad-status"],
    queryFn: fetchTriadStatus,
    refetchInterval: 15_000,
    enabled,
  });
}

export function useMonitoring(enabled = true) {
  return useQuery({
    queryKey: ["monitoring"],
    queryFn: fetchMonitoring,
    refetchInterval: 30_000,
    enabled,
  });
}

/** Invalidate specific dashboard queries based on event type, or all if unspecified */
export function useRefreshDashboard() {
  const qc = useQueryClient();
  return (eventType?: string) => {
    switch (eventType) {
      case "upload:complete":
        void qc.invalidateQueries({ queryKey: ["stats"] });
        void qc.invalidateQueries({ queryKey: ["assets"] });
        void qc.invalidateQueries({ queryKey: ["my-assets"] });
        break;
      case "user:connected":
      case "user:disconnected":
        void qc.invalidateQueries({ queryKey: ["users"] });
        void qc.invalidateQueries({ queryKey: ["triad-status"] });
        break;
      default:
        void qc.invalidateQueries({ queryKey: ["stats"] });
        void qc.invalidateQueries({ queryKey: ["users"] });
        void qc.invalidateQueries({ queryKey: ["assets"] });
        void qc.invalidateQueries({ queryKey: ["my-assets"] });
        void qc.invalidateQueries({ queryKey: ["organizations"] });
        void qc.invalidateQueries({ queryKey: ["triad-status"] });
        void qc.invalidateQueries({ queryKey: ["monitoring"] });
    }
  };
}
