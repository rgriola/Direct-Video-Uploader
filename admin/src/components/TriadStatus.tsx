import { cn } from "@/lib/utils";
import type { TriadStatus as TriadStatusType } from "@/lib/types";
import { panelHeader } from "@/lib/types";
import { subTextPanelHeader } from "@/lib/types";

interface TriadStatusProps {
  triad?: TriadStatusType;
  isLoading: boolean;
  wsConnected?: boolean;
  iosClients?: number;
}

const serviceConfig = [
  {
    key: "database" as const,
    label: "Database",
    icon: "🗄️",
    desc: "PostgreSQL",
  },
  {
    key: "server" as const,
    label: "Server",
    icon: "⚡",
    desc: "Fastify :3000",
  },
  { key: "ios" as const, label: "iOS App", icon: "📱", desc: "Mobile Client" },
  { key: "admin" as const, label: "Dashboard", icon: "📊", desc: "This Page" },
];

function statusDot(status: string) {
  switch (status) {
    case "ok":
    case "connected":
      return "bg-(--accent-green) shadow-[0_0_6px_var(--accent-green)]";
    case "error":
      return "bg-(--accent-red) shadow-[0_0_6px_var(--accent-red)]";
    default:
      return "bg-(--muted-foreground)";
  }
}

function statusLabel(status: string) {
  switch (status) {
    case "ok":
      return "Running";
    case "connected":
      return "Connected";
    case "error":
      return "Error";
    case "disconnected":
      return "Waiting";
    default:
      return "Unknown";
  }
}

function statusTextColor(status: string) {
  switch (status) {
    case "ok":
    case "connected":
      return "text-(--accent-green)";
    case "error":
      return "text-(--accent-red)";
    default:
      return "text-(--muted-foreground)";
  }
}

export function TriadStatusPanel({
  triad,
  isLoading,
  wsConnected = false,
  iosClients = 0,
}: TriadStatusProps) {
  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) overflow-hidden mb-8">
      <div className={panelHeader}>
        <h2 className="text-lg font-semibold text-(--foreground) flex items-center gap-2">
          🔺 Triad Status
        </h2>
        <div className="flex items-center gap-3">
          {/* iOS client indicator */}
          <div className="flex items-center gap-1 text-xs text-(--foreground)">
            <span>📱</span>
            <span>
              {iosClients > 0 ? `${iosClients} iOS User` : "No iOS User"}
            </span>
          </div>

          {/* WebSocket status badge */}
          <span
            className={cn(
              "inline-flex items-center gap-1 px-3 py-0.5 rounded-full text-xs font-semibold tracking-wide border",
              wsConnected
                ? "bg-(--accent-green-glow) text-(--accent-green) border-[rgba(52,211,153,0.2)]"
                : "bg-(--secondary) text-(--muted-foreground) border-(--border)",
            )}
          >
            <span
              className={cn(
                "w-1.5 h-1.5 rounded-full",
                wsConnected
                  ? "bg-(--accent-green) animate-pulse-dot"
                  : "bg-(--muted-foreground)",
              )}
            />
            {wsConnected ? "LIVE" : "CONNECTING"}
          </span>
        </div>
      </div>

      <div className="grid grid-cols-4 gap-0 max-[900px]:grid-cols-2 max-[600px]:grid-cols-1">
        {serviceConfig.map((svc) => {
          const data = triad?.triad?.[svc.key];
          const status = data?.status ?? "unknown";
          const message = data?.message;
          const clients = data?.clients;

          return (
            <div
              key={svc.key}
              className="flex items-center gap-3 px-5 py-4 border-r border-(--border-subtle) last:border-r-0 max-[900px]:border-b max-[900px]:border-r-0"
            >
              <div className="text-2xl">{svc.icon}</div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <span
                    className={`w-2 h-2 rounded-full shrink-0 ${isLoading ? "bg-(--muted-foreground)" : statusDot(status)}`}
                  />
                  <span className="text-sm font-semibold">{svc.label}</span>

                  <span
                    className={`text-[11px] font-semibold ${isLoading ? "text-(--muted-foreground)" : statusTextColor(status)}`}
                  >
                    {isLoading ? "..." : statusLabel(status)}
                  </span>
                </div>
                <p className="text-[11px] text-(--muted-foreground) mt-0.5 truncate">
                  {isLoading
                    ? svc.desc
                    : message
                      ? message
                      : clients !== undefined
                        ? `${clients} connection${clients !== 1 ? "s" : ""}`
                        : svc.desc}
                </p>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
