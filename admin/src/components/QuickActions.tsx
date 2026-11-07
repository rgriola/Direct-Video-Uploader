import type { LogEntry } from "@/lib/types";
import { panelHeader, subTextPanelHeader } from "@/lib/types";
import { Icon, type IconName } from "./Icon";

interface QuickActionsProps {
  onAction: (action: string) => void;
  addLog: (type: LogEntry["type"], msg: string) => void;
}

const buttons: { key: string; icon: IconName; label: string; sub: string }[] = [
  { key: "health", icon: "health", label: "Health Check", sub: "GET /api/health" },
  { key: "me", icon: "user", label: "My Profile", sub: "GET /api/auth/me" },
  { key: "messages", icon: "messages", label: "Chat History", sub: "GET /api/messages" },
  { key: "cleanup", icon: "cleanup", label: "Cleanup Assets", sub: "Stale UPLOADING" },
];

export function QuickActions({ onAction }: QuickActionsProps) {
  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius-xl) overflow-hidden mb-8">

      <div className={panelHeader}>

        <h2 className="text-(length:--text-lg) font-semibold flex items-center gap-2"><Icon name="api" /> Quick Actions</h2>
        <span className={subTextPanelHeader}>
          Test the API
        </span>
      </div>

      <div className="grid grid-cols-4 gap-4 px-6 py-4 max-[900px]:grid-cols-2 max-[600px]:grid-cols-1">
        {buttons.map((btn) => (
          <button
            key={btn.key}
            onClick={() => onAction(btn.key)}
            className="flex flex-col items-center gap-1 px-4 py-4 rounded-(--radius-lg) text-(length:--text-sm) font-medium bg-(--secondary) border border-(--border) text-(--secondary-foreground) hover:bg-(--secondary-dark-shade) hover:border-(--accent-blue) hover:-translate-y-px transition-all cursor-pointer"
          >
            <span className="text-(length:--text-xl)"><Icon name={btn.icon} /></span>
            {btn.label}
            <span className="text-(length:--text-xs) text-(--secondary-foreground)">{btn.sub}</span>
          </button>
        ))}
      </div>
    </div>
  );
}
