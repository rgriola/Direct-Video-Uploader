import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  audit: vi.fn(),
  issues: vi.fn(),
  retired: vi.fn(),
}));

vi.mock("@/lib/api", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/lib/api")>(),
  fetchAuditLogs: mocks.audit,
  fetchMediaIssues: mocks.issues,
  fetchRetiredMuxEvents: mocks.retired,
}));

const { AuditLog } = await import("@/components/AuditLog");

function renderAudit() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(<QueryClientProvider client={client}><AuditLog /></QueryClientProvider>);
}

afterEach(() => {
  cleanup();
  vi.resetAllMocks();
});

describe("retired Mux reference monitoring", () => {
  it("shows retained references and loads additional pages", async () => {
    mocks.audit.mockResolvedValue({ logs: [] });
    mocks.issues.mockResolvedValue({ issues: [], hasMore: false });
    mocks.retired
      .mockResolvedValueOnce({
        events: [{
          operationId: "operation-1", muxAssetId: "Mux-1", firstSeenAt: "2026-01-01T00:00:00Z",
          attempt: { originalMuxAssetId: "Mux-old" },
        }],
        nextCursor: { operationId: "operation-1", muxAssetId: "Mux-1" },
      })
      .mockResolvedValueOnce({
        events: [{
          operationId: "operation-1", muxAssetId: "mux-2", firstSeenAt: "2026-01-02T00:00:00Z",
          attempt: { originalMuxAssetId: "Mux-old" },
        }],
        nextCursor: null,
      });
    renderAudit();
    expect(await screen.findByText("Mux-1")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Load more Mux references" }));
    expect(await screen.findByText("mux-2")).toBeTruthy();
    expect(mocks.retired).toHaveBeenLastCalledWith({ operationId: "operation-1", muxAssetId: "Mux-1" });
    expect(screen.queryByRole("button", { name: "Load more Mux references" })).toBeNull();
  });

  it("surfaces failures instead of reporting an empty list", async () => {
    mocks.audit.mockResolvedValue({ logs: [] });
    mocks.issues.mockResolvedValue({ issues: [], hasMore: false });
    mocks.retired.mockRejectedValue(new Error("Retired references unavailable"));
    renderAudit();
    expect((await screen.findByRole("alert")).textContent).toBe("Retired references unavailable");
    expect(screen.queryByText("No retired Mux references have been reported.")).toBeNull();
  });
});
