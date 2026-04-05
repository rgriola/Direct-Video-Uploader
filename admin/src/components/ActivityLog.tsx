import type { LogEntry } from "@/lib/types";
import {panelHeader} from "@/lib/types";

const typeClasses: Record<string, string> = {
  ws: "bg-(--accent-purple-glow) text-(--accent-purple)",
  http: "bg-(--accent-blue-glow) text-(--accent-blue)",
  auth: "bg-(--accent-green-glow) text-(--accent-green)",
  error: "bg-(--accent-red-glow) text-(--accent-red)",
  triad: "bg-(--accent-amber-glow) text-(--accent-amber)",
};

interface ActivityLogProps {
  logs: LogEntry[];
  onClear: () => void;
}

export function ActivityLog({ logs, onClear }: ActivityLogProps) {
  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) overflow-hidden">

      <div className={panelHeader}>

        <h2 className="text-lg font-semibold flex items-center gap-2">📡 Activity Log</h2>
        <button
          onClick={onClear}
          className="px-2 py-1 rounded-lg text-[11px] font-medium bg-(--card) border border-(--border) text-(--muted-foreground) hover:bg-(--card-hover) hover:text-(--foreground) transition-all cursor-pointer"
        >
          Clear
        </button>
      </div>

      <div className="max-h-75 overflow-y-auto scrollbar-hide px-6 py-4 font-mono text-xs leading-[1.8]">
        {logs.length === 0 ? (
          <div className="py-10 text-center text-(--muted-foreground) text-sm font-sans">
            <div className="text-[32px] mb-2 opacity-50">📡</div>
            Waiting for activity...
          </div>
        ) : (
          logs.map((log) => (
            <div key={log.id} className="flex items-start gap-2 py-1 animate-fade-in">
              <span className="text-(--muted-foreground) shrink-0 text-[11px]">{log.time}</span>
              <span
                className={`text-[11px] font-bold shrink-0 px-1.5 py-px rounded ${typeClasses[log.type] ?? ""}`}
              >
                {log.type.toUpperCase()}
              </span>
              <span className="text-(--muted-foreground)">{log.msg}</span>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
