import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { confirmMuxPlaybackCreation, type MediaSyncResponse } from "@/lib/api";
import type { MediaSyncInfo } from "@/lib/types";

export function notifyMediaSyncResult(result: MediaSyncResponse) {
  if (result.mediaSyncState === "SYNCED") toast.success(result.message);
  else if (result.mediaSyncState === "ERROR") toast.error(result.message);
  else toast.info(result.message);
}

export function MediaSyncDetails({
  assetId,
  media,
  canConfirm,
}: {
  assetId: string;
  media: MediaSyncInfo;
  canConfirm: boolean;
}) {
  const [confirming, setConfirming] = useState(false);
  const queryClient = useQueryClient();
  const operationId = media.mediaCreateOperationId;
  const status = operationId || media.mediaSyncState === "ERROR"
    ? "Needs attention"
    : media.mediaSyncState === "PENDING"
      ? "Pending"
      : media.mediaSyncState === "SYNCED"
        ? "Synced"
        : "Unknown";

  async function confirmCreation() {
    if (!operationId) return;
    const muxAsset = media.mediaCreateMuxAssetId ?? "unknown";
    const started = media.mediaCreateStartedAt
      ? new Date(media.mediaCreateStartedAt).toLocaleString()
      : "unknown";
    if (!window.confirm(
      `Only continue if Mux has confirmed that the playback-ID creation request for Mux asset ${muxAsset}, started ${started}, cannot complete now or later. Have you received that confirmation?`,
    )) return;
    const entered = window.prompt("Record how and when Mux confirmed this (required):", "");
    if (entered === null) return;
    const reason = entered.trim();
    if (!reason) {
      toast.error("A confirmation note is required");
      return;
    }

    setConfirming(true);
    try {
      const result = await confirmMuxPlaybackCreation(assetId, operationId, reason);
      notifyMediaSyncResult(result);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Could not confirm playback creation");
    } finally {
      setConfirming(false);
      void queryClient.invalidateQueries({ queryKey: ["assets"] });
      void queryClient.invalidateQueries({ queryKey: ["media-issues"] });
      void queryClient.invalidateQueries({ queryKey: ["audit-logs"] });
    }
  }

  if (!media.mediaSyncState && !operationId) return null;
  return (
    <div className="my-3 rounded-(--radius-md) border border-(--border-subtle) px-3 py-2 text-(length:--text-xs)">
      <p className="font-semibold">
        Media reconciliation: {status}
      </p>
      {media.mediaSyncError && <p role="status" className="mt-1 text-(--accent-red)">{media.mediaSyncError}</p>}
      {(media.mediaPlaybackUnavailable || media.mediaPlaybackReset || operationId) && (
        <p className="mt-1">Playback remains unavailable while moderation or media reconciliation is in effect.</p>
      )}
      {media.mediaSyncNextAt && media.mediaSyncState !== "SYNCED" && (
        <p className="mt-1">Next check: {new Date(media.mediaSyncNextAt).toLocaleString()}</p>
      )}
      {operationId && (
        <div className="mt-2">
          <p>Playback creation may still be in progress or its outcome is unknown. Keep this video unavailable until Mux confirms the request cannot complete later.</p>
          <p className="mt-1 break-all">Mux asset: <code>{media.mediaCreateMuxAssetId ?? "unknown"}</code></p>
          <p>Started: {media.mediaCreateStartedAt ? new Date(media.mediaCreateStartedAt).toLocaleString() : "unknown"}</p>
          <p className="break-all">Reconciliation operation: <code>{operationId}</code></p>
          {canConfirm && (
            <button
              type="button"
              disabled={confirming}
              onClick={() => void confirmCreation()}
              className="mt-2 px-2 py-1 rounded-(--radius-md) border border-(--border-subtle) text-(--foreground) disabled:opacity-50"
            >
              {confirming ? "Confirming..." : "Confirm Mux cannot complete request"}
            </button>
          )}
        </div>
      )}
    </div>
  );
}
