import { useQuery, useQueryClient } from "@tanstack/react-query";
import { fetchAuditLogs, updateAssetModeration } from "@/lib/api";
import { panelHeader, subTextPanelHeader } from "@/lib/types";
import { Icon } from "./Icon";
import { toast } from "sonner";
import { useState } from "react";

export function AuditLog() {
  const queryClient = useQueryClient();
  const [retryingId, setRetryingId] = useState<string | null>(null);
  const { data, isLoading, error } = useQuery({
    queryKey: ["audit-logs"],
    queryFn: fetchAuditLogs,
    refetchInterval: 30_000,
  });

  async function retryRemoval(targetId: string, reason?: string | null) {
    setRetryingId(targetId);
    try {
      const result = await updateAssetModeration(targetId, {
        moderation: "REMOVED",
        reason: reason || "Retry media cleanup",
      });
      toast.success(result.message);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Media cleanup retry failed");
    } finally {
      setRetryingId(null);
      void queryClient.invalidateQueries({ queryKey: ["audit-logs"] });
    }
  }

  return (
    <section className="bg-(--card) border border-(--border-subtle) rounded-(--radius-xl) overflow-hidden">
      <div className={panelHeader}>
        <h2 className="text-(length:--text-lg) font-semibold flex items-center gap-2">
          <Icon name="activity" /> Moderation Audit{" "}
          <span className={subTextPanelHeader}>{data?.logs.length ?? 0}</span>
        </h2>
      </div>
      {error ? (
        <p role="alert" className="p-4 text-(--accent-red)">
          {error instanceof Error ? error.message : "Could not load audit history"}
        </p>
      ) : isLoading ? (
        <p className="p-4 text-(--muted-foreground)">Loading audit history...</p>
      ) : !data?.logs.length ? (
        <p className="p-4 text-(--muted-foreground)">No moderation actions recorded.</p>
      ) : (
        <ol className="max-h-80 overflow-y-auto divide-y divide-(--border-subtle)">
          {data.logs.map((log) => (
            <li key={log.id} className="px-4 py-3 text-(length:--text-xs)">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="font-semibold text-(--foreground)">{log.action.replace(/_/g, " ")}</span>
                <time dateTime={log.createdAt} className="text-(--muted-foreground)">
                  {new Date(log.createdAt).toLocaleString()}
                </time>
              </div>
              <p className="mt-1 text-(--muted-foreground)">
                {log.targetType} <code>{log.targetId}</code> · actor <code>{log.actorUserId}</code>
              </p>
              {log.reason && <p className="mt-1 break-words">{log.reason}</p>}
              {log.targetType === "ASSET" && log.action === "ASSET_REMOVED" && (
                <button
                  type="button"
                  disabled={retryingId === log.targetId}
                  onClick={() => void retryRemoval(log.targetId, log.reason)}
                  className="mt-2 px-2 py-1 rounded-(--radius-md) border border-(--border-subtle) text-(--foreground) disabled:opacity-50"
                >
                  {retryingId === log.targetId ? "Retrying..." : "Retry media cleanup"}
                </button>
              )}
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
