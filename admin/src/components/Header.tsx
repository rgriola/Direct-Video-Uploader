import { RefreshCw, LogOut } from "lucide-react";
import { cn } from "@/lib/utils";

interface HeaderProps {
  wsConnected: boolean;
  onRefresh: () => void;
  onLogout: () => void;
  refreshing: boolean;
  iosClients?: number;
}

export function Header({ wsConnected, onRefresh, onLogout, refreshing, iosClients = 0 }: HeaderProps) {
  return (
    <header className="flex flex-wrap items-center justify-between gap-4 mb-8 pb-6 border-b border-(--border-subtle)">
      <div className="flex items-center gap-4 min-w-0">
        <div className="w-12 h-12 shrink-0 rounded-xl bg-linear-to-br from-(--accent-blue) to-(--accent-purple) flex items-center justify-center text-2xl shadow-[0_4px_16px_rgba(74,158,255,0.25)]">
          🎬
        </div>
        <div className="min-w-0">
          <h1 className="text-2xl max-[480px]:text-xl font-bold tracking-tight truncate">Fixer</h1>
          <p className="text-xs text-(--muted-foreground) mt-0.5">Server Dashboard · Live Data</p>
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-3">
        {/* iOS client indicator */}
        <div className="flex items-center gap-1 text-xs text-(--muted-foreground)">
          <span>📱</span>
          <span>{iosClients > 0 ? `${iosClients} iOS` : "No iOS"}</span>
        </div>

        {/* WS indicator */}
        <div className="flex items-center gap-1 text-xs text-(--muted-foreground)">
          <span
            className={cn(
              "w-2 h-2 rounded-full transition-all",
              wsConnected
                ? "bg-(--accent-green) shadow-[0_0_8px_var(--accent-green)]"
                : "bg-(--muted-foreground)",
            )}
          />
          <span className="hidden sm:inline">{wsConnected ? "WS Connected" : "WS Disconnected"}</span>
        </div>

        {/* Server status badge */}
        <span
          className={cn(
            "inline-flex items-center gap-1 px-4 py-1 rounded-full text-xs font-semibold tracking-wide border",
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
          className="flex items-center gap-1 px-4 py-2 rounded-lg text-sm font-medium bg-(--card) border border-(--border) text-(--muted-foreground) hover:bg-(--card-hover) hover:text-(--foreground) hover:border-(--accent-blue) transition-all cursor-pointer"
        >
          <RefreshCw className={cn("w-3.5 h-3.5", refreshing && "animate-spin-once")} />
          Refresh
        </button>

        {/* Logout button */}
        <button
          onClick={onLogout}
          className="flex items-center gap-1 px-4 py-2 rounded-lg text-sm font-medium bg-(--card) border border-(--border) text-(--muted-foreground) hover:bg-(--card-hover) hover:text-(--accent-red) hover:border-(--accent-red)/50 transition-all cursor-pointer"
        >
          <LogOut className="w-3.5 h-3.5" />
          Logout
        </button>
      </div>
    </header>
  );
}
