import type { LogEntry } from "@/lib/types";

interface QuickActionsProps {
  onAction: (action: string) => void;
  addLog: (type: LogEntry["type"], msg: string) => void;
}

const buttons = [
  { key: "health", icon: "💚", label: "Health Check", sub: "GET /api/health" },
  { key: "me", icon: "👤", label: "My Profile", sub: "GET /api/auth/me" },
  { key: "messages", icon: "💬", label: "Chat History", sub: "GET /api/messages" },
  { key: "cleanup", icon: "🧹", label: "Cleanup Assets", sub: "Stale UPLOADING" },
];

export function QuickActions({ onAction }: QuickActionsProps) {
  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) overflow-hidden mb-8">
      <div className="flex items-center justify-between px-5.5 py-4.5 border-b border-(--border-subtle)">
        <span className="text-[15px] font-semibold flex items-center gap-2">⚡ Quick Actions</span>
        <span className="text-[11px] bg-(--secondary) text-(--muted-foreground) px-2 py-0.5 rounded-[10px] font-semibold">
          Test the API
        </span>
      </div>

      <div className="grid grid-cols-4 gap-3 px-5.5 py-4.5 max-[900px]:grid-cols-2 max-[600px]:grid-cols-1">
        {buttons.map((btn) => (
          <button
            key={btn.key}
            onClick={() => onAction(btn.key)}
            className="flex flex-col items-center gap-1.5 px-4 py-3 rounded-lg text-[13px] font-medium bg-(--secondary) border border-(--border) text-(--foreground) hover:bg-(--card-hover) hover:border-(--accent-blue) hover:-translate-y-px transition-all cursor-pointer"
          >
            <span className="text-xl">{btn.icon}</span>
            {btn.label}
            <span className="text-[11px] text-(--muted-foreground)">{btn.sub}</span>
          </button>
        ))}
      </div>
    </div>
  );
}
