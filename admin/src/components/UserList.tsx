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
 *          └─ UserDetails  — Phone, assets, last login, team, iOS connection, delete button
 *
 * NOTE: Unlike AssetList (single accordion), UserList allows MULTIPLE rows
 * to be expanded at once. It uses a Set<string> instead of a single ID.
 */

import { useState } from "react";
import { updateUser } from "@/lib/api";
import { toast } from "sonner";
import type { User, Organization } from "@/lib/types";
import { panelHeader, subTextPanelHeader } from "@/lib/types";
import { Icon } from "./Icon";

// ─── Avatar Configuration ────────────────────────────────────────────
//
// Users cycle through blue → green → purple avatar colors based on
// their position in the sorted list. Each color maps to CSS variables
// for background, text, and border.

const avatarColors = ["blue", "green", "purple"] as const;

function avatarStyle(color: string) {
  const map: Record<string, { bg: string; text: string; border: string }> = {
    blue: {
      bg: "var(--accent-blue-glow)",
      text: "var(--accent-blue)",
      border: "var(--border-blue)",
    },
    green: {
      bg: "var(--accent-green-glow)",
      text: "var(--accent-green)",
      border: "var(--border-green)",
    },
    purple: {
      bg: "var(--accent-purple-glow)",
      text: "var(--accent-purple)",
      border: "var(--border-purple)",
    },
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
const pillBase =
  "shrink-0 inline-flex items-center px-2 py-0.5 rounded-(--radius-md) text-(length:--text-xs) font-semibold" as const;

// ─── Main Component ──────────────────────────────────────────────────

interface UserListProps {
  users?: User[];
  isLoading: boolean;
  onDeleteUser?: (userId: string, userName: string) => Promise<void>;
  currentUserId?: string;
  organizations?: Organization[];
  onRefresh?: () => void;
}

export function UserList({
  users,
  isLoading,
  onDeleteUser,
  currentUserId,
  organizations,
  onRefresh,
}: UserListProps) {
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
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius-xl) overflow-hidden">
      {/* Panel header — "Users [count]" */}
      <div className={panelHeader}>
        <h2 className="text-(length:--text-lg) font-semibold text-(--foreground) items-center gap-2">
          <Icon name="users" /> Users{" "}
          <span className={subTextPanelHeader}>{users?.length ?? 0}</span>
        </h2>
      </div>

      <div>
        {isLoading ? (
          <Empty icon={<Icon name="users" size={32} />} text="Loading users..." />
        ) : !sorted.length ? (
          <Empty
            icon={<Icon name="users" size={32} />}
            text="No users registered yet."
          />
        ) : (
          sorted.map((user, i) => (
            <UserRow
              key={user.id}
              user={user}
              color={avatarColors[i % avatarColors.length]!}
              isOpen={expanded.has(user.id)}
              onToggle={() => toggle(user.id)}
              onDeleteUser={onDeleteUser}
              isSelf={user.id === currentUserId}
              organizations={organizations}
              onRefresh={onRefresh}
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
  color: string; // Avatar color key: "blue" | "green" | "purple"
  isOpen: boolean;
  onToggle: () => void;
  onDeleteUser?: (userId: string, userName: string) => Promise<void>;
  isSelf: boolean;
  organizations?: Organization[];
  onRefresh?: () => void;
}

function UserRow({
  user,
  color,
  isOpen,
  onToggle,
  onDeleteUser,
  isSelf,
  organizations,
  onRefresh,
}: UserRowProps) {
  const s = avatarStyle(color);
  const initials = user.name
    .split(" ")
    .map((w) => w[0])
    .join("");

  return (
    <div className="border-b border-(--border-subtle) last:border-b-0">
      {/* ── Collapsed row — always visible ── */}
      <button
        onClick={onToggle}
        aria-expanded={isOpen}
        className="w-full flex items-center gap-3 px-4 py-3 hover:bg-(--card-hover) transition-colors text-left"
      >
        {/* Avatar with initials + online dot */}
        <div className="relative shrink-0">
          <div
            className="w-9 h-9 rounded-(--radius-lg) flex items-center justify-center font-bold text-(length:--text-sm)"
            style={{
              background: s.bg,
              color: s.text,
              border: `1px solid ${s.border}`,
            }}
          >
            {initials}
          </div>
          {user.isOnline && (
            <span className="absolute -top-0.5 -right-0.5 w-2.5 h-2.5 rounded-(--radius-full) bg-(--accent-green) border-2 border-(--card)" />
          )}
        </div>

        {/* Name */}
        <span className="flex-1 min-w-0 text-(length:--text-sm) font-semibold truncate">
          {user.name}
        </span>

        {/* Team pill */}
        <span
          className={`${pillBase} bg-(--secondary) text-(--secondary-foreground) border border-(--border-subtle)`}
        >
          {user.team ?? "—"}
        </span>

        {/* Company pill — only if user has a company */}
        {user.companyCode && (
          <span
            className={`${pillBase} bg-(--accent-purple)/15 text-(--accent-purple) border border-(--accent-purple)/30 tracking-wider`}
          >
            {user.companyCode}
          </span>
        )}

        {/* Status pill: ONLINE / OFFLINE / NEVER SEEN */}
        <StatusPill user={user} />

        {/* Chevron — rotates when expanded */}
        <Icon
          name="expand"
          className={`shrink-0 w-4 h-4 text-(--muted-foreground) transition-transform ${isOpen ? "rotate-180" : ""}`}
        />
      </button>

      {/* ── Expanded detail panel ── */}
      {isOpen && (
        <UserDetails
          user={user}
          onDeleteUser={onDeleteUser}
          isSelf={isSelf}
          organizations={organizations}
          onRefresh={onRefresh}
        />
      )}
    </div>
  );
}

// ─── Status Pill ─────────────────────────────────────────────────────

/** Renders the ONLINE / OFFLINE / NEVER SEEN pill based on user state */
function StatusPill({ user }: { user: User }) {
  if (user.isOnline) {
    return (
      <span
        className={`${pillBase} bg-(--accent-green-glow) text-(--accent-green) border border-(--border-green)`}
      >
        ONLINE
      </span>
    );
  }
  if (user.lastLoginAt) {
    return (
      <span
        className={`${pillBase} bg-(--accent-amber-glow) text-(--accent-amber) border border-(--border-amber)`}
      >
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

interface UserDetailsProps {
  user: User;
  onDeleteUser?: (userId: string, userName: string) => Promise<void>;
  isSelf: boolean;
  organizations?: Organization[];
  onRefresh?: () => void;
}

/** Expanded panel showing phone, asset count, last login, team (mobile), iOS status, company, delete button */
function UserDetails({
  user,
  onDeleteUser,
  isSelf,
  organizations,
  onRefresh,
}: UserDetailsProps) {
  const [confirming, setConfirming] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [editingCompany, setEditingCompany] = useState(false);
  const [selectedCode, setSelectedCode] = useState(user.companyCode ?? "");
  const [savingCompany, setSavingCompany] = useState(false);

  async function handleDelete() {
    if (!confirming) {
      setConfirming(true);
      return;
    }
    setDeleting(true);
    try {
      await onDeleteUser?.(user.id, user.name);
    } finally {
      setDeleting(false);
      setConfirming(false);
    }
  }

  async function handleSaveCompany() {
    setSavingCompany(true);
    try {
      const res = await updateUser(user.id, {
        companyCode: selectedCode || null,
      });
      toast.success(res.message);
      setEditingCompany(false);
      onRefresh?.();
    } catch (err) {
      toast.error(
        err instanceof Error ? err.message : "Failed to update company",
      );
    } finally {
      setSavingCompany(false);
    }
  }

  const rows = [
    { label: "Phone", icon: "device" as const, value: user.phoneNumber },
    {
      label: "Assets",
      icon: null,
      value: `${user.assetCount ?? 0} asset${user.assetCount !== 1 ? "s" : ""}`,
    },
    {
      label: "Last login",
      icon: null,
      value: user.lastLoginAt
        ? formatLoginAge(user.lastLoginAt)
        : "Never logged in",
    },
  ];

  return (
    <div className="px-4 pb-3 pt-1 border-t border-(--border-subtle) bg-(--card-hover) text-(length:--text-xs) text-(--muted-foreground) space-y-1.5">
      {rows.map(({ label, icon, value }) => (
        <div key={label} className="flex items-center gap-2">
          <span className="w-20 shrink-0 font-medium text-(--foreground)/60">
            {label}
          </span>
          <span className="inline-flex items-center gap-1">
            {icon && <Icon name={icon} />} {value}
          </span>
        </div>
      ))}

      {/* Team — shown here on mobile since the pill in the row is hidden on sm */}
      <div className="flex items-center gap-2 sm:hidden">
        <span className="w-20 shrink-0 font-medium text-(--foreground)/60">
          Team
        </span>
        <span>{user.team ?? "—"}</span>
      </div>

      {/* iOS connection badge */}
      {user.hasIosConnection && (
        <div className="flex items-center gap-2">
          <span className="w-20 shrink-0 font-medium text-(--foreground)/60">
            iOS
          </span>
          <span className="text-(length:--text-xs) bg-(--accent-blue-glow) text-(--accent-blue) px-1.5 py-px rounded-(--radius-sm) font-semibold">
            Connected
          </span>
        </div>
      )}

      {/* Company — display + admin edit */}
      <div className="flex items-center gap-2">
        <span className="w-20 shrink-0 font-medium text-(--foreground)/60 flex items-center gap-1">
          <Icon name="organization" /> Company
        </span>
        {editingCompany ? (
          <div className="flex items-center gap-1.5">
            <select
              value={selectedCode}
              onChange={(e) => setSelectedCode(e.target.value)}
              className="px-2 py-1 rounded-(--radius-sm) text-(length:--text-xs) bg-(--secondary) border border-(--border) text-(--foreground) focus:outline-none focus:border-(--accent-blue)"
            >
              <option value="">None</option>
              {organizations?.map((org) => (
                <option key={org.companyCode} value={org.companyCode}>
                  {org.companyCode} — {org.companyName}
                </option>
              ))}
            </select>
            <button
              onClick={handleSaveCompany}
              disabled={savingCompany}
              className="px-2 py-1 rounded-(--radius-sm) text-(length:--text-xs) font-semibold bg-(--accent-blue) text-white hover:opacity-90 cursor-pointer disabled:opacity-50"
            >
              {savingCompany ? "..." : "Save"}
            </button>
            <button
              onClick={() => {
                setEditingCompany(false);
                setSelectedCode(user.companyCode ?? "");
              }}
              className="px-2 py-1 rounded-(--radius-sm) text-(length:--text-xs) text-(--muted-foreground) hover:text-(--foreground) cursor-pointer"
            >
              Cancel
            </button>
          </div>
        ) : (
          <div className="flex items-center gap-1.5">
            <span>
              {user.companyName
                ? `${user.companyName} (${user.companyCode})`
                : "—"}
            </span>
            {onDeleteUser && (
              <button
                onClick={() => setEditingCompany(true)}
                className="text-(length:--text-xs) text-(--accent-blue) hover:underline cursor-pointer"
              >
                Edit
              </button>
            )}
          </div>
        )}
      </div>

      {/* Delete user — Super Admin only, hidden for self and other Super Admins */}
      {onDeleteUser && !isSelf && user.role !== "SUPER_ADMIN" && (
        <div className="pt-2 mt-2 border-t border-(--border-subtle)">
          {confirming && !deleting && (
            <p className="text-(length:--text-xs) text-(--accent-red) font-semibold mb-2 inline-flex items-start gap-1">
              <Icon name="warning" /> This will permanently delete {user.name} and ALL their data.
              Click again to confirm.
            </p>
          )}
          <div className="flex items-center gap-2">
            <button
              onClick={handleDelete}
              disabled={deleting}
              className={`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-(--radius-lg) text-(length:--text-xs) font-semibold border transition-all cursor-pointer ${
                confirming
                  ? "bg-(--accent-red) border-(--accent-red) text-white hover:opacity-90"
                  : "bg-(--secondary) border-(--border-subtle) text-(--muted-foreground) hover:bg-(--accent-red-glow) hover:border-(--accent-red)/50 hover:text-(--accent-red)"
              } disabled:opacity-50 disabled:cursor-not-allowed`}
            >
              <Icon name="delete" className="w-3 h-3" />
              {deleting
                ? "Deleting..."
                : confirming
                  ? "Confirm Delete"
                  : "Delete User"}
            </button>
            {confirming && !deleting && (
              <button
                onClick={() => setConfirming(false)}
                className="px-3 py-1.5 rounded-(--radius-lg) text-(length:--text-xs) font-medium bg-(--secondary) border border-(--border-subtle) text-(--muted-foreground) hover:text-(--foreground) transition-all cursor-pointer"
              >
                Cancel
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Shared Helper ───────────────────────────────────────────────────

/** Placeholder shown when the list is loading or has no items */
function Empty({ icon, text }: { icon: React.ReactNode; text: string }) {
  return (
    <div className="py-10 px-6 text-center text-(--muted-foreground) text-(length:--text-sm)">
      <div className="flex justify-center mb-2 opacity-50">{icon}</div>
      {text}
    </div>
  );
}
