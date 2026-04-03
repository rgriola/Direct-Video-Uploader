import { useState } from "react";
import { ChevronDown } from "lucide-react";
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
  const [expanded, setExpanded] = useState<Set<string>>(new Set());

  const sorted = [...(users ?? [])].sort((a, b) => {
    if (a.isOnline !== b.isOnline) return a.isOnline ? -1 : 1;
    const aTime = a.lastLoginAt ? new Date(a.lastLoginAt).getTime() : 0;
    const bTime = b.lastLoginAt ? new Date(b.lastLoginAt).getTime() : 0;
    return bTime - aTime;
  });

  function toggle(id: string) {
    setExpanded((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  }

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
        ) : !sorted.length ? (
          <Empty icon="👥" text="No users registered yet." />
        ) : (
          sorted.map((user, i) => {
            const color = avatarColors[i % avatarColors.length]!;
            const s = avatarStyle(color);
            const initials = user.name.split(" ").map((w) => w[0]).join("");
            const isOpen = expanded.has(user.id);

            return (
              <div key={user.id} className="border-b border-(--border-subtle) last:border-b-0">
                {/* Summary row — always visible */}
                <button
                  onClick={() => toggle(user.id)}
                  className="w-full flex items-center gap-3 px-4 py-3 hover:bg-(--card-hover) transition-colors text-left"
                >
                  {/* Avatar */}
                  <div className="relative shrink-0">
                    <div
                      className="w-9 h-9 rounded-[10px] flex items-center justify-center font-bold text-sm"
                      style={{ background: s.bg, color: s.text, border: `1px solid ${s.border}` }}
                    >
                      {initials}
                    </div>
                    {user.isOnline && (
                      <span className="absolute -top-0.5 -right-0.5 w-2.5 h-2.5 rounded-full bg-(--accent-green) border-2 border-(--card)" />
                    )}
                  </div>

                  {/* Name */}
                  <span className="flex-1 min-w-0 text-sm font-semibold truncate">
                    {user.name}
                  </span>

                  {/* Team pill */}
                  <span className="hidden sm:inline-flex shrink-0 items-center px-2 py-0.5 rounded-md text-[11px] font-semibold bg-(--secondary) text-(--muted-foreground)">
                    {user.team ?? "—"}
                  </span>

                  {/* Status pill */}
                  {user.isOnline ? (
                    <span className="shrink-0 inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[11px] font-semibold bg-(--accent-green-glow) text-(--accent-green)">
                      <span className="w-1.5 h-1.5 rounded-full bg-(--accent-green) animate-pulse-dot" />
                      ONLINE
                    </span>
                  ) : user.lastLoginAt ? (
                    <span className="shrink-0 inline-flex items-center px-2 py-0.5 rounded-md text-[11px] font-semibold bg-(--secondary) text-(--muted-foreground)">
                      OFFLINE
                    </span>
                  ) : (
                    <span className="shrink-0 inline-flex items-center px-2 py-0.5 rounded-md text-[11px] font-semibold bg-(--secondary) text-(--muted-foreground) opacity-50">
                      NEVER SEEN
                    </span>
                  )}

                  {/* Chevron */}
                  <ChevronDown
                    className={`shrink-0 w-4 h-4 text-(--muted-foreground) transition-transform ${isOpen ? "rotate-180" : ""}`}
                  />
                </button>

                {/* Expanded detail */}
                {isOpen && (
                  <div className="px-4 pb-3 pt-1 border-t border-(--border-subtle) bg-(--card-hover) text-xs text-(--muted-foreground) space-y-1.5">
                    <div className="flex items-center gap-2">
                      <span className="w-20 shrink-0 font-medium text-(--foreground)/60">Phone</span>
                      <span>📱 {user.phoneNumber}</span>
                    </div>
                    <div className="flex items-center gap-2">
                      <span className="w-20 shrink-0 font-medium text-(--foreground)/60">Assets</span>
                      <span>{user.assetCount ?? 0} asset{user.assetCount !== 1 ? "s" : ""}</span>
                    </div>
                    <div className="flex items-center gap-2">
                      <span className="w-20 shrink-0 font-medium text-(--foreground)/60">Last login</span>
                      <span>{user.lastLoginAt ? formatLoginAge(user.lastLoginAt) : "Never logged in"}</span>
                    </div>
                    {/* Team — shown here on mobile since pill is hidden on sm */}
                    <div className="flex items-center gap-2 sm:hidden">
                      <span className="w-20 shrink-0 font-medium text-(--foreground)/60">Team</span>
                      <span>{user.team ?? "—"}</span>
                    </div>
                    {user.hasIosConnection && (
                      <div className="flex items-center gap-2">
                        <span className="w-20 shrink-0 font-medium text-(--foreground)/60">iOS</span>
                        <span className="text-[11px] bg-(--accent-blue-glow) text-(--accent-blue) px-1.5 py-px rounded font-semibold">
                          Connected
                        </span>
                      </div>
                    )}
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

function Empty({ icon, text }: { icon: string; text: string }) {
  return (
    <div className="py-10 px-6 text-center text-(--muted-foreground) text-sm">
      <div className="text-[32px] mb-2 opacity-50">{icon}</div>
      {text}
    </div>
  );
}
