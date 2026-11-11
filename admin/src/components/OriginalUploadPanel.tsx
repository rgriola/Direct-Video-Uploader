import { useCallback, useEffect, useRef, useState, type DragEvent } from "react";
import { useQueryClient } from "@tanstack/react-query";
import {
  cancelOriginalUpload,
  runOriginalUpload,
  validateOriginalFile,
  type OriginalUploadJob,
  type UploadPhase,
} from "@/lib/original-upload";

type ItemStatus = "queued" | UploadPhase | "done" | "failed" | "cancelling" | "cancelled" | "invalid";

interface UploadItem {
  key: string;
  name: string;
  size: number;
  status: ItemStatus;
  loaded: number;
  message?: string;
}

const ACTIVE: ReadonlySet<ItemStatus> = new Set(["hashing", "reserving", "uploading", "verifying"]);

const STATUS_LABEL: Record<ItemStatus, string> = {
  queued: "Waiting",
  hashing: "Checking file",
  reserving: "Preparing",
  uploading: "Uploading",
  verifying: "Verifying",
  done: "Stored",
  failed: "Failed",
  cancelling: "Cancelling",
  cancelled: "Cancelled",
  invalid: "Not uploaded",
};

function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KiB", "MiB", "GiB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(1)} ${units[unit]}`;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Unknown error";
}

const buttonClass = "px-2 py-1 rounded-(--radius-md) text-(length:--text-xs) bg-(--card) border border-(--border) text-(--foreground) hover:bg-(--card-hover) disabled:opacity-50";

export function OriginalUploadPanel() {
  const queryClient = useQueryClient();
  const [items, setItems] = useState<UploadItem[]>([]);
  const [announcement, setAnnouncement] = useState("");
  const [dragging, setDragging] = useState(false);
  const jobs = useRef(new Map<string, OriginalUploadJob>());
  const controllers = useRef(new Map<string, AbortController>());
  const runs = useRef(new Map<string, Promise<void>>());
  const started = useRef(new Set<string>());

  const update = useCallback((key: string, change: Partial<UploadItem>, onlyFrom?: ReadonlySet<ItemStatus>) => {
    setItems(current => current.map(item => item.key === key && (!onlyFrom || onlyFrom.has(item.status))
      ? { ...item, ...change }
      : item));
  }, []);

  const finish = useCallback((key: string, name: string, change: Partial<UploadItem>, message: string) => {
    update(key, change);
    setAnnouncement(`${name}: ${message}`);
  }, [update]);

  const start = useCallback((item: UploadItem) => {
    const job = jobs.current.get(item.key);
    if (!job) return;
    started.current.add(item.key);
    const controller = new AbortController();
    controllers.current.set(item.key, controller);
    const progressFrom = new Set<ItemStatus>(["queued", ...ACTIVE]);
    update(item.key, { status: "hashing", loaded: 0, message: undefined });
    const run = runOriginalUpload(
      job,
      progress => update(item.key, { status: progress.phase, loaded: progress.loaded }, progressFrom),
      controller.signal,
    ).then(() => {
      finish(item.key, item.name, { status: "done", loaded: item.size }, "stored");
      void queryClient.invalidateQueries({ queryKey: ["my-assets"] });
    }, error => {
      if (controller.signal.aborted) return;
      finish(item.key, item.name, { status: "failed", message: errorMessage(error) }, `failed: ${errorMessage(error)}`);
    }).finally(() => {
      controllers.current.delete(item.key);
      runs.current.delete(item.key);
    });
    runs.current.set(item.key, run);
  }, [finish, queryClient, update]);

  useEffect(() => {
    if (items.some(item => ACTIVE.has(item.status))) return;
    const next = items.find(item => item.status === "queued" && !started.current.has(item.key));
    if (next) start(next);
  }, [items, start]);

  useEffect(() => {
    const busy = items.some(item => item.status === "queued" || item.status === "cancelling" || ACTIVE.has(item.status)
      || (item.status === "failed" && jobs.current.get(item.key)?.reservationRequested));
    if (!busy) return;
    const warn = (event: BeforeUnloadEvent) => event.preventDefault();
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [items]);

  useEffect(() => {
    const active = controllers.current;
    return () => active.forEach(controller => controller.abort());
  }, []);

  function addFiles(files: FileList | null) {
    if (!files?.length) return;
    const added = Array.from(files, (file): UploadItem => {
      const key = crypto.randomUUID();
      const invalid = validateOriginalFile(file);
      if (!invalid) jobs.current.set(key, { clientRequestId: crypto.randomUUID(), file });
      return {
        key, name: file.name, size: file.size, loaded: 0,
        status: invalid ? "invalid" : "queued",
        message: invalid ?? undefined,
      };
    });
    setItems(current => [...current, ...added]);
  }

  async function cancel(item: UploadItem) {
    const job = jobs.current.get(item.key);
    update(item.key, { status: "cancelling", message: undefined });
    controllers.current.get(item.key)?.abort();
    await runs.current.get(item.key);
    if (!job?.reservationRequested) {
      finish(item.key, item.name, { status: "cancelled", message: "Nothing was sent to the server." }, "cancelled");
      return;
    }
    try {
      const { retainedSessions } = await cancelOriginalUpload(job.clientRequestId);
      const message = retainedSessions
        ? "The original had already been stored and is retained."
        : "Unfinished parts were removed from the server.";
      finish(item.key, item.name, { status: "cancelled", message }, `cancelled. ${message}`);
    } catch (error) {
      finish(item.key, item.name,
        { status: "failed", message: `Could not cancel: ${errorMessage(error)}` },
        `could not cancel: ${errorMessage(error)}`);
    }
  }

  function retry(item: UploadItem) {
    started.current.delete(item.key);
    update(item.key, { status: "queued", message: undefined });
  }

  function remove(item: UploadItem) {
    jobs.current.delete(item.key);
    started.current.delete(item.key);
    setItems(current => current.filter(entry => entry.key !== item.key));
  }

  function onDrop(event: DragEvent) {
    event.preventDefault();
    setDragging(false);
    addFiles(event.dataTransfer.files);
  }

  return (
    <section
      aria-labelledby="original-upload-title"
      className="mb-6 bg-(--card) border border-(--border-subtle) rounded-(--radius-xl) p-6"
    >
      <h3 id="original-upload-title" className="text-(length:--text-lg) font-semibold mb-1">Upload originals</h3>
      <p className="text-(length:--text-xs) text-(--muted-foreground) mb-4">
        Full-quality originals up to 500 MiB are kept on your team's storage and its backups. Cancelling
        stops the transfer and removes unfinished parts, but a file that has finished uploading is retained.
        Keep this page open until uploads finish; leaving or reloading stops them.
      </p>
      <div
        onDragOver={event => { event.preventDefault(); setDragging(true); }}
        onDragLeave={() => setDragging(false)}
        onDrop={onDrop}
        className={`rounded-(--radius-md) border-2 border-dashed p-6 text-center focus-within:outline-2 focus-within:outline-(--foreground) ${dragging ? "border-(--foreground) bg-(--card-hover)" : "border-(--border)"}`}
      >
        <label className="cursor-pointer text-(length:--text-sm)">
          <span className="font-semibold underline">Choose video files</span> or drop them here
          <input
            type="file"
            accept="video/*"
            multiple
            className="sr-only"
            onChange={event => {
              addFiles(event.currentTarget.files);
              event.currentTarget.value = "";
            }}
          />
        </label>
      </div>
      <p aria-live="polite" className="sr-only">{announcement}</p>
      {items.length > 0 && (
        <ul aria-label="Original uploads" className="mt-4 flex flex-col gap-3">
          {items.map(item => {
            const job = jobs.current.get(item.key);
            const canCancel = item.status === "queued" || ACTIVE.has(item.status)
              || (item.status === "failed" && !!job?.reservationRequested);
            const canRemove = item.status === "done" || item.status === "cancelled" || item.status === "invalid"
              || (item.status === "failed" && !job?.reservationRequested);
            return (
              <li key={item.key} className="border-b border-(--border-subtle) pb-3 last:border-b-0">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <p className="min-w-0 truncate text-(length:--text-sm) font-semibold">{item.name}</p>
                  <div className="flex gap-2">
                    {item.status === "failed" && (
                      <button type="button" className={buttonClass} onClick={() => retry(item)} aria-label={`Retry ${item.name}`}>
                        Retry
                      </button>
                    )}
                    {canCancel && (
                      <button type="button" className={buttonClass} onClick={() => void cancel(item)} aria-label={`Cancel ${item.name}`}>
                        Cancel
                      </button>
                    )}
                    {canRemove && (
                      <button type="button" className={buttonClass} onClick={() => remove(item)} aria-label={`Remove ${item.name}`}>
                        Remove
                      </button>
                    )}
                  </div>
                </div>
                <p className="text-(length:--text-xs) text-(--muted-foreground) mt-1">
                  {STATUS_LABEL[item.status]} · {formatBytes(item.loaded)} of {formatBytes(item.size)}
                </p>
                {(ACTIVE.has(item.status) || item.status === "done") && (
                  <progress
                    className="mt-2 w-full"
                    max={item.size}
                    value={item.loaded}
                    aria-label={`${item.name} ${STATUS_LABEL[item.status].toLowerCase()}`}
                  />
                )}
                {item.message && (
                  <p role={item.status === "failed" ? "alert" : undefined} className="mt-1 text-(length:--text-xs)">
                    {item.message}
                  </p>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
