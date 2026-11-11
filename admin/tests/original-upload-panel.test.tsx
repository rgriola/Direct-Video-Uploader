import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { clearToken, setToken } from "@/lib/api";
import { OriginalUploadJournal, UploadFileMismatchError } from "@/lib/original-upload-journal";
import type { OriginalUploadJob, UploadProgress, UploadTransport } from "@/lib/original-upload";

const upload = vi.hoisted(() => ({
  run: vi.fn(),
  cancel: vi.fn(),
}));

vi.mock("@/lib/original-upload", async importOriginal => ({
  ...await importOriginal<typeof import("@/lib/original-upload")>(),
  runOriginalUpload: upload.run,
  cancelOriginalUpload: upload.cancel,
}));

const { OriginalUploadPanel } = await import("@/components/OriginalUploadPanel");

type Run = {
  job: OriginalUploadJob;
  onProgress: (progress: UploadProgress) => void;
  signal: AbortSignal;
  transport: UploadTransport;
  beforeReservation: (job: OriginalUploadJob) => void;
  resolve: () => void;
  reject: (error: Error) => void;
};

let runs: Run[];
let queryClient: QueryClient;

function renderPanel(ownerId = "owner-a") {
  return render(<QueryClientProvider client={queryClient}><OriginalUploadPanel ownerId={ownerId} /></QueryClientProvider>);
}

function addFiles(...files: File[]) {
  fireEvent.change(screen.getByLabelText(/Choose video files/), { target: { files } });
}

function video(name: string, text = "video") {
  return new File([text], name, { type: "video/mp4" });
}

function markReserved(run: Run, digest = "a".repeat(64)) {
  run.job.sha256 = digest;
  run.beforeReservation(run.job);
  run.job.reservationRequested = true;
}

beforeEach(() => {
  runs = [];
  queryClient = new QueryClient();
  localStorage.clear();
  setToken("owner-a-token");
  const held = new Set<string>();
  Object.defineProperty(navigator, "locks", {
    configurable: true,
    value: {
      request: async (name: string, _options: unknown, work: (lock: object | null) => Promise<unknown>) => {
        if (held.has(name)) return work(null);
        held.add(name);
        try { return await work({}); } finally { held.delete(name); }
      },
    },
  });
  upload.run.mockImplementation((job: OriginalUploadJob, onProgress: Run["onProgress"], signal: AbortSignal,
    transport: UploadTransport, beforeReservation: Run["beforeReservation"]) =>
    new Promise<void>((resolve, reject) => {
      runs.push({ job, onProgress, signal, transport, beforeReservation, resolve, reject });
      signal.addEventListener("abort", () => reject(new Error("aborted")));
    }));
  upload.cancel.mockResolvedValue({ retainedSessions: 0 });
});

afterEach(() => {
  cleanup();
  clearToken();
  localStorage.clear();
  vi.clearAllMocks();
  vi.restoreAllMocks();
});

describe("original upload panel", () => {
  it("uploads queued files one at a time and refreshes the video list", async () => {
    const invalidate = vi.spyOn(queryClient, "invalidateQueries");
    renderPanel();
    addFiles(video("first.mp4"), video("second.mp4"));

    await waitFor(() => expect(runs).toHaveLength(1));
    expect(runs[0].job.file.name).toBe("first.mp4");
    act(() => runs[0].onProgress({ phase: "uploading", loaded: 2, total: 5 }));
    expect(screen.getByText(/Uploading · 2 B of 5 B/)).toBeTruthy();
    expect(screen.getByText(/Waiting/)).toBeTruthy();

    await act(async () => runs[0].resolve());
    await waitFor(() => expect(runs).toHaveLength(2));
    expect(screen.getByText(/Stored · 5 B of 5 B/)).toBeTruthy();
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["my-assets"] });
  });

  it("rejects empty files without contacting the server", () => {
    renderPanel();
    addFiles(video("empty.mp4", ""));

    expect(screen.getByText("The file is empty.")).toBeTruthy();
    expect(screen.getByText(/Not uploaded/)).toBeTruthy();
    expect(upload.run).not.toHaveBeenCalled();
  });

  it("retries a failed upload with the same request", async () => {
    renderPanel();
    addFiles(video("clip.mp4"));
    await waitFor(() => expect(runs).toHaveLength(1));

    markReserved(runs[0]);
    await act(async () => runs[0].reject(new Error("Original storage is unavailable")));
    expect(screen.getByRole("alert").textContent).toBe("Original storage is unavailable");
    expect(screen.queryByRole("button", { name: "Remove clip.mp4" })).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "Retry clip.mp4" }));
    expect(document.activeElement?.textContent).toBe("clip.mp4");
    await waitFor(() => expect(runs).toHaveLength(2));
    expect(runs[1].job).toBe(runs[0].job);
  });

  it("stops an active upload and fences its reservation", async () => {
    upload.cancel.mockResolvedValue({ retainedSessions: 1 });
    renderPanel();
    addFiles(video("clip.mp4"));
    await waitFor(() => expect(runs).toHaveLength(1));
    markReserved(runs[0]);

    fireEvent.click(screen.getByRole("button", { name: "Cancel clip.mp4" }));

    expect(await screen.findByText("The original had already been stored and is retained.")).toBeTruthy();
    expect(runs[0].signal.aborted).toBe(true);
    expect(upload.cancel).toHaveBeenCalledWith(runs[0].job.clientRequestId, expect.objectContaining({
      request: expect.any(Function),
    }));
  });

  it("cancels an unsent upload locally", async () => {
    renderPanel();
    addFiles(video("first.mp4"), video("second.mp4"));
    await waitFor(() => expect(runs).toHaveLength(1));

    fireEvent.click(screen.getByRole("button", { name: "Cancel second.mp4" }));

    expect(await screen.findByText("Nothing was sent to the server.")).toBeTruthy();
    expect(document.activeElement?.textContent).toBe("second.mp4");
    expect(upload.cancel).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Remove second.mp4" }));
    expect(document.activeElement).toBe(screen.getByLabelText(/Choose video files/));
    await act(async () => runs[0].resolve());
    expect(runs).toHaveLength(1);
  });

  it("reports retention if completion wins a cancellation race", async () => {
    upload.run.mockImplementation((job: OriginalUploadJob, onProgress: Run["onProgress"], signal: AbortSignal,
      transport: UploadTransport, beforeReservation: Run["beforeReservation"]) =>
      new Promise<void>((resolve, reject) => {
        runs.push({ job, onProgress, signal, transport, beforeReservation, resolve, reject });
      }));
    renderPanel();
    addFiles(video("clip.mp4"));
    await waitFor(() => expect(runs).toHaveLength(1));
    markReserved(runs[0]);
    fireEvent.click(screen.getByRole("button", { name: "Cancel clip.mp4" }));
    expect(runs[0].signal.aborted).toBe(true);

    await act(async () => runs[0].resolve());
    expect(await screen.findByText("The original had already been stored and is retained.")).toBeTruthy();
    expect(upload.cancel).not.toHaveBeenCalled();
    expect(new OriginalUploadJournal("owner-a", localStorage).entries()).toEqual([]);
  });

  it("recovers a reservation in the same tab, rejecting a different file before resuming", async () => {
    const first = renderPanel();
    addFiles(video("clip.mp4"));
    await waitFor(() => expect(runs).toHaveLength(1));
    markReserved(runs[0]);
    const requestId = runs[0].job.clientRequestId;
    await act(async () => first.unmount());

    renderPanel();
    expect(screen.getByText("Choose the original file to resume · 0 B of 5 B")).toBeTruthy();
    fireEvent.change(screen.getByLabelText("Choose the original file for clip.mp4"), {
      target: { files: [video("wrong.mp4", "other")] },
    });
    await waitFor(() => expect(runs).toHaveLength(2));
    expect(runs[1].job.clientRequestId).toBe(requestId);
    expect(runs[1].job.originalFileName).toBe("clip.mp4");
    const wrong = new UploadFileMismatchError();
    runs[1].job.sha256 = "b".repeat(64);
    expect(() => runs[1].beforeReservation(runs[1].job)).toThrow(UploadFileMismatchError);
    await act(async () => runs[1].reject(wrong));
    expect(screen.getByRole("alert").textContent).toMatch(/does not match/);

    fireEvent.change(screen.getByLabelText("Choose the original file for clip.mp4"), {
      target: { files: [video("renamed.mp4")] },
    });
    await waitFor(() => expect(runs).toHaveLength(3));
    markReserved(runs[2]);
    await act(async () => runs[2].resolve());
    expect(screen.getByText(/Stored · 5 B of 5 B/)).toBeTruthy();
    expect(new OriginalUploadJournal("owner-a", localStorage).entries()).toEqual([]);
  });

  it("keeps a failed cancellation pending across navigation without allowing upload retry", async () => {
    upload.cancel.mockRejectedValueOnce(new Error("Network unavailable"));
    const first = renderPanel();
    addFiles(video("clip.mp4"));
    await waitFor(() => expect(runs).toHaveLength(1));
    markReserved(runs[0]);
    fireEvent.click(screen.getByRole("button", { name: "Cancel clip.mp4" }));
    expect(await screen.findByText(/Could not cancel: Network unavailable/)).toBeTruthy();
    first.unmount();

    renderPanel();
    expect(screen.getByText(/Cancellation pending/)).toBeTruthy();
    expect(screen.queryByLabelText("Choose the original file for clip.mp4")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Finish cancelling clip.mp4" }));
    expect(await screen.findByText("Unfinished parts were removed from the server.")).toBeTruthy();
    expect(upload.run).toHaveBeenCalledTimes(1);
    expect(new OriginalUploadJournal("owner-a", localStorage).entries()).toEqual([]);
  });

  it("explains that an unsent queued file cannot yet be verified after recovery", async () => {
    const first = renderPanel();
    addFiles(video("pending.mp4"));
    await waitFor(() => expect(runs).toHaveLength(1));
    await act(async () => first.unmount());

    renderPanel();
    expect(screen.getByText(/This file was not checked before the interruption/)).toBeTruthy();
    fireEvent.change(screen.getByLabelText("Choose the original file for pending.mp4"), {
      target: { files: [video("different.mp4")] },
    });
    expect(screen.getByRole("alert").textContent).toMatch(/original name/);
    expect(runs).toHaveLength(1);
  });

  it("keeps recovery records isolated by account and stops requests after the token changes", async () => {
    const first = renderPanel();
    addFiles(video("clip.mp4"));
    await waitFor(() => expect(runs).toHaveLength(1));
    markReserved(runs[0]);
    setToken("owner-b-token");
    expect(() => runs[0].transport.request("GET", "/api/assets/mine")).toThrow(/session changed/i);
    expect(() => runs[0].transport.putPart("/part", new Blob(), () => {}, new AbortController().signal))
      .toThrow(/session changed/i);
    first.unmount();

    renderPanel("owner-b");
    expect(screen.queryByText("clip.mp4")).toBeNull();
    expect(new OriginalUploadJournal("owner-a", localStorage).entries()).toHaveLength(1);
  });

  it("does not start an upload if recovery data cannot be saved", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new Error("storage full"); });
    renderPanel();
    addFiles(video("clip.mp4"));
    expect(screen.getByRole("alert").textContent).toMatch(/Cannot save upload recovery data/);
    expect(upload.run).not.toHaveBeenCalled();
  });

  it("fails closed when the browser cannot coordinate recovery", () => {
    Object.defineProperty(navigator, "locks", { configurable: true, value: undefined });
    renderPanel();
    expect(screen.getByRole("alert").textContent).toMatch(/cannot safely coordinate/);
    expect(screen.getByLabelText(/Choose video files/)).toHaveProperty("disabled", true);
  });

  it("does not process a job held by another tab", async () => {
    Object.defineProperty(navigator, "locks", {
      configurable: true,
      value: { request: (_name: string, _options: unknown, work: (lock: object | null) => Promise<unknown>) => work(null) },
    });
    renderPanel();
    addFiles(video("clip.mp4"));
    expect((await screen.findByRole("alert")).textContent).toMatch(/Another page or tab is processing this upload/);
    expect(upload.run).not.toHaveBeenCalled();
  });

  it("does not mistake another tab's reservation for an unsent local upload", async () => {
    const first = renderPanel();
    addFiles(video("clip.mp4"));
    await waitFor(() => expect(runs).toHaveLength(1));
    const second = renderPanel();
    markReserved(runs[0]);

    fireEvent.click(within(second.container).getByRole("button", { name: "Cancel clip.mp4" }));
    expect((await within(second.container).findByRole("alert")).textContent).toMatch(/Another page or tab is processing/);
    expect(upload.cancel).not.toHaveBeenCalled();
    expect(within(second.container).queryByText("Nothing was sent to the server.")).toBeNull();

    await act(async () => runs[0].reject(new Error("Connection interrupted")));
    fireEvent.click(within(second.container).getByRole("button", { name: "Cancel clip.mp4" }));
    expect(await within(second.container).findByText("Unfinished parts were removed from the server.")).toBeTruthy();
    expect(upload.cancel).toHaveBeenCalledTimes(1);
    first.unmount();
  });

  it("does not overwrite damaged recovery data", () => {
    const key = "dvu-original-uploads:v1:owner-a:11111111-1111-4111-8111-111111111111";
    localStorage.setItem(key, "{bad json");
    renderPanel();
    expect(screen.getByRole("alert").textContent).toMatch(/Cannot read upload recovery data/);
    expect(screen.getByLabelText(/Choose video files/)).toHaveProperty("disabled", true);
    expect(localStorage.getItem(key)).toBe("{bad json");
  });
});

describe("original upload journal", () => {
  it("preserves newer entries and pending cancellation across overlapping panel instances", () => {
    const older = new OriginalUploadJournal("owner-a", localStorage);
    const entry = {
      clientRequestId: "11111111-1111-4111-8111-111111111111",
      fileName: "first.mp4",
      sizeBytes: 5,
      expectedSha256: "a".repeat(64),
      reservationRequested: true,
      cancellationRequested: false,
    };
    older.add(entry);
    const newer = new OriginalUploadJournal("owner-a", localStorage);
    newer.add({ ...entry, clientRequestId: "22222222-2222-4222-8222-222222222222", fileName: "second.mp4" });
    newer.requestCancellation(entry.clientRequestId);

    expect(older.complete(entry.clientRequestId)).toBe(false);
    expect(new OriginalUploadJournal("owner-a", localStorage).entries()).toMatchObject([
      { clientRequestId: entry.clientRequestId, cancellationRequested: true },
      { fileName: "second.mp4" },
    ]);
  });
});
