import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { OriginalUploadJob, UploadProgress } from "@/lib/original-upload";

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
  resolve: () => void;
  reject: (error: Error) => void;
};

let runs: Run[];
let queryClient: QueryClient;

function renderPanel() {
  return render(<QueryClientProvider client={queryClient}><OriginalUploadPanel /></QueryClientProvider>);
}

function addFiles(...files: File[]) {
  fireEvent.change(screen.getByLabelText(/Choose video files/), { target: { files } });
}

function video(name: string, text = "video") {
  return new File([text], name, { type: "video/mp4" });
}

beforeEach(() => {
  runs = [];
  queryClient = new QueryClient();
  upload.run.mockImplementation((job: OriginalUploadJob, onProgress: Run["onProgress"], signal: AbortSignal) =>
    new Promise<void>((resolve, reject) => {
      runs.push({ job, onProgress, signal, resolve, reject });
      signal.addEventListener("abort", () => reject(new Error("aborted")));
    }));
  upload.cancel.mockResolvedValue({ retainedSessions: 0 });
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
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

    runs[0].job.reservationRequested = true;
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
    runs[0].job.reservationRequested = true;

    fireEvent.click(screen.getByRole("button", { name: "Cancel clip.mp4" }));

    expect(await screen.findByText("The original had already been stored and is retained.")).toBeTruthy();
    expect(runs[0].signal.aborted).toBe(true);
    expect(upload.cancel).toHaveBeenCalledWith(runs[0].job.clientRequestId);
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
});
