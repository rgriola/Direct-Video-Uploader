/* ─── TanStack React Query hooks ─── */

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { fetchStats, fetchUsers, fetchAssets, fetchTriadStatus } from "@/lib/api";

export function useStats() {
  return useQuery({
    queryKey: ["stats"],
    queryFn: fetchStats,
    refetchInterval: 10_000,
  });
}

export function useUsers() {
  return useQuery({
    queryKey: ["users"],
    queryFn: async () => {
      const data = await fetchUsers();
      return data.users;
    },
    refetchInterval: 15_000,
  });
}

export function useAssets() {
  return useQuery({
    queryKey: ["assets"],
    queryFn: async () => {
      const data = await fetchAssets();
      return data.assets;
    },
    refetchInterval: 15_000,
  });
}

export function useTriadStatus() {
  return useQuery({
    queryKey: ["triad-status"],
    queryFn: fetchTriadStatus,
    refetchInterval: 5_000,
  });
}

/** Invalidate dashboard data (call after mutations or WS events) */
export function useRefreshDashboard() {
  const qc = useQueryClient();
  return () => {
    void qc.invalidateQueries({ queryKey: ["stats"] });
    void qc.invalidateQueries({ queryKey: ["users"] });
    void qc.invalidateQueries({ queryKey: ["assets"] });
    void qc.invalidateQueries({ queryKey: ["triad-status"] });
  };
}
