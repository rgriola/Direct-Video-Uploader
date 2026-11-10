import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { MonitoringPanel } from "@/components/MonitoringPanel";
import type { MonitoringSnapshot } from "@/lib/types";

afterEach(cleanup);

describe("storage and backup monitoring panel", () => {
  it("explains disabled monitoring and missing external alerts", () => {
    const disabled: MonitoringSnapshot = { enabled: false, checkedAt: null, checks: [], stale: false };
    const { rerender } = render(<MonitoringPanel snapshot={disabled} isLoading={false} isError={false} />);
    expect(screen.getByText("Monitoring is not configured.")).toBeTruthy();
    rerender(<MonitoringPanel snapshot={{ ...disabled, enabled: true }} isLoading={false} isError={false} />);
    expect(screen.getByText(/no external alerts are sent/)).toBeTruthy();
    expect(screen.getByText("Waiting for the first monitoring check.")).toBeTruthy();
  });

  it("shows severities, capacity, running jobs, and stale or failed refreshes", () => {
    const snapshot: MonitoringSnapshot = {
      enabled: true,
      checkedAt: "2026-03-01T12:00:00.000Z",
      stale: true,
      checks: [
        {
          id: "source-space", label: "Original storage", category: "storage", status: "warning",
          message: "Storage has reached a warning threshold",
          metrics: { freeBytes: "1073741824", usedBytes: "2048", limitBytes: "4096" },
        },
        {
          id: "original-b2", label: "Original backup: B2", category: "backup", status: "critical",
          message: "The most recent backup run failed", running: true,
        },
      ],
    };
    render(<MonitoringPanel snapshot={snapshot} isLoading={false} isError />);
    expect(screen.getByText("warning").className).toContain("text-(--foreground)");
    expect(screen.getByText("critical").className).toContain("text-(--foreground)");
    expect(screen.getByText("Free: 1.0 GiB")).toBeTruthy();
    expect(screen.getByText(/2.0 KiB \/ 4.0 KiB limit/)).toBeTruthy();
    expect(screen.getByText("Run in progress")).toBeTruthy();
    expect(screen.getByText("Monitoring results are stale.")).toBeTruthy();
    expect(screen.getByText(/Could not refresh monitoring status/)).toBeTruthy();
  });
});
