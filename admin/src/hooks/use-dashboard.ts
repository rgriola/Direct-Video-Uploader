/* ─── TanStack React Query hooks ─── */

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { fetchStats, fetchUsers, fetchAssets, fetchTriadStatus } from "@/lib/api";

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

export function useAssets(enabled = true) {
  return useQuery({
    queryKey: ["assets"],
    queryFn: async () => {
      const data = await fetchAssets();
      return data.assets;
    },
    refetchInterval: 15_000,
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

/** Invalidate specific dashboard queries based on event type, or all if unspecified */
export function useRefreshDashboard() {
  const qc = useQueryClient();
  return (eventType?: string) => {
    switch (eventType) {
      case "upload:complete":
        void qc.invalidateQueries({ queryKey: ["stats"] });
        void qc.invalidateQueries({ queryKey: ["assets"] });
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
        void qc.invalidateQueries({ queryKey: ["triad-status"] });
    }
  };
}
