import type { User } from "@/lib/types";

const avatarColors = ["blue", "green", "purple"] as const;

function avatarStyle(color: string) {
  const map: Record<string, { bg: string; text: string; border: string }> = {
    blue: { bg: "var(--accent-blue-glow)", text: "var(--accent-blue)", border: "rgba(74,158,255,0.2)" },
    green: { bg: "var(--accent-green-glow)", text: "var(--accent-green)", border: "rgba(52,211,153,0.2)" },
    purple: { bg: "var(--accent-purple-glow)", text: "var(--accent-purple)", border: "rgba(167,139,250,0.2)" },
  };
  return map[color] ?? map.blue!;
}

function formatLoginAge(dateStr: string): string {
  const diff = Date.now() - new Date(dateStr).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "Just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  return `${days}d ago`;
}

interface UserListProps {
  users?: User[];
  isLoading: boolean;
}

export function UserList({ users, isLoading }: UserListProps) {
  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) overflow-hidden">
      <div className="flex items-center justify-between px-6 py-4 border-b border-(--border-subtle)">
        <h2 className="text-lg font-semibold flex items-center gap-2">
          👥 Users{" "}
          <span className="text-[11px] bg-(--secondary) text-(--muted-foreground) px-2 py-0.5 rounded-[10px] font-semibold">
            {users?.length ?? 0}
          </span>
        </h2>
      </div>

      <div>
        {isLoading ? (
          <Empty icon="👥" text="Loading users..." />
        ) : !users?.length ? (
          <Empty icon="👥" text="No users registered yet." />
        ) : (
          users.map((user, i) => {
            const color = avatarColors[i % avatarColors.length]!;
            const s = avatarStyle(color);
            const initials = user.name
              .split(" ")
              .map((w) => w[0])
              .join("");

            return (
              <div
                key={user.id}
                className="flex items-center px-6 py-4 border-b border-(--border-subtle) last:border-b-0 hover:bg-(--card-hover) transition-colors"
              >
                {/* Avatar with online indicator */}
                <div className="relative mr-3.5 shrink-0">
                  <div
                    className="w-9.5 h-9.5 rounded-[10px] flex items-center justify-center font-bold text-sm"
                    style={{ background: s.bg, color: s.text, border: `1px solid ${s.border}` }}
                  >
                    {initials}
                  </div>
                  {user.isOnline && (
                    <span className="absolute -top-0.5 -right-0.5 w-3 h-3 rounded-full bg-(--accent-green) border-2 border-(--card) shadow-[0_0_6px_var(--accent-green)]" />
                  )}
                </div>

                <div className="flex-1 min-w-0">
                  <p className="text-sm font-semibold truncate flex items-center gap-2">
                    {user.name}
                    {user.hasIosConnection && (
                      <span className="text-[11px] bg-(--accent-blue-glow) text-(--accent-blue) px-1.5 py-px rounded font-semibold">
                        iOS
                      </span>
                    )}
                  </p>
                  <p className="text-xs text-(--muted-foreground) mt-0.5 flex items-center gap-2">
                    <span>📱 {user.phoneNumber}</span>
                    <span>·</span>
                    <span>{user.assetCount ?? 0} asset{user.assetCount !== 1 ? "s" : ""}</span>
                    <span>·</span>
                    <span>
                      {user.lastLoginAt
                        ? `Last login: ${formatLoginAge(user.lastLoginAt)}`
                        : "Never logged in"}
                    </span>
                  </p>
                </div>

                <div className="flex items-center gap-2.5 shrink-0">
                  <span className="inline-flex items-center px-2 py-0.5 rounded-md text-[11px] font-semibold tracking-wide bg-(--secondary) text-(--muted-foreground)">
                    {user.team ?? "—"}
                  </span>
                  {user.isOnline ? (
                    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[11px] font-semibold tracking-wide bg-(--accent-green-glow) text-(--accent-green)">
                      <span className="w-1.5 h-1.5 rounded-full bg-(--accent-green) animate-pulse-dot" />
                      ONLINE
                    </span>
                  ) : user.lastLoginAt ? (
                    <span className="inline-flex items-center px-2 py-0.5 rounded-md text-[11px] font-semibold tracking-wide bg-(--secondary) text-(--muted-foreground)">
                      OFFLINE
                    </span>
                  ) : (
                    <span className="inline-flex items-center px-2 py-0.5 rounded-md text-[11px] font-semibold tracking-wide bg-(--secondary) text-(--muted-foreground) opacity-50">
                      NEVER SEEN
                    </span>
                  )}
                </div>
              </div>
            );
          })
        )}
      </div>
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
