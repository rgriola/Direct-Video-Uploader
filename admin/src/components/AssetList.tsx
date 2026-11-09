/**
 * AssetList.tsx — Admin Dashboard panel showing all uploaded video assets.
 *
 * DATA FLOW:
 *   1. Role dashboards fetch scoped assets through the dashboard query hooks
 *   2. The dashboard passes the array of Asset objects + loading state to this component
 *   3. This component renders each asset as a clickable row (AssetRow)
 *   4. Clicking a row toggles an expanded detail panel (accordion-style, one at a time)
 *
 * COMPONENT STRUCTURE:
 *   AssetList          — Outer card with header + scrollable list
 *     └─ AssetRow      — One clickable row per asset (collapsed + expanded states)
 *          ├─ FormSection  — Slug, description, type, priority from iOS context form
 *          └─ ClipSection  — Resolution, codec, orientation, file size, duration from Mux
 *
 * HELPER COMPONENTS:
 *   DetailRow  — Single "Label: Value" row used in both sections
 *   Empty      — Placeholder shown when loading or no assets
 */

import { useState } from "react";
import { toast } from "sonner";
import type { Asset } from "@/lib/types";
import { panelHeader, subTextPanelHeader } from "@/lib/types";
import { Icon, type IconName } from "./Icon";
import { MediaSyncDetails } from "./MediaSyncDetails";

// ─── Status Configuration ────────────────────────────────────────────
//
// Maps asset.status values to visual indicators used in AssetRow.
//   statusIcons   → icon name shown inside the colored circle
//   statusClasses → Tailwind classes for the status pill badge
//   priorityColors → text color for the priority field in form response

const statusIcons: Record<string, IconName> = {
  READY: "success",
  PROCESSING: "processing",
  UPLOADING: "outgoing",
  ERROR: "error",
};

const statusClasses: Record<string, string> = {
  READY: "bg-(--accent-green-glow) text-(--accent-green)",
  PROCESSING: "bg-(--accent-amber-glow) text-(--accent-amber)",
  UPLOADING: "bg-(--accent-blue-glow) text-(--accent-blue)",
  ERROR: "bg-(--accent-red-glow) text-(--accent-red)",
};

const priorityColors: Record<string, string> = {
  CRITICAL: "text-(--accent-red)",
  HIGH: "text-(--accent-amber)",
  MEDIUM: "text-(--accent-green)",
  LOW: "text-(--muted-foreground)",
};

// ─── Utilities ───────────────────────────────────────────────────────

/** Format seconds → "M:SS" (e.g. 125 → "2:05"). Returns "" if null/undefined. */
function formatDuration(seconds: number | null | undefined): string {
  if (seconds == null) return "";
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

// ─── Main Component ──────────────────────────────────────────────────

interface AssetListProps {
  assets?: Asset[];
  isLoading: boolean;
  title?: string;
  emptyText?: string;
  viewerRole?: string | null;
  moderationFilter?: string;
  onModerationFilterChange?: (moderation?: string) => void;
  onModerate?: (
    assetId: string,
    moderation: "ACTIVE" | "PAUSED" | "FLAGGED_FOR_REMOVAL" | "REMOVED",
    reason?: string,
  ) => Promise<void>;
}

export function AssetList({
  assets,
  isLoading,
  title = "Assets",
  emptyText = "No Assets on the server. Uploaded Video will appear here.",
  viewerRole,
  moderationFilter,
  onModerationFilterChange,
  onModerate,
}: AssetListProps) {
  /* Accordion: only one row expanded at a time. Stores asset.id or null. */
  const [expandedId, setExpandedId] = useState<string | null>(null);

  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius-xl) overflow-hidden">
      {/* Panel header — "Assets [count]" */}
      <div className={panelHeader}>
        <h2 className="text-(length:--text-lg) font-semibold flex items-center gap-2">
          <Icon name="assets" /> {title}{" "}
          <span className={subTextPanelHeader}>
            {assets?.length ?? 0}
          </span>
        </h2>
        {(viewerRole === "ADMIN" || viewerRole === "SUPER_ADMIN") && (
          <select
            aria-label="Filter assets by moderation"
            value={moderationFilter ?? ""}
            onChange={(event) => onModerationFilterChange?.(event.target.value || undefined)}
            className="px-2 py-1 rounded-(--radius-md) text-(length:--text-xs) bg-(--card) border border-(--border) text-(--foreground)"
          >
            <option value="">Active assets</option>
            <option value="PAUSED">Paused assets</option>
            {viewerRole === "SUPER_ADMIN" && <option value="FLAGGED_FOR_REMOVAL">Removal queue</option>}
          </select>
        )}
      </div>

      {/* Scrollable list — max 400px, then scrolls */}
      <div className="max-h-100 overflow-y-auto scrollbar-hide">
        {isLoading ? (
          <Empty icon="assets" text="Loading assets..." />
        ) : !assets?.length ? (
          <Empty icon="assets" text={emptyText} />
        ) : (
          assets.map((asset) => (
            <AssetRow
              key={asset.id}
              asset={asset}
              isExpanded={expandedId === asset.id}
              onToggle={() => setExpandedId(expandedId === asset.id ? null : asset.id)}
              viewerRole={viewerRole}
              onModerate={onModerate}
            />
          ))
        )}
      </div>
    </div>
  );
}

// ─── Asset Row ───────────────────────────────────────────────────────
//
// Each asset renders as a clickable row with two states:
//   Collapsed: [icon] [title + detail summary] [badges + chevron]
//   Expanded:  collapsed row + detail panel underneath

interface AssetRowProps {
  asset: Asset;
  isExpanded: boolean;
  onToggle: () => void;
  viewerRole?: string | null;
  onModerate?: AssetListProps["onModerate"];
}

function AssetRow({ asset, isExpanded, onToggle, viewerRole, onModerate }: AssetRowProps) {
  const clip = asset.clips?.[0];
  const missingForm = !asset.formResponse && asset.status === "READY";

  // Title: show slug if available, fall back to mediasource ID, then asset ID
  const title = asset.formResponse?.slug || asset.mediasourceId || asset.id;

  // One-line summary: "#100000017 · 1 clip · 2:05 · 1920x1080 · by Rod Griola"
  const details = [
    asset.mediasourceId ? `#${asset.mediasourceId}` : null,
    asset.clipCount ? `${asset.clipCount} clip${asset.clipCount !== 1 ? "s" : ""}` : null,
    formatDuration(asset.totalDuration) || null,
    clip?.resolution ?? null,
    asset.user?.name ? `by ${asset.user.name}` : null,
  ]
    .filter(Boolean)
    .join(" · ");

  // Clip viewer URL: prefer mediasourceUrl, fall back to /clips/:id
  const clipUrl = asset.mediasourceUrl || (asset.mediasourceId ? `/clips/${asset.mediasourceId}` : null);
  const isSuperAdmin = viewerRole === "SUPER_ADMIN";
  const canPlay = !!clipUrl && asset.moderation === "ACTIVE"
    && !asset.mediaPlaybackUnavailable
    && !asset.mediaPlaybackReset
    && !asset.mediaCreateOperationId;

  async function changeModeration(
    moderation: "ACTIVE" | "PAUSED" | "FLAGGED_FOR_REMOVAL" | "REMOVED",
  ) {
    let reason: string | undefined;
    if (moderation === "FLAGGED_FOR_REMOVAL" || moderation === "REMOVED") {
      if (moderation === "REMOVED" && asset.moderation === "REMOVED") {
        reason = asset.moderationReason ?? "Retry media cleanup";
      } else {
        const entered = window.prompt(
          moderation === "REMOVED" ? "Reason for permanent removal:" : "Reason for flagging this asset:",
          "",
        );
        if (entered === null) return;
        reason = entered.trim();
        if (!reason) {
          toast.error("A reason is required");
          return;
        }
      }
    } else {
      const entered = window.prompt("Optional moderation note:", "");
      if (entered === null) return;
      reason = entered.trim() || undefined;
    }

    if (
      moderation === "REMOVED" &&
      asset.moderation !== "REMOVED" &&
      !window.confirm("Permanently remove this asset and delete its media? This cannot be undone.")
    ) {
      return;
    }
    await onModerate?.(asset.id, moderation, reason);
  }

  return (
    <div className={`border-b border-(--border-subtle) last:border-b-0 ${missingForm ? "border-l-3 border-l-(--accent-red) bg-(--accent-red-glow)" : ""} ${asset.moderation !== "ACTIVE" ? "opacity-80" : ""}`}>

      {/* ── Collapsed row — always visible, click to toggle ── */}
      <button
        onClick={onToggle}
        aria-expanded={isExpanded}
        className="flex items-center w-full px-6 py-4 hover:bg-(--card-hover) transition-colors cursor-pointer text-left bg-transparent border-0 text-inherit font-inherit"
      >
        {/* Status icon circle */}
        <div className="w-10.5 h-10.5 rounded-(--radius-lg) bg-(--secondary) flex items-center justify-center text-(length:--text-base) mr-3.5 shrink-0">
          <Icon name={statusIcons[asset.status] ?? "assets"} />
        </div>

        {/* Title + detail line */}
        <div className="flex-1 min-w-0">
          <p className="text-(length:--text-sm) font-semibold truncate">{title}</p>
          <p className="text-(length:--text-xs) text-(--muted-foreground) mt-0.5 flex items-center gap-2">
            {details}
            {asset.formResponse && (
              <span className="inline-flex items-center gap-1 shrink-0">
                <Icon name="form" /> Form
              </span>
            )}
          </p>
        </div>

        {/* Right side: badges + chevron */}
        <div className="shrink-0 flex items-center gap-2">
          {missingForm && (
            <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-(--radius-md) text-(length:--text-xs) font-semibold bg-(--accent-red-glow) text-(--accent-red)">
              <Icon name="warning" /> No Form
            </span>
          )}
          <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-(--radius-md) text-(length:--text-xs) font-semibold ${statusClasses[asset.status] ?? ""}`}>
            {asset.status}
          </span>
          {asset.moderation !== "ACTIVE" && (
            <span className="inline-flex items-center px-2 py-0.5 rounded-(--radius-md) text-(length:--text-xs) font-semibold bg-(--accent-amber-glow) text-(--accent-amber)">
              {asset.moderation === "FLAGGED_FOR_REMOVAL" ? "FLAGGED" : asset.moderation}
            </span>
          )}
          {viewerRole !== "USER" && asset.mediaSyncState === "ERROR" && (
            <span className="inline-flex items-center px-2 py-0.5 rounded-(--radius-md) text-(length:--text-xs) font-semibold bg-(--accent-red-glow) text-(--accent-red)">
              MEDIA NEEDS ATTENTION
            </span>
          )}
          {viewerRole !== "USER" && asset.mediaSyncState === "PENDING" && (
            <span className="inline-flex items-center px-2 py-0.5 rounded-(--radius-md) text-(length:--text-xs) font-semibold bg-(--accent-amber-glow) text-(--accent-amber)">
              MEDIA PENDING
            </span>
          )}
          {viewerRole === "USER" && asset.moderation === "ACTIVE" && (asset.mediaPlaybackUnavailable || asset.mediaPlaybackReset) && (
            <span className="inline-flex items-center px-2 py-0.5 rounded-(--radius-md) text-(length:--text-xs) font-semibold bg-(--accent-amber-glow) text-(--accent-amber)">
              PLAYBACK UNAVAILABLE
            </span>
          )}
          <Icon
            name="expand"
            className={`shrink-0 w-4 h-4 text-(--muted-foreground) transition-transform ${isExpanded ? "rotate-180" : ""}`}
          />
        </div>
      </button>

      {/* ── Expanded detail panel ── */}
      {isExpanded && (
        <div className="px-6 pb-4 pt-1 bg-(--muted-foreground)/10 border-t border-(--border-subtle)">
          {/* Missing form alert */}
          {missingForm && (
            <div className="flex items-center gap-2 mb-4 px-4 py-2 rounded-(--radius-lg) bg-(--accent-red-glow) border border-(--accent-red)/25">
              <span className="text-(length:--text-base)"><Icon name="alert" /></span>
              <div className="text-(length:--text-xs)">
                <span className="font-semibold text-(--accent-red)">NO CONTEXT FORM</span>
                <span className="text-(--muted-foreground)"> Slug and description are missing for this asset.</span>
              </div>
            </div>
          )}

          {/* Form response (slug, description, type, priority) */}
          {asset.formResponse && <FormSection form={asset.formResponse} />}

          {/* Clip details (resolution, codec, orientation, file size, duration) */}
          {clip && <ClipSection clip={clip} />}

          {asset.moderationReason && (
            <p className="mb-3 text-(length:--text-xs) text-(--muted-foreground)">
              Moderation note: {asset.moderationReason}
            </p>
          )}
          {viewerRole !== "USER" && <MediaSyncDetails assetId={asset.id} media={asset} canConfirm={isSuperAdmin} />}

          {onModerate && viewerRole && (
            <div className="flex flex-wrap gap-2 py-2">
              {asset.moderation === "ACTIVE" && (
                <>
                  {(asset.mediaSyncState === "ERROR" || asset.mediaPlaybackReset) && (
                    <ModerationButton label="Retry media reconciliation" onClick={() => void changeModeration("ACTIVE")} />
                  )}
                  <ModerationButton label="Pause playback" onClick={() => void changeModeration("PAUSED")} />
                  <ModerationButton label="Flag for removal" onClick={() => void changeModeration("FLAGGED_FOR_REMOVAL")} />
                </>
              )}
              {asset.moderation === "PAUSED" && (
                <>
                  <ModerationButton
                    label="Retry playback revocation"
                    onClick={() => void changeModeration("PAUSED")}
                  />
                  <ModerationButton label="Unpause" onClick={() => void changeModeration("ACTIVE")} />
                  <ModerationButton label="Flag for removal" onClick={() => void changeModeration("FLAGGED_FOR_REMOVAL")} />
                </>
              )}
              {asset.moderation === "FLAGGED_FOR_REMOVAL" && isSuperAdmin && (
                <>
                  <ModerationButton
                    label="Retry playback revocation"
                    onClick={() => void changeModeration("FLAGGED_FOR_REMOVAL")}
                  />
                  <ModerationButton label="Restore asset" onClick={() => void changeModeration("ACTIVE")} />
                  <ModerationButton
                    label="Remove permanently"
                    destructive
                    onClick={() => void changeModeration("REMOVED")}
                  />
                </>
              )}
            </div>
          )}

          {/* Footer: timestamp + clip viewer link */}
          <div className="flex items-center justify-between mt-2 pt-2 border-t border-(--border-subtle)">
            <span className="text-(length:--text-xs) text-(--muted-foreground)">
              {asset.createdAt ? new Date(asset.createdAt).toLocaleString() : ""}
            </span>
            {canPlay ? (
              <a
                href={clipUrl ?? undefined}
                target="_blank"
                rel="noopener noreferrer"
                className="text-(length:--text-xs) font-semibold text-(--accent-blue) hover:underline no-underline inline-flex items-center gap-1"
              >
                Play Clip <Icon name="arrowUpRight" />
              </a>
            ) : (
              <span className="text-(length:--text-xs) text-(--muted-foreground)">
                {asset.moderation !== "ACTIVE"
                  ? `Playback disabled while ${asset.moderation.toLowerCase().replace(/_/g, " ")}`
                  : !clipUrl
                    ? "Clip link is not available yet"
                    : viewerRole === "USER"
                      ? "Playback is temporarily unavailable"
                      : "Playback unavailable while media reconciliation is in progress"}
              </span>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function ModerationButton({
  label,
  onClick,
  destructive = false,
}: {
  label: string;
  onClick: () => void;
  destructive?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`px-3 py-1.5 rounded-(--radius-lg) text-(length:--text-xs) font-semibold border ${
        destructive
          ? "border-(--accent-red)/40 text-(--accent-red) hover:bg-(--accent-red-glow)"
          : "border-(--border-subtle) text-(--foreground) hover:border-(--accent-blue)/50"
      }`}
    >
      {label}
    </button>
  );
}

// ─── Expanded Panel Sections ─────────────────────────────────────────

/** Form Response — user-submitted metadata from ContextFormView in iOS */
function FormSection({ form }: { form: NonNullable<Asset["formResponse"]> }) {
  return (
    <div className="mb-3">
      <h4 className="text-(length:--text-xs) font-semibold text-(--muted-foreground) uppercase tracking-wider mb-2">Form Response</h4>
      <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-(length:--text-xs)">
        {form.description && (
          <div className="col-span-2 max-w-[65ch]">
            <DetailRow label="Description" value={form.description} />
          </div>
        )}
        {form.type && <DetailRow label="Type" value={form.type} />}
        {form.priority && (
          <DetailRow label="Priority" value={form.priority} className={priorityColors[form.priority] ?? ""} />
        )}
      </div>
    </div>
  );
}

/** Clip Details — technical metadata from Mux about the video file */
function ClipSection({ clip }: { clip: NonNullable<Asset["clips"]>[number] }) {
  return (
    <div className="mb-3">
      <h4 className="text-(length:--text-xs) font-semibold text-(--muted-foreground) uppercase tracking-wider mb-2">Clip Details</h4>
      <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-(length:--text-xs)">
        {clip.resolution && <DetailRow label="Resolution" value={clip.resolution} />}
        {clip.codec && <DetailRow label="Codec" value={clip.codec} />}
        {clip.orientation && <DetailRow label="Orientation" value={clip.orientation} />}
        {clip.fileSize && <DetailRow label="File Size" value={`${(Number(clip.fileSize) / 1_000_000).toFixed(1)} MB`} />}
        {clip.duration != null && <DetailRow label="Duration" value={formatDuration(clip.duration)} />}
      </div>
    </div>
  );
}

// ─── Shared Helper Components ────────────────────────────────────────

/** A single "Label: Value" row used in FormSection and ClipSection */
function DetailRow({ label, value, className = "" }: { label: string; value: string; className?: string }) {
  return (
    <div className="flex gap-2">
      <span className="text-(--muted-foreground) shrink-0">{label}:</span>
      <span className={`font-medium truncate ${className}`}>{value}</span>
    </div>
  );
}

/** Placeholder shown when the list is loading or has no items */
function Empty({ icon, text }: { icon: IconName; text: string }) {
  return (
    <div className="py-10 px-6 text-center text-(--muted-foreground) text-(length:--text-sm)">
      <div className="text-(length:--text-3xl) mb-2 opacity-50 flex justify-center"><Icon name={icon} /></div>
      {text}
    </div>
  );
}
