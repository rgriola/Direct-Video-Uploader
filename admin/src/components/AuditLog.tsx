import { useInfiniteQuery, useQuery, useQueryClient } from "@tanstack/react-query";
import { fetchAuditLogs, fetchMediaIssues, fetchRetiredMuxEvents, updateAssetModeration, type RetiredMuxCursor } from "@/lib/api";
import { panelHeader, subTextPanelHeader, type AssetModeration } from "@/lib/types";
import { Icon } from "./Icon";
import { toast } from "sonner";
import { useState } from "react";
import { MediaSyncDetails, notifyMediaSyncResult } from "./MediaSyncDetails";

export function AuditLog() {
  const queryClient = useQueryClient();
  const [retryingId, setRetryingId] = useState<string | null>(null);
  const { data, isLoading, error } = useQuery({
    queryKey: ["audit-logs"],
    queryFn: fetchAuditLogs,
    refetchInterval: 30_000,
  });
  const issues = useQuery({
    queryKey: ["media-issues"],
    queryFn: fetchMediaIssues,
    refetchInterval: 30_000,
  });
  const retiredMux = useInfiniteQuery({
    queryKey: ["retired-mux-events"],
    queryFn: ({ pageParam }) => fetchRetiredMuxEvents(pageParam),
    initialPageParam: null as RetiredMuxCursor | null,
    getNextPageParam: (lastPage) => lastPage.nextCursor ?? undefined,
    refetchInterval: 30_000,
  });
  const retiredEvents = retiredMux.data?.pages.flatMap((page) => page.events);

  async function retryMedia(targetId: string, moderation: AssetModeration, reason?: string | null) {
    setRetryingId(targetId);
    try {
      const result = await updateAssetModeration(targetId, {
        moderation,
        reason: reason || "Retry media reconciliation",
      });
      notifyMediaSyncResult(result);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Media reconciliation retry failed");
    } finally {
      setRetryingId(null);
      void queryClient.invalidateQueries({ queryKey: ["audit-logs"] });
      void queryClient.invalidateQueries({ queryKey: ["media-issues"] });
      void queryClient.invalidateQueries({ queryKey: ["assets"] });
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
      <div className="border-b border-(--border-subtle) px-4 py-3">
        <h3 className="font-semibold text-(length:--text-sm)">Media requiring attention</h3>
        {issues.error ? (
          <p role="alert" className="mt-2 text-(--accent-red)">
            {issues.error instanceof Error ? issues.error.message : "Could not load media reconciliation issues"}
          </p>
        ) : issues.isLoading ? (
          <p className="mt-2 text-(--muted-foreground)">Loading media issues...</p>
        ) : !issues.data?.issues.length ? (
          <p className="mt-2 text-(--muted-foreground)">No media requires attention.</p>
        ) : (
          <ul className="mt-2 max-h-80 overflow-y-auto divide-y divide-(--border-subtle)">
            {issues.data.issues.map((issue) => (
              <li key={issue.id} className="py-2 text-(length:--text-xs)">
                <p className="font-semibold">
                  {issue.mediasourceId ? `#${issue.mediasourceId}` : issue.id} · {issue.moderation.replace(/_/g, " ")}
                </p>
                <MediaSyncDetails assetId={issue.id} media={issue} canConfirm />
                <button
                  type="button"
                  disabled={retryingId === issue.id}
                  onClick={() => void retryMedia(issue.id, issue.moderation, issue.moderationReason)}
                  className="px-2 py-1 rounded-(--radius-md) border border-(--border-subtle) text-(--foreground) disabled:opacity-50"
                >
                  {retryingId === issue.id ? "Retrying..." : "Retry media reconciliation"}
                </button>
              </li>
            ))}
          </ul>
        )}
        {issues.data?.hasMore && (
          <p role="status" className="mt-2 text-(--accent-amber)">More than 100 media issues exist. Resolve these to see the rest.</p>
        )}
      </div>
      <div className="border-b border-(--border-subtle) px-4 py-3">
        <h3 className="font-semibold text-(length:--text-sm)">Mux references after account deletion</h3>
        <p className="mt-1 text-(--muted-foreground)">
          Investigate these references with Mux. They are retained for review and are not automatically cleared.
        </p>
        {retiredMux.error && (
          <p role="alert" className="mt-2 text-(--accent-red)">
            {retiredMux.error instanceof Error ? retiredMux.error.message : "Could not load retired Mux references"}
          </p>
        )}
        {retiredMux.isLoading ? (
          <p className="mt-2 text-(--muted-foreground)">Loading retired Mux references...</p>
        ) : retiredEvents?.length === 0 ? (
          <p className="mt-2 text-(--muted-foreground)">No retired Mux references have been reported.</p>
        ) : retiredEvents && (
          <ul className="mt-2 max-h-80 overflow-y-auto divide-y divide-(--border-subtle)">
            {retiredEvents.map((event) => (
              <li key={`${event.operationId}:${event.muxAssetId}`} className="py-2 text-(length:--text-xs)">
                <p>Operation: <code>{event.operationId}</code></p>
                <p>Mux asset: <code>{event.muxAssetId}</code></p>
                {event.attempt.originalMuxAssetId && (
                  <p>Previously linked Mux asset: <code>{event.attempt.originalMuxAssetId}</code></p>
                )}
                <time dateTime={event.firstSeenAt}>{new Date(event.firstSeenAt).toLocaleString()}</time>
              </li>
            ))}
          </ul>
        )}
        {retiredMux.hasNextPage && (
          <button
            type="button"
            disabled={retiredMux.isFetchingNextPage}
            onClick={() => void retiredMux.fetchNextPage()}
            className="mt-2 px-2 py-1 rounded-(--radius-md) border border-(--border-subtle) text-(--foreground) disabled:opacity-50"
          >
            {retiredMux.isFetchingNextPage ? "Loading..." : "Load more Mux references"}
          </button>
        )}
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
                  onClick={() => void retryMedia(log.targetId, "REMOVED", log.reason)}
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
