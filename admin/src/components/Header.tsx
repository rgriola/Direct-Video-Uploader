import { RefreshCw } from "lucide-react";
import { cn } from "@/lib/utils";

interface HeaderProps {
  wsConnected: boolean;
  onRefresh: () => void;
  refreshing: boolean;
  iosClients?: number;
}

export function Header({ wsConnected, onRefresh, refreshing, iosClients = 0 }: HeaderProps) {
  return (
    <header className="flex items-center justify-between mb-10 pb-6 border-b border-(--border-subtle)">
      <div className="flex items-center gap-4">
        <div className="w-12 h-12 rounded-xl bg-linear-to-br from-(--accent-blue) to-(--accent-purple) flex items-center justify-center text-2xl shadow-[0_4px_16px_rgba(74,158,255,0.25)]">
          🎬
        </div>
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Direct Video Uploader</h1>
          <p className="text-xs text-(--muted-foreground) mt-0.5">Server Dashboard · Live Data</p>
        </div>
      </div>

      <div className="flex items-center gap-3">
        {/* iOS client indicator */}
        <div className="flex items-center gap-1.5 text-xs text-(--muted-foreground)">
          <span>📱</span>
          <span>{iosClients > 0 ? `${iosClients} iOS` : "No iOS"}</span>
        </div>

        {/* WS indicator */}
        <div className="flex items-center gap-1.5 text-xs text-(--muted-foreground)">
          <span
            className={cn(
              "w-2 h-2 rounded-full transition-all",
              wsConnected
                ? "bg-(--accent-green) shadow-[0_0_8px_var(--accent-green)]"
                : "bg-(--muted-foreground)",
            )}
          />
          <span>{wsConnected ? "WS Connected" : "WS Disconnected"}</span>
        </div>

        {/* Server status badge */}
        <span
          className={cn(
            "inline-flex items-center gap-1.5 px-3.5 py-1.5 rounded-full text-xs font-semibold tracking-wide border",
            wsConnected
              ? "bg-(--accent-green-glow) text-(--accent-green) border-[rgba(52,211,153,0.2)]"
              : "bg-(--secondary) text-(--muted-foreground) border-(--border)",
          )}
        >
          <span
            className={cn(
              "w-1.75 h-1.75 rounded-full",
              wsConnected ? "bg-(--accent-green) animate-pulse-dot" : "bg-(--muted-foreground)",
            )}
          />
          {wsConnected ? "LIVE" : "CONNECTING"}
        </span>

        {/* Refresh button */}
        <button
          onClick={onRefresh}
          className="flex items-center gap-1.5 px-4 py-2 rounded-lg text-[13px] font-medium bg-(--card) border border-(--border) text-(--muted-foreground) hover:bg-(--card-hover) hover:text-(--foreground) hover:border-(--accent-blue) transition-all cursor-pointer"
        >
          <RefreshCw className={cn("w-3.5 h-3.5", refreshing && "animate-spin-once")} />
          Refresh
        </button>
      </div>
    </header>
  );
}
