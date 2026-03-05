import type { Endpoint } from "@/lib/types";

const methodClasses: Record<string, string> = {
  GET: "text-(--accent-green)",
  POST: "text-(--accent-blue)",
  WS: "text-(--accent-purple)",
};

const endpoints: Endpoint[] = [
  { method: "GET", path: "/api/health", description: "Server health check" },
  { method: "GET", path: "/api/admin/status", description: "Triad status (DB, server, iOS, WS)" },
  { method: "GET", path: "/api/admin/stats", description: "Live dashboard stats" },
  { method: "GET", path: "/api/admin/users", description: "Users with online status" },
  { method: "GET", path: "/api/admin/assets", description: "Assets with clips" },
  { method: "POST", path: "/api/auth/login", description: "Login (phone + PIN)" },
  { method: "GET", path: "/api/auth/me", description: "Current user profile" },
  { method: "POST", path: "/api/assets", description: "Create new asset" },
  { method: "POST", path: "/api/assets/:id/upload", description: "Upload video file" },
  { method: "POST", path: "/api/assets/:id/form", description: "Submit context form" },
  { method: "WS", path: "/socket.io/", description: "Real-time WebSocket" },
];

export function EndpointTable() {
  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) overflow-hidden">
      <div className="flex items-center justify-between px-5.5 py-4.5 border-b border-(--border-subtle)">
        <span className="text-[15px] font-semibold flex items-center gap-2">🗺️ API Endpoints</span>
        <span className="text-[11px] bg-(--secondary) text-(--muted-foreground) px-2 py-0.5 rounded-[10px] font-semibold">
          {endpoints.length} routes
        </span>
      </div>

      <div className="overflow-x-auto">
        <div className="grid grid-cols-[80px_1fr_1fr] max-[600px]:grid-cols-[60px_1fr] text-[13px] min-w-0">
          {endpoints.map((ep) => (
            <div key={ep.path} className="contents group">
              <div className="px-5.5 max-[600px]:px-3 py-2.75 border-b border-(--border-subtle) flex items-center group-last:border-b-0 group-hover:bg-(--card-hover)">
                <span className={`font-bold text-[11px] tracking-wide ${methodClasses[ep.method] ?? ""}`}>
                  {ep.method}
                </span>
              </div>
              <div className="px-5.5 max-[600px]:px-3 py-2.75 border-b border-(--border-subtle) flex items-center font-mono text-[12.5px] text-(--foreground) group-last:border-b-0 group-hover:bg-(--card-hover) truncate">
                {ep.path}
              </div>
              <div className="px-5.5 py-2.75 border-b border-(--border-subtle) flex items-center text-[12.5px] text-(--muted-foreground) group-last:border-b-0 group-hover:bg-(--card-hover) max-[600px]:hidden">
                {ep.description}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
