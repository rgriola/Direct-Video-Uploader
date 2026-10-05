/**
 * AssetList.tsx — Admin Dashboard panel showing all uploaded video assets.
 *
 * DATA FLOW:
 *   1. App.tsx fetches assets from GET /api/admin/assets (via TanStack Query hook `useAssets`)
 *   2. App.tsx passes the array of Asset objects + loading state as props to this component
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
import { ChevronDown } from "lucide-react";
import type { Asset } from "@/lib/types";
import { panelHeader, subTextPanelHeader } from "@/lib/types";

// ─── Status Configuration ────────────────────────────────────────────
//
// Maps asset.status values to visual indicators used in AssetRow.
//   statusIcons   → emoji inside the colored circle
//   statusClasses → Tailwind classes for the status pill badge
//   priorityColors → text color for the priority field in form response

const statusIcons: Record<string, string> = {
  READY: "✅",
  PROCESSING: "⏳",
  UPLOADING: "📤",
  ERROR: "❌",
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
}

export function AssetList({ assets, isLoading }: AssetListProps) {
  /* Accordion: only one row expanded at a time. Stores asset.id or null. */
  const [expandedId, setExpandedId] = useState<string | null>(null);

  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius-xl) overflow-hidden">
      {/* Panel header — "📦 Assets [count]" */}
      <div className={panelHeader}>
        <h2 className="text-(--text-lg) font-semibold flex items-center gap-2">
          📦 Assets{" "}
          <span className={subTextPanelHeader}>
            {assets?.length ?? 0}
          </span>
        </h2>
      </div>

      {/* Scrollable list — max 400px, then scrolls */}
      <div className="max-h-100 overflow-y-auto scrollbar-hide">
        {isLoading ? (
          <Empty icon="📦" text="Loading assets..." />
        ) : !assets?.length ? (
          <Empty icon="📦" text="No Assets on the server. Uploaded Video will appear here." />
        ) : (
          assets.map((asset) => (
            <AssetRow
              key={asset.id}
              asset={asset}
              isExpanded={expandedId === asset.id}
              onToggle={() => setExpandedId(expandedId === asset.id ? null : asset.id)}
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
}

function AssetRow({ asset, isExpanded, onToggle }: AssetRowProps) {
  const clip = asset.clips?.[0];
  const missingForm = !asset.formResponse && asset.status === "READY";

  // Title: show slug if available, fall back to mediasource ID, then asset ID
  const title = asset.formResponse?.slug || asset.mediasourceId || asset.id;

  // One-line summary: "#100000017 · 1 clip · 2:05 · 1920x1080 · by Rod Griola · 📋 Form"
  const details = [
    asset.mediasourceId ? `#${asset.mediasourceId}` : null,
    asset.clipCount ? `${asset.clipCount} clip${asset.clipCount !== 1 ? "s" : ""}` : null,
    formatDuration(asset.totalDuration) || null,
    clip?.resolution ?? null,
    `by ${asset.user?.name ?? "Unknown"}`,
    asset.formResponse ? "📋 Form" : null,
  ]
    .filter(Boolean)
    .join(" · ");

  // Clip viewer URL: prefer mediasourceUrl, fall back to /clips/:id
  const clipUrl = asset.mediasourceUrl || `/clips/${asset.mediasourceId || asset.id}`;

  return (
    <div className={`border-b border-(--border-subtle) last:border-b-0 ${missingForm ? "border-l-3 border-l-(--accent-red) bg-(--accent-red-glow)" : ""}`}>

      {/* ── Collapsed row — always visible, click to toggle ── */}
      <button
        onClick={onToggle}
        aria-expanded={isExpanded}
        className="flex items-center w-full px-6 py-4 hover:bg-(--card-hover) transition-colors cursor-pointer text-left bg-transparent border-0 text-inherit font-inherit"
      >
        {/* Status icon circle */}
        <div className="w-10.5 h-10.5 rounded-(--radius-lg) bg-(--secondary) flex items-center justify-center text-(--text-base) mr-3.5 shrink-0">
          {statusIcons[asset.status] ?? "📦"}
        </div>

        {/* Title + detail line */}
        <div className="flex-1 min-w-0">
          <p className="text-(--text-sm) font-semibold truncate">{title}</p>
          <p className="text-(--text-xs) text-(--muted-foreground) mt-0.5 flex items-center gap-2">
            {details}
          </p>
        </div>

        {/* Right side: badges + chevron */}
        <div className="shrink-0 flex items-center gap-2">
          {missingForm && (
            <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-(--radius-md) text-(--text-xs) font-semibold bg-(--accent-red-glow) text-(--accent-red)">
              ⚠️ No Form
            </span>
          )}
          <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-(--radius-md) text-(--text-xs) font-semibold ${statusClasses[asset.status] ?? ""}`}>
            {asset.status}
          </span>
          <ChevronDown
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
              <span className="text-(--text-base)">🚨</span>
              <div className="text-(--text-xs)">
                <span className="font-semibold text-(--accent-red)">NO CONTEXT FORM</span>
                <span className="text-(--muted-foreground)"> Slug and description are missing for this asset.</span>
              </div>
            </div>
          )}

          {/* Form response (slug, description, type, priority) */}
          {asset.formResponse && <FormSection form={asset.formResponse} />}

          {/* Clip details (resolution, codec, orientation, file size, duration) */}
          {clip && <ClipSection clip={clip} />}

          {/* Footer: timestamp + clip viewer link */}
          <div className="flex items-center justify-between mt-2 pt-2 border-t border-(--border-subtle)">
            <span className="text-(--text-xs) text-(--muted-foreground)">
              {asset.createdAt ? new Date(asset.createdAt).toLocaleString() : ""}
            </span>
            <a
              href={clipUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="text-(--text-xs) font-semibold text-(--accent-blue) hover:underline no-underline"
            >
              Play Clip ↗
            </a>
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Expanded Panel Sections ─────────────────────────────────────────

/** Form Response — user-submitted metadata from ContextFormView in iOS */
function FormSection({ form }: { form: NonNullable<Asset["formResponse"]> }) {
  return (
    <div className="mb-3">
      <h4 className="text-(--text-xs) font-semibold text-(--muted-foreground) uppercase tracking-wider mb-2">Form Response</h4>
      <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-(--text-xs)">
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
      <h4 className="text-(--text-xs) font-semibold text-(--muted-foreground) uppercase tracking-wider mb-2">Clip Details</h4>
      <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-(--text-xs)">
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
function Empty({ icon, text }: { icon: string; text: string }) {
  return (
    <div className="py-10 px-6 text-center text-(--muted-foreground) text-(--text-sm)">
      <div className="text-(--text-3xl) mb-2 opacity-50">{icon}</div>
      {text}
    </div>
  );
}
