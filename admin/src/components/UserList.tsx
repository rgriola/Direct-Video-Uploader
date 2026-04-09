/**
 * UserList.tsx — Admin Dashboard panel showing all registered users.
 *
 * DATA FLOW:
 *   1. App.tsx fetches users from GET /api/admin/users (via TanStack Query hook `useUsers`)
 *   2. App.tsx passes the array of User objects + loading state as props
 *   3. Users are sorted: online first, then by most recent login
 *   4. Each user renders as a clickable row (UserRow) with expand/collapse
 *
 * COMPONENT STRUCTURE:
 *   UserList           — Outer card with header + sorted list
 *     └─ UserRow       — One row per user (collapsed + expanded states)
 *          └─ UserDetails  — Phone, assets, last login, team, iOS connection
 *
 * NOTE: Unlike AssetList (single accordion), UserList allows MULTIPLE rows
 * to be expanded at once. It uses a Set<string> instead of a single ID.
 */

import { useState } from "react";
import { ChevronDown } from "lucide-react";
import type { User } from "@/lib/types";
import { panelHeader, subTextPanelHeader } from "@/lib/types";

// ─── Avatar Configuration ────────────────────────────────────────────
//
// Users cycle through blue → green → purple avatar colors based on
// their position in the sorted list. Each color maps to CSS variables
// for background, text, and border.

const avatarColors = ["blue", "green", "purple"] as const;

function avatarStyle(color: string) {
  const map: Record<string, { bg: string; text: string; border: string }> = {
    blue: { bg: "var(--accent-blue-glow)", text: "var(--accent-blue)", border: "var(--border-blue)" },
    green: { bg: "var(--accent-green-glow)", text: "var(--accent-green)", border: "var(--border-green)" },
    purple: { bg: "var(--accent-purple-glow)", text: "var(--accent-purple)", border: "var(--border-purple)" },
  };
  return map[color] ?? map.blue!;
}

// ─── Utilities ───────────────────────────────────────────────────────

/** Format a date string into a relative time label: "Just now", "5m ago", "3h ago", "2d ago" */
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

// Shared Tailwind class string for status pill badges (ONLINE / OFFLINE / NEVER SEEN)
const pillBase = "shrink-0 inline-flex items-center px-2 py-0.5 rounded-md text-[11px] font-semibold" as const;

// ─── Main Component ──────────────────────────────────────────────────

interface UserListProps {
  users?: User[];
  isLoading: boolean;
}

export function UserList({ users, isLoading }: UserListProps) {
  /* Multi-expand: multiple users can be open at once (Set of user IDs) */
  const [expanded, setExpanded] = useState<Set<string>>(new Set());

  /* Sort: online users first, then by most recent login */
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
      {/* Panel header — "👥 Users [count]" */}
      <div className={panelHeader}>
        <h2 className="text-lg font-semibold flex items-center gap-2">
          👥 Users{" "}
          <span className={subTextPanelHeader}>
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
          sorted.map((user, i) => (
            <UserRow
              key={user.id}
              user={user}
              color={avatarColors[i % avatarColors.length]!}
              isOpen={expanded.has(user.id)}
              onToggle={() => toggle(user.id)}
            />
          ))
        )}
      </div>
    </div>
  );
}

// ─── User Row ────────────────────────────────────────────────────────
//
// Each user renders as a clickable row with two states:
//   Collapsed: [avatar] [name] [team pill] [status pill] [chevron]
//   Expanded:  collapsed row + detail rows underneath

interface UserRowProps {
  user: User;
  color: string;        // Avatar color key: "blue" | "green" | "purple"
  isOpen: boolean;
  onToggle: () => void;
}

function UserRow({ user, color, isOpen, onToggle }: UserRowProps) {
  const s = avatarStyle(color);
  const initials = user.name.split(" ").map((w) => w[0]).join("");

  return (
    <div className="border-b border-(--border-subtle) last:border-b-0">
      {/* ── Collapsed row — always visible ── */}
      <button
        onClick={onToggle}
        className="w-full flex items-center gap-3 px-4 py-3 hover:bg-(--card-hover) transition-colors text-left"
      >
        {/* Avatar with initials + online dot */}
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
        <span className={`${pillBase} bg-(--base) text-(--secondary-foreground) border border(--border-subtle)`}>
          {user.team ?? "—"}
        </span>

        {/* Status pill: ONLINE / OFFLINE / NEVER SEEN */}
        <StatusPill user={user} />

        {/* Chevron — rotates when expanded */}
        <ChevronDown
          className={`shrink-0 w-4 h-4 text-(--muted-foreground) transition-transform ${isOpen ? "rotate-180" : ""}`}
        />
      </button>

      {/* ── Expanded detail panel ── */}
      {isOpen && <UserDetails user={user} />}
    </div>
  );
}

// ─── Status Pill ─────────────────────────────────────────────────────

/** Renders the ONLINE / OFFLINE / NEVER SEEN pill based on user state */
function StatusPill({ user }: { user: User }) {
  if (user.isOnline) {
    return (
      <span className={`${pillBase} bg-(--accent-green-glow) text-(--accent-green) border border-(--border-green)`}>
        ONLINE
      </span>
    );
  }
  if (user.lastLoginAt) {
    return (
      <span className={`${pillBase} bg-(--accent-amber) text-(--black) border border-(--accent)`}>
        OFFLINE
      </span>
    );
  }
  return (
    <span className={`${pillBase} bg-(--accent) text-(--accent-foreground)`}>
      NEVER SEEN
    </span>
  );
}

// ─── User Details ────────────────────────────────────────────────────

/** Expanded panel showing phone, asset count, last login, team (mobile), iOS status */
function UserDetails({ user }: { user: User }) {
  const rows = [
    { label: "Phone", value: `📱 ${user.phoneNumber}` },
    { label: "Assets", value: `${user.assetCount ?? 0} asset${user.assetCount !== 1 ? "s" : ""}` },
    { label: "Last login", value: user.lastLoginAt ? formatLoginAge(user.lastLoginAt) : "Never logged in" },
  ];

  return (
    <div className="px-4 pb-3 pt-1 border-t border-(--border-subtle) bg-(--card-hover) text-xs text-(--muted-foreground) space-y-1.5">
      {rows.map(({ label, value }) => (
        <div key={label} className="flex items-center gap-2">
          <span className="w-20 shrink-0 font-medium text-(--foreground)/60">{label}</span>
          <span>{value}</span>
        </div>
      ))}

      {/* Team — shown here on mobile since the pill in the row is hidden on sm */}
      <div className="flex items-center gap-2 sm:hidden">
        <span className="w-20 shrink-0 font-medium text-(--foreground)/60">Team</span>
        <span>{user.team ?? "—"}</span>
      </div>

      {/* iOS connection badge */}
      {user.hasIosConnection && (
        <div className="flex items-center gap-2">
          <span className="w-20 shrink-0 font-medium text-(--foreground)/60">iOS</span>
          <span className="text-[11px] bg-(--accent-blue-glow) text-(--accent-blue) px-1.5 py-px rounded font-semibold">
            Connected
          </span>
        </div>
      )}
    </div>
  );
}

// ─── Shared Helper ───────────────────────────────────────────────────

/** Placeholder shown when the list is loading or has no items */
function Empty({ icon, text }: { icon: string; text: string }) {
  return (
    <div className="py-10 px-6 text-center text-(--muted-foreground) text-sm">
      <div className="text-[32px] mb-2 opacity-50">{icon}</div>
      {text}
    </div>
  );
}
