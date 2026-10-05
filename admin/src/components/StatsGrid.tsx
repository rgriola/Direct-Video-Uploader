import type { Stats } from "@/lib/types";

interface StatsGridProps {
  stats?: Stats;
}

const cards = [
  {
    key: "users" as const,
    label: "👥 Users",
    color: "blue",
    detailFn: (s: Stats) => {
      const parts: string[] = [];
      parts.push(`${s.loggedInUsers} logged in`);
      if (s.onlineUsers > 0) parts.push(`${s.onlineUsers} online`);
      return parts.join(" · ");
    },
  },
  {
    key: "assets" as const,
    label: "📦 Assets",
    color: "green",
    detailFn: (s: Stats) => {
      const parts: string[] = [];
      parts.push(`${s.readyAssets} ready`);
      if (s.uploadingAssets > 0) parts.push(`${s.uploadingAssets} uploading`);
      return parts.join(" · ");
    },
  },
  {
    key: "messages" as const,
    label: "💬 Messages",
    color: "amber",
    detailFn: () => "all time",
  },
  {
    key: "clips" as const,
    label: "🎬 Clips",
    color: "purple",
    detailFn: (s: Stats) => `${s.readyAssets} ready asset${s.readyAssets !== 1 ? "s" : ""}`,
  },
] as const;

function accentVar(color: string) {
  return `var(--accent-${color})`;
}

export function StatsGrid({ stats }: StatsGridProps) {
  return (
    <div className="grid grid-cols-4 gap-4 mb-8 max-[900px]:grid-cols-2 max-[600px]:grid-cols-1">
      {cards.map((card) => {
        const value = stats?.[card.key] ?? "—";
        const detail = stats && card.detailFn ? card.detailFn(stats) : "—";

        return (
          <div
            key={card.label}
            className="group relative overflow-hidden bg-(--card) border border-(--border-subtle) rounded-(--radius-xl) px-6 py-5.5 transition-all hover:border-(--border) hover:-translate-y-0.5 hover:shadow-[0_4px_24px_rgba(0,0,0,0.3)]"
          >
            {/* Top accent bar on hover */}
            <div
              className="absolute inset-x-0 top-0 h-0.5 opacity-0 group-hover:opacity-100 transition-opacity"
              style={{ background: `linear-gradient(90deg, ${accentVar(card.color)}, transparent)` }}
            />

            <p className="text-(length:--text-xs) text-(--muted-foreground) uppercase tracking-[0.8px] font-semibold mb-2 flex items-center gap-1">
              {card.label}
            </p>
            <p
              className="text-(length:--text-3xl) font-bold tracking-tight leading-none"
              style={{ color: accentVar(card.color) }}
            >
              {value}
            </p>
            <p className="text-(length:--text-xs) text-(--muted-foreground) mt-2">{detail}</p>
          </div>
        );
      })}
    </div>
  );
}
