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

interface AssetListProps {
  assets?: Asset[];
  isLoading: boolean;
}

export function AssetList({ assets, isLoading }: AssetListProps) {
  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) overflow-hidden">
      <div className="flex items-center justify-between px-5.5 py-4.5 border-b border-(--border-subtle)">
        <span className="text-[15px] font-semibold flex items-center gap-2">
          📦 Assets{" "}
          <span className="text-[11px] bg-(--secondary) text-(--muted-foreground) px-2 py-0.5 rounded-[10px] font-semibold">
            {assets?.length ?? 0}
          </span>
        </span>
      </div>

      <div className="max-h-75 overflow-y-auto scrollbar-hide">
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

            const clipUrl = `/clips/${asset.slug}`;

            return (
              <a
                key={asset.id}
                href={clipUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center px-5.5 py-3.5 border-b border-(--border-subtle) last:border-b-0 hover:bg-(--card-hover) transition-colors no-underline text-inherit cursor-pointer"
              >
                <div className="w-10.5 h-10.5 rounded-[10px] bg-(--secondary) flex items-center justify-center text-lg mr-3.5 shrink-0">
                  {statusIcons[asset.status] ?? "📦"}
                </div>

                <div className="flex-1 min-w-0">
                  <p className="text-sm font-semibold truncate">{asset.slug}</p>
                  <p className="text-xs text-(--muted-foreground) mt-0.5 flex items-center gap-2">
                    {details}
                  </p>
                </div>

                <div className="shrink-0 flex items-center gap-2">
                  <span
                    className={`inline-flex items-center gap-1.25 px-2.5 py-0.5 rounded-md text-[11px] font-semibold ${statusClasses[asset.status] ?? ""}`}
                  >
                    {asset.status}
                  </span>
                  <span className="text-(--muted-foreground) text-xs opacity-50">▸</span>
                </div>
              </a>
            );
          })
        )}
      </div>
    </div>
  );
}

function Empty({ icon, text }: { icon: string; text: string }) {
  return (
    <div className="py-10 px-5.5 text-center text-(--muted-foreground) text-[13px]">
      <div className="text-[32px] mb-2.5 opacity-50">{icon}</div>
      {text}
    </div>
  );
}
