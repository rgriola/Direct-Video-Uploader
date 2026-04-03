import { useState } from "react";
import type { Asset } from "@/lib/types";

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

interface AssetListProps {
  assets?: Asset[];
  isLoading: boolean;
}

export function AssetList({ assets, isLoading }: AssetListProps) {
  const [expandedId, setExpandedId] = useState<string | null>(null);

  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) overflow-hidden">
      <div className="flex items-center justify-between px-6 py-4 border-b border-(--border-subtle)">
        <h2 className="text-lg font-semibold flex items-center gap-2">
          📦 Assets{" "}
          <span className="text-[11px] bg-(--secondary) text-(--muted-foreground) px-2 py-0.5 rounded-[10px] font-semibold">
            {assets?.length ?? 0}
          </span>
        </h2>
      </div>

      <div className="max-h-100 overflow-y-auto scrollbar-hide">
        {isLoading ? (
          <Empty icon="📦" text="Loading assets..." />
        ) : !assets?.length ? (
          <Empty icon="📦" text="No assets uploaded yet. Upload from the iOS app to see them here." />
        ) : (
          assets.map((asset) => {
            const clip = asset.clips?.[0];
            const dur = asset.totalDuration
              ? `${Math.floor(asset.totalDuration / 60)}:${String(asset.totalDuration % 60).padStart(2, "0")}`
              : "";

            const missingForm = !asset.formResponse && asset.status === "READY";

            const details = [
              asset.mediasourceId ? `#${asset.mediasourceId}` : null,
              asset.clipCount ? `${asset.clipCount} clip${asset.clipCount !== 1 ? "s" : ""}` : null,
              dur || null,
              clip?.resolution ?? null,
              `by ${asset.user?.name ?? "Unknown"}`,
              asset.formResponse ? "📋 Form" : null,
            ]
              .filter(Boolean)
              .join(" · ");

            const isExpanded = expandedId === asset.id;

            return (
              <div key={asset.id} className={`border-b border-(--border-subtle) last:border-b-0 ${missingForm ? "border-l-3 border-l-(--accent-red) bg-(--accent-red-glow)" : ""}`}>
                {/* Row header — click to expand/collapse */}
                <button
                  onClick={() => setExpandedId(isExpanded ? null : asset.id)}
                  className="flex items-center w-full px-6 py-4 hover:bg-(--card-hover) transition-colors cursor-pointer text-left bg-transparent border-0 text-inherit font-inherit"
                >
                  <div className="w-10.5 h-10.5 rounded-[10px] bg-(--secondary) flex items-center justify-center text-lg mr-3.5 shrink-0">
                    {statusIcons[asset.status] ?? "📦"}
                  </div>

                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-semibold truncate">{asset.mediasourceId || asset.id}</p>
                    <p className="text-xs text-(--muted-foreground) mt-0.5 flex items-center gap-2">
                      {details}
                    </p>
                  </div>

                  <div className="shrink-0 flex items-center gap-2">
                    {missingForm && (
                      <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[11px] font-semibold bg-(--accent-red-glow) text-(--accent-red)">
                        ⚠️ No Form
                      </span>
                    )}
                    <span
                      className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[11px] font-semibold ${statusClasses[asset.status] ?? ""}`}
                    >
                      {asset.status}
                    </span>
                    <span className={`text-(--muted-foreground) text-xs transition-transform ${isExpanded ? "rotate-90" : ""}`}>▸</span>
                  </div>
                </button>

                {/* Expanded detail panel */}
                {isExpanded && (
                  <div className="px-6 pb-4 pt-1 bg-(--secondary)/30 border-t border-(--border-subtle)">
                    {/* Missing form alert */}
                    {missingForm && (
                      <div className="flex items-center gap-2 mb-4 px-4 py-2 rounded-lg bg-(--accent-red-glow) border border-(--accent-red)/25">
                        <span className="text-base">🚨</span>
                        <div className="text-xs">
                          <span className="font-semibold text-(--accent-red)">NO CONTEXT FORM</span>
                          <span className="text-(--muted-foreground)"> Slug and description are missing for this asset.</span>
                        </div>
                      </div>
                    )}
                    {/* Clip details */}
                    {clip && (
                      <div className="mb-3">
                        <h4 className="text-[11px] font-semibold text-(--muted-foreground) uppercase tracking-wider mb-2">Clip Details</h4>
                        <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-xs">
                          {clip.resolution && <DetailRow label="Resolution" value={clip.resolution} />}
                          {clip.codec && <DetailRow label="Codec" value={clip.codec} />}
                          {clip.orientation && <DetailRow label="Orientation" value={clip.orientation} />}
                          {clip.fileSize && <DetailRow label="File Size" value={`${(Number(clip.fileSize) / 1_000_000).toFixed(1)} MB`} />}
                          {clip.duration != null && (
                            <DetailRow
                              label="Duration"
                              value={`${Math.floor(clip.duration / 60)}:${String(clip.duration % 60).padStart(2, "0")}`}
                            />
                          )}
                        </div>
                      </div>
                    )}

                    {/* Form response */}
                    {asset.formResponse && (
                      <div className="mb-3">
                        <h4 className="text-[11px] font-semibold text-(--muted-foreground) uppercase tracking-wider mb-2">Form Response</h4>
                        <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-xs">
                          {asset.formResponse.type && <DetailRow label="Type" value={asset.formResponse.type} />}
                          {asset.formResponse.priority && (
                            <DetailRow label="Priority" value={asset.formResponse.priority} className={priorityColors[asset.formResponse.priority] ?? ""} />
                          )}
                          {asset.formResponse.description && (
                            <div className="col-span-2 max-w-[65ch]">
                              <DetailRow label="Description" value={asset.formResponse.description} />
                            </div>
                          )}
                        </div>
                      </div>
                    )}

                    {/* Timestamps + link */}
                    <div className="flex items-center justify-between mt-2 pt-2 border-t border-(--border-subtle)">
                      <span className="text-[11px] text-(--muted-foreground)">
                        {asset.createdAt ? new Date(asset.createdAt).toLocaleString() : ""}
                      </span>
                      <a
                        href={asset.mediasourceUrl || `/clips/${asset.mediasourceId || asset.id}`}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-[11px] font-semibold text-(--accent-blue) hover:underline no-underline"
                      >
                        Open Clip Viewer ↗
                      </a>
                    </div>
                  </div>
                )}
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}

function DetailRow({ label, value, className = "" }: { label: string; value: string; className?: string }) {
  return (
    <div className="flex gap-2">
      <span className="text-(--muted-foreground) shrink-0">{label}:</span>
      <span className={`font-medium truncate ${className}`}>{value}</span>
    </div>
  );
}

function Empty({ icon, text }: { icon: string; text: string }) {
  return (
    <div className="py-10 px-6 text-center text-(--muted-foreground) text-sm">
      <div className="text-[32px] mb-2 opacity-50">{icon}</div>
      {text}
    </div>
  );
}
