import { cn } from "@/lib/utils";
import { panelHeader, type MonitoringCheck, type MonitoringSnapshot } from "@/lib/types";

const statusClass: Record<MonitoringCheck["status"], string> = {
  ok: "border-(--accent-green)",
  warning: "border-(--accent-amber)",
  critical: "border-(--accent-red)",
  unknown: "border-(--border)",
};

function formatBytes(value: string) {
  if (!/^[0-9]+$/.test(value)) return "Unavailable";
  const bytes = BigInt(value);
  const units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
  let divisor = 1n;
  let unit = 0;
  while (bytes >= divisor * 1024n && unit < units.length - 1) {
    divisor *= 1024n;
    unit += 1;
  }
  if (unit === 0) return `${bytes} B`;
  const tenths = bytes * 10n / divisor;
  return `${tenths / 10n}.${tenths % 10n} ${units[unit]}`;
}

function displayTime(value: string) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "Unavailable" : date.toLocaleString();
}

interface MonitoringPanelProps {
  snapshot?: MonitoringSnapshot;
  isLoading: boolean;
  isError: boolean;
}

export function MonitoringPanel({ snapshot, isLoading, isError }: MonitoringPanelProps) {
  return (
    <section aria-labelledby="monitoring-heading" className="bg-(--card) border border-(--border-subtle) rounded-(--radius-xl) overflow-hidden mb-8">
      <div className={panelHeader}>
        <h2 id="monitoring-heading" className="text-(length:--text-lg) font-semibold">Storage &amp; Backup Monitoring</h2>
        {snapshot?.checkedAt && (
          <span className="text-(length:--text-xs)">Checked {displayTime(snapshot.checkedAt)}</span>
        )}
      </div>
      <div className="px-6 py-4">
        {isError && <p role="alert" className="border-l-4 border-(--accent-red) pl-3">Could not refresh monitoring status. Displayed results may be outdated.</p>}
        {isLoading && !snapshot && <p>Loading monitoring status...</p>}
        {snapshot && !snapshot.enabled && <p>Monitoring is not configured.</p>}
        {snapshot?.enabled && (
          <>
            <p className="text-(length:--text-xs) text-(--muted-foreground) mb-3">
              {snapshot.checks.some(check => check.id === "alert-delivery")
                ? "Slack alerts are configured for problems while the server runs; none are sent if the server is down."
                : "Dashboard only: no external alerts are sent when this page is closed or the server is down."}
            </p>
            {snapshot.stale && <p role="alert" className="border-l-4 border-(--accent-red) pl-3 mb-3">Monitoring results are stale.</p>}
            {!snapshot.checkedAt && <p>Waiting for the first monitoring check.</p>}
            <div className="grid grid-cols-2 gap-3 max-[900px]:grid-cols-1">
              {snapshot.checks.map((check) => (
                <div key={check.id} className="border border-(--border-subtle) rounded-(--radius-md) p-3">
                  <div className="flex items-center justify-between gap-2">
                    <h3 className="font-semibold">{check.label}</h3>
                    <span className={cn("shrink-0 border-l-4 pl-2 text-(--foreground) text-(length:--text-xs) font-semibold uppercase", statusClass[check.status])}>
                      {check.status}
                    </span>
                  </div>
                  <p className="text-(length:--text-sm) mt-1">{check.message}</p>
                  {check.metrics?.freeBytes && <p className="text-(length:--text-xs)">Free: {formatBytes(check.metrics.freeBytes)}</p>}
                  {check.metrics?.usedBytes && (
                    <p className="text-(length:--text-xs)">
                      Original storage on disk: {formatBytes(check.metrics.usedBytes)}
                      {check.metrics.limitBytes ? ` / ${formatBytes(check.metrics.limitBytes)} limit` : ""}
                      {" "}— excludes upload reservations
                    </p>
                  )}
                  {check.lastSuccessAt && <p className="text-(length:--text-xs)">Last success: {displayTime(check.lastSuccessAt)}</p>}
                  {check.running && <p className="text-(length:--text-xs)">Run in progress</p>}
                </div>
              ))}
            </div>
          </>
        )}
      </div>
    </section>
  );
}
