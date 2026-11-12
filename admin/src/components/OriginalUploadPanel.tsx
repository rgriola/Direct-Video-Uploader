import { useCallback, useEffect, useRef, useState, type DragEvent } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { getToken } from "@/lib/api";
import {
  browserTransport,
  cancelOriginalUpload,
  runOriginalUpload,
  validateOriginalFile,
  type OriginalUploadJob,
  type UploadTransport,
  type UploadPhase,
} from "@/lib/original-upload";
import {
  OriginalUploadJournal,
  UploadFileMismatchError,
  type UploadJournalEntry,
} from "@/lib/original-upload-journal";

type ItemStatus = "queued" | UploadPhase | "done" | "failed" | "cancelling" | "cancelled" | "invalid"
  | "needs-file" | "cancellation-pending";

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
  "needs-file": "Choose the original file to resume",
  "cancellation-pending": "Cancellation pending",
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

function initializeRecovery(ownerId: string): {
  journal: OriginalUploadJournal | null;
  entries: UploadJournalEntry[];
  error: string | null;
} {
  try {
    if (!navigator.locks) {
      throw new Error("This browser cannot safely coordinate upload recovery. Use a current browser over HTTPS.");
    }
    const journal = new OriginalUploadJournal(ownerId, window.localStorage);
    return { journal, entries: journal.entries(), error: null };
  } catch (error) {
    return { journal: null, entries: [], error: errorMessage(error) };
  }
}

function scopedTransport(token: string): UploadTransport {
  const checkSession = () => {
    if (getToken() !== token) throw new Error("Your session changed. Sign in again to resume this upload.");
  };
  return {
    request: <T,>(method: string, path: string, body?: unknown) => {
      checkSession();
      return browserTransport.request<T>(method, path, body);
    },
    putPart: (url, body, onProgress, signal) => {
      checkSession();
      return browserTransport.putPart(url, body, onProgress, signal);
    },
    sleep: browserTransport.sleep,
  };
}

async function withUploadLock<T>(ownerId: string, requestId: string, work: () => Promise<T>): Promise<T> {
  if (!navigator.locks) throw new Error("This browser cannot safely coordinate upload recovery.");
  return navigator.locks.request(
    `dvu-original-upload:${encodeURIComponent(ownerId)}:${requestId}`,
    { ifAvailable: true },
    lock => {
      if (!lock) throw new Error("Another page or tab is processing this upload. Try again when it finishes.");
      return work();
    },
  );
}

const buttonClass = "px-2 py-1 rounded-(--radius-md) text-(length:--text-xs) bg-(--card) border border-(--border) text-(--foreground) hover:bg-(--card-hover) disabled:opacity-50";

export function OriginalUploadPanel({ ownerId }: { ownerId: string }) {
  const queryClient = useQueryClient();
  const [recovery] = useState(() => initializeRecovery(ownerId));
  const journal = recovery.journal;
  const [items, setItems] = useState<UploadItem[]>(() => recovery.entries.map(entry => ({
    key: entry.clientRequestId,
    name: entry.fileName,
    size: entry.sizeBytes,
    loaded: 0,
    status: entry.cancellationRequested ? "cancellation-pending" : "needs-file",
  })));
  const [announcement, setAnnouncement] = useState("");
  const [dragging, setDragging] = useState(false);
  const jobs = useRef(new Map<string, OriginalUploadJob>());
  const controllers = useRef(new Map<string, AbortController>());
  const runs = useRef(new Map<string, Promise<void>>());
  const started = useRef(new Set<string>());
  const completed = useRef(new Set<string>());
  const itemNames = useRef(new Map<string, HTMLParagraphElement>());
  const fileInput = useRef<HTMLInputElement>(null);

  // Action buttons disappear as an item changes state; keep keyboard focus on the item.
  const focusItem = (key: string) => itemNames.current.get(key)?.focus();

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
    if (!job || !journal) return;
    started.current.add(item.key);
    const token = getToken();
    if (!token) {
      finish(item.key, item.name, { status: "failed", message: "Sign in again to resume this upload." }, "sign-in required");
      return;
    }
    const controller = new AbortController();
    controllers.current.set(item.key, controller);
    const progressFrom = new Set<ItemStatus>(["queued", ...ACTIVE]);
    update(item.key, { status: "hashing", loaded: 0, message: undefined });
    const run = withUploadLock(ownerId, job.clientRequestId, async () => {
      await runOriginalUpload(
        job, progress => update(item.key, { status: progress.phase, loaded: progress.loaded }, progressFrom),
        controller.signal, scopedTransport(token), current => journal.prepareReservation(current),
      );
      completed.current.add(item.key);
      try {
        return { cleared: journal.complete(item.key), error: null };
      } catch (error) {
        return { cleared: true, error: errorMessage(error) };
      }
    }).then(result => {
      if (!result.cleared) return;
      if (!result.error) {
        finish(item.key, item.name, { status: "done", loaded: item.size }, "stored");
      } else {
        const message = `Stored, but recovery data could not be cleared: ${result.error}`;
        finish(item.key, item.name, { status: "done", loaded: item.size, message }, message);
      }
      void queryClient.invalidateQueries({ queryKey: ["my-assets"] });
    }, error => {
      if (controller.signal.aborted) return;
      if (error instanceof UploadFileMismatchError) {
        jobs.current.delete(item.key);
        started.current.delete(item.key);
        finish(item.key, item.name, { status: "needs-file", loaded: 0, message: error.message }, error.message);
      } else {
        finish(item.key, item.name, { status: "failed", message: errorMessage(error) }, `failed: ${errorMessage(error)}`);
      }
    }).finally(() => {
      controllers.current.delete(item.key);
      runs.current.delete(item.key);
    });
    runs.current.set(item.key, run);
  }, [finish, journal, ownerId, queryClient, update]);

  useEffect(() => {
    if (items.some(item => ACTIVE.has(item.status))) return;
    const next = items.find(item => item.status === "queued" && !started.current.has(item.key));
    if (next) start(next);
  }, [items, start]);

  useEffect(() => {
    const busy = items.some(item => {
      if (item.status === "queued" || item.status === "cancelling" || ACTIVE.has(item.status)) return true;
      try {
        return !!journal?.get(item.key)?.reservationRequested;
      } catch {
        return true;
      }
    });
    if (!busy) return;
    const warn = (event: BeforeUnloadEvent) => event.preventDefault();
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [items, journal]);

  useEffect(() => {
    const active = controllers.current;
    return () => active.forEach(controller => controller.abort());
  }, []);

  function addFiles(files: FileList | null) {
    if (!files?.length || !journal) return;
    const added = Array.from(files, (file): UploadItem => {
      const key = crypto.randomUUID();
      const invalid = validateOriginalFile(file);
      if (invalid) {
        return { key, name: file.name, size: file.size, loaded: 0, status: "invalid", message: invalid };
      }
      try {
        journal.add({
          clientRequestId: key, fileName: file.name, sizeBytes: file.size, expectedSha256: null,
          reservationRequested: false, cancellationRequested: false,
        });
        jobs.current.set(key, { clientRequestId: key, file });
      } catch (error) {
        return {
          key, name: file.name, size: file.size, loaded: 0, status: "invalid",
          message: `Could not save this upload: ${errorMessage(error)}`,
        };
      }
      return {
        key, name: file.name, size: file.size, loaded: 0, status: "queued",
      };
    });
    setItems(current => [...current, ...added]);
  }

  function chooseRecoveryFile(item: UploadItem, file: File | undefined) {
    if (!file || !journal) return;
    let entry: UploadJournalEntry | undefined;
    try {
      entry = journal.get(item.key);
      if (!entry) throw new Error("Upload recovery data is no longer available. Refresh My Videos.");
    } catch (error) {
      finish(item.key, item.name, { message: errorMessage(error) }, errorMessage(error));
      return;
    }
    if (entry.cancellationRequested) {
      const message = "Cancellation is pending. Finish cancelling before starting another upload.";
      finish(item.key, item.name, { status: "cancellation-pending", message }, message);
      return;
    }
    const invalid = validateOriginalFile(file);
    const differentName = !entry.expectedSha256 && file.name !== entry.fileName;
    if (invalid || file.size !== entry.sizeBytes || differentName) {
      const message = invalid || (differentName
        ? "This file was not checked before the interruption. Choose the file with the original name."
        : "The selected file has a different size. Choose the original file.");
      finish(item.key, item.name, { message }, message);
      return;
    }
    jobs.current.set(item.key, {
      clientRequestId: entry.clientRequestId, file, originalFileName: entry.fileName,
      reservationRequested: entry.reservationRequested,
    });
    started.current.delete(item.key);
    update(item.key, { status: "queued", loaded: 0, message: undefined });
    focusItem(item.key);
  }

  async function cancel(item: UploadItem) {
    if (!journal) return;
    const token = getToken();
    controllers.current.get(item.key)?.abort();
    update(item.key, { status: "cancelling", message: undefined });
    focusItem(item.key);
    await runs.current.get(item.key);
    try {
      const outcome = await withUploadLock(ownerId, item.key, async () => {
        const entry = journal.get(item.key);
        if (!entry) {
          if (completed.current.has(item.key)) return "retained";
          throw new Error("Upload recovery data is no longer available. Refresh My Videos.");
        }
        journal.requestCancellation(item.key);
        if (!entry.reservationRequested) {
          journal.remove(item.key);
          return "unsent";
        }
        if (!token) throw new Error("Sign in again to finish cancelling this upload.");
        const { retainedSessions } = await cancelOriginalUpload(entry.clientRequestId, scopedTransport(token));
        journal.remove(item.key);
        return retainedSessions ? "retained" : "cancelled";
      });
      const message = outcome === "retained"
        ? "The original had already been stored and is retained."
        : outcome === "unsent" ? "Nothing was sent to the server." : "Unfinished parts were removed from the server.";
      finish(item.key, item.name, { status: "cancelled", message }, `cancelled. ${message}`);
      if (outcome === "retained") void queryClient.invalidateQueries({ queryKey: ["my-assets"] });
    } catch (error) {
      finish(item.key, item.name,
        { status: "failed", message: `Could not cancel: ${errorMessage(error)}` },
        `could not cancel: ${errorMessage(error)}`);
    }
  }

  function retry(item: UploadItem) {
    try {
      if (journal?.get(item.key)?.cancellationRequested) {
        void cancel(item);
        return;
      }
    } catch (error) {
      finish(item.key, item.name, { status: "failed", message: errorMessage(error) }, errorMessage(error));
      return;
    }
    started.current.delete(item.key);
    update(item.key, { status: "queued", message: undefined });
    focusItem(item.key);
  }

  async function remove(item: UploadItem) {
    try {
      if (journal?.get(item.key)) {
        await withUploadLock(ownerId, item.key, async () => {
          const entry = journal.get(item.key);
          if (!entry) throw new Error("Upload recovery data is no longer available. Refresh My Videos.");
          if (entry.cancellationRequested || (entry.reservationRequested && !completed.current.has(item.key))) {
            throw new Error("Cancel the server upload before removing its recovery data.");
          }
          journal.remove(item.key);
        });
      }
    } catch (error) {
      const message = `Could not remove recovery data: ${errorMessage(error)}`;
      finish(item.key, item.name, { message }, message);
      return;
    }
    jobs.current.delete(item.key);
    started.current.delete(item.key);
    completed.current.delete(item.key);
    itemNames.current.delete(item.key);
    setItems(current => current.filter(entry => entry.key !== item.key));
    fileInput.current?.focus();
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
        Leaving or reloading stops uploads; return and choose the same file to resume. This browser stores
        file names, sizes and checksums until finished or cancelled, not video bytes. Others using this
        browser profile may see them. Clearing browser data removes recovery information.
      </p>
      {recovery.error && <p role="alert" className="mb-4 text-(length:--text-xs)">{recovery.error}</p>}
      <div
        onDragOver={event => { event.preventDefault(); if (journal) setDragging(true); }}
        onDragLeave={() => setDragging(false)}
        onDrop={onDrop}
        className={`rounded-(--radius-md) border-2 border-dashed p-6 text-center focus-within:outline-2 focus-within:outline-(--foreground) ${dragging ? "border-(--foreground) bg-(--card-hover)" : "border-(--border)"}`}
      >
        <label className="cursor-pointer text-(length:--text-sm)">
          <span className="font-semibold underline">Choose video files</span> or drop them here
          <input
            ref={fileInput}
            type="file"
            accept="video/*"
            multiple
            disabled={!journal}
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
            let entry: UploadJournalEntry | undefined;
            let entryError: string | undefined;
            try {
              entry = journal?.get(item.key);
            } catch (error) {
              entryError = errorMessage(error);
            }
            const pendingCancellation = !!entry?.cancellationRequested;
            const canCancel = item.status === "queued" || ACTIVE.has(item.status)
              || item.status === "needs-file" || item.status === "cancellation-pending"
              || (pendingCancellation && item.status === "done")
              || (item.status === "failed" && !!entry);
            const canRemove = item.status === "done" || item.status === "cancelled" || item.status === "invalid"
              || (item.status === "failed" && !entry?.reservationRequested && !pendingCancellation);
            return (
              <li key={item.key} className="border-b border-(--border-subtle) pb-3 last:border-b-0">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <p
                    ref={element => {
                      if (element) itemNames.current.set(item.key, element);
                    }}
                    tabIndex={-1}
                    className="min-w-0 truncate text-(length:--text-sm) font-semibold"
                  >
                    {item.name}
                  </p>
                  <div className="flex gap-2">
                    {!entryError && item.status === "needs-file" && !pendingCancellation && (
                      <label className={`${buttonClass} cursor-pointer`}>
                        Choose file
                        <input
                          type="file"
                          accept="video/*"
                          aria-label={`Choose the original file for ${item.name}`}
                          className="sr-only"
                          onChange={event => {
                            chooseRecoveryFile(item, event.currentTarget.files?.[0]);
                            event.currentTarget.value = "";
                          }}
                        />
                      </label>
                    )}
                    {!entryError && item.status === "failed" && (job || pendingCancellation) && (
                      <button type="button" className={buttonClass} onClick={() => retry(item)}
                        aria-label={`${pendingCancellation ? "Retry cancellation of" : "Retry"} ${item.name}`}>
                        {pendingCancellation ? "Retry cancellation" : "Retry"}
                      </button>
                    )}
                    {!entryError && canCancel && !(item.status === "failed" && pendingCancellation) && (
                      <button type="button" className={buttonClass} onClick={() => void cancel(item)}
                        aria-label={`${pendingCancellation ? "Finish cancelling" : "Cancel"} ${item.name}`}>
                        {pendingCancellation ? "Finish cancelling" : "Cancel"}
                      </button>
                    )}
                    {!entryError && canRemove && (
                      <button type="button" className={buttonClass} onClick={() => void remove(item)} aria-label={`Remove ${item.name}`}>
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
                {item.status === "needs-file" && entry && !entry.expectedSha256 && !pendingCancellation && (
                  <p className="mt-1 text-(length:--text-xs)">
                    This file was not checked before the interruption. Verify your selection before starting.
                  </p>
                )}
                {item.message && (
                  <p role={item.status === "failed" || item.status === "needs-file" || item.status === "invalid" ? "alert" : undefined} className="mt-1 text-(length:--text-xs)">
                    {item.message}
                  </p>
                )}
                {entryError && <p role="alert" className="mt-1 text-(length:--text-xs)">{entryError}</p>}
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
