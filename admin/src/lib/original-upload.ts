import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex } from "@noble/hashes/utils.js";
import { api, ApiError } from "./api";

export const MAX_ORIGINAL_UPLOAD_BYTES = 500 * 1024 * 1024;
const HASH_CHUNK_BYTES = 8 * 1024 * 1024;
const PART_ATTEMPTS = 4;
const RETRY_BASE_DELAY_MS = 1_000;

export type UploadPhase = "hashing" | "reserving" | "uploading" | "verifying";

export interface UploadProgress {
  phase: UploadPhase;
  loaded: number;
  total: number;
}

interface ReservedAsset {
  id: string;
}

interface UploadSession {
  id: string;
  status: "OPEN" | "COMPLETING" | "COMPLETED" | "ABORTED" | "EXPIRED";
  partSizeBytes: number;
  partCount: number | null;
  parts: { partNumber: number; sizeBytes: string }[];
}

interface SignedPart {
  url: string;
  sizeBytes: number;
}

interface SessionPage {
  sessionIds: string[];
  nextCursor: string | null;
}

export type PutPart = (
  url: string,
  body: Blob,
  onProgress: (loaded: number) => void,
  signal: AbortSignal,
) => Promise<void>;

export interface UploadTransport {
  request<T>(method: string, path: string, body?: unknown): Promise<T>;
  putPart: PutPart;
  sleep(ms: number, signal: AbortSignal): Promise<void>;
}

/** Retry-safe state for one file. Reusing it after a failure resumes the same reservation. */
export interface OriginalUploadJob {
  clientRequestId: string;
  file: File;
  sha256?: string;
  assetId?: string;
  /** Once set, the server may hold a reservation that only cancellation can fence. */
  reservationRequested?: boolean;
}

export interface CancellationResult {
  /** Sessions already stored or finishing, which cannot be recalled. */
  retainedSessions: number;
}

export class UploadAbortedError extends Error {
  constructor() {
    super("Upload stopped");
    this.name = "UploadAbortedError";
  }
}

function throwIfAborted(signal: AbortSignal) {
  if (signal.aborted) throw new UploadAbortedError();
}

export function validateOriginalFile(file: File): string | null {
  if (file.size === 0) return "The file is empty.";
  if (file.size > MAX_ORIGINAL_UPLOAD_BYTES) return "Files larger than 500 MiB cannot be uploaded.";
  return null;
}

export async function hashFile(
  file: Blob,
  onProgress: (loaded: number) => void,
  signal: AbortSignal,
): Promise<string> {
  const hash = sha256.create();
  for (let offset = 0; offset < file.size; offset += HASH_CHUNK_BYTES) {
    throwIfAborted(signal);
    const chunk = await file.slice(offset, offset + HASH_CHUNK_BYTES).arrayBuffer();
    hash.update(new Uint8Array(chunk));
    onProgress(Math.min(offset + HASH_CHUNK_BYTES, file.size));
  }
  return bytesToHex(hash.digest());
}

export const xhrPutPart: PutPart = (url, body, onProgress, signal) => new Promise((resolve, reject) => {
  const xhr = new XMLHttpRequest();
  const onAbort = () => xhr.abort();
  const finish = (error?: Error) => {
    signal.removeEventListener("abort", onAbort);
    if (error) reject(error);
    else resolve();
  };
  xhr.open("PUT", url);
  xhr.setRequestHeader("Content-Type", "application/octet-stream");
  xhr.upload.onprogress = event => onProgress(event.loaded);
  xhr.onload = () => {
    if (xhr.status >= 200 && xhr.status < 300) return finish();
    let message = `HTTP ${xhr.status}`;
    try {
      const parsed = JSON.parse(xhr.responseText) as { error?: string };
      if (parsed.error) message = parsed.error;
    } catch { /* keep the status message */ }
    finish(new ApiError(message, xhr.status));
  };
  xhr.onerror = () => finish(new Error("Network error while uploading"));
  xhr.onabort = () => finish(new UploadAbortedError());
  signal.addEventListener("abort", onAbort, { once: true });
  xhr.send(body);
});

function abortableSleep(ms: number, signal: AbortSignal) {
  return new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new UploadAbortedError());
    };
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

export const browserTransport: UploadTransport = {
  request: api,
  putPart: xhrPutPart,
  sleep: abortableSleep,
};

/** Network failures, rate limits, server errors, and expired part URLs are worth retrying. */
function isTransient(error: unknown) {
  if (error instanceof UploadAbortedError) return false;
  if (!(error instanceof ApiError)) return true;
  return error.status === 403 || error.status === 408 || error.status === 429 || error.status >= 500;
}

async function uploadPart(
  transport: UploadTransport,
  session: UploadSession,
  partNumber: number,
  file: File,
  onPartProgress: (loaded: number) => void,
  signal: AbortSignal,
) {
  const start = (partNumber - 1) * session.partSizeBytes;
  for (let attempt = 1; ; attempt += 1) {
    throwIfAborted(signal);
    try {
      // A fresh signature per attempt: part URLs expire within minutes.
      const signed = await transport.request<SignedPart>(
        "POST", `/api/upload-sessions/${session.id}/parts/${partNumber}/sign`);
      await transport.putPart(signed.url, file.slice(start, start + signed.sizeBytes), onPartProgress, signal);
      return;
    } catch (error) {
      onPartProgress(0);
      if (attempt >= PART_ATTEMPTS || !isTransient(error)) throw error;
      await transport.sleep(RETRY_BASE_DELAY_MS * 2 ** (attempt - 1), signal);
    }
  }
}

export async function runOriginalUpload(
  job: OriginalUploadJob,
  onProgress: (progress: UploadProgress) => void,
  signal: AbortSignal,
  transport: UploadTransport = browserTransport,
): Promise<void> {
  const { file } = job;
  const total = file.size;
  if (!job.sha256) {
    onProgress({ phase: "hashing", loaded: 0, total });
    job.sha256 = await hashFile(file, loaded => onProgress({ phase: "hashing", loaded, total }), signal);
  }
  throwIfAborted(signal);

  onProgress({ phase: "reserving", loaded: 0, total });
  const expected = { expectedSizeBytes: String(total), expectedSha256: job.sha256 };
  if (!job.assetId) {
    job.reservationRequested = true;
    const { asset } = await transport.request<{ asset: ReservedAsset }>("POST", "/api/assets/original-uploads", {
      clientRequestId: job.clientRequestId,
      fileName: file.name || null,
      ...expected,
      uploadSource: "WEB",
    });
    job.assetId = asset.id;
  }
  throwIfAborted(signal);
  let { uploadSession: session } = await transport.request<{ uploadSession: UploadSession }>(
    "POST", `/api/assets/${job.assetId}/upload-sessions`, expected);

  if (session.status === "OPEN") {
    const received = new Map(session.parts.map(part => [part.partNumber, Number(part.sizeBytes)]));
    let stored = [...received.values()].reduce((sum, size) => sum + size, 0);
    onProgress({ phase: "uploading", loaded: stored, total });
    for (let partNumber = 1; partNumber <= (session.partCount ?? 0); partNumber += 1) {
      if (received.has(partNumber)) continue;
      const before = stored;
      await uploadPart(transport, session, partNumber, file,
        loaded => onProgress({ phase: "uploading", loaded: before + loaded, total }), signal);
      stored = Math.min(total, before + session.partSizeBytes);
      onProgress({ phase: "uploading", loaded: stored, total });
    }
  }

  if (session.status !== "COMPLETED") {
    throwIfAborted(signal);
    onProgress({ phase: "verifying", loaded: total, total });
    ({ uploadSession: session } = await transport.request<{ uploadSession: UploadSession }>(
      "POST", `/api/upload-sessions/${session.id}/complete`));
  }
  if (session.status !== "COMPLETED") {
    throw new Error("The server did not confirm the upload.");
  }
}

/**
 * Fence the reservation server-side, then abort every session it owns. The
 * server rejects new sessions once the intent is cancelled, so paging after
 * the fence sees a stable set. Stored originals cannot be recalled.
 */
export async function cancelOriginalUpload(
  clientRequestId: string,
  transport: Pick<UploadTransport, "request"> = browserTransport,
): Promise<CancellationResult> {
  const id = encodeURIComponent(clientRequestId);
  await transport.request("POST", `/api/assets/original-uploads/${id}/cancel`);
  let retainedSessions = 0;
  let cursor: string | null = null;
  do {
    const query: string = cursor ? `?after=${encodeURIComponent(cursor)}` : "";
    const page: SessionPage = await transport.request<SessionPage>(
      "GET", `/api/assets/original-uploads/${id}/sessions${query}`);
    for (const sessionId of page.sessionIds) {
      try {
        await transport.request("DELETE", `/api/upload-sessions/${encodeURIComponent(sessionId)}`);
      } catch (error) {
        if (!(error instanceof ApiError) || error.status !== 409) throw error;
        retainedSessions += 1;
      }
    }
    cursor = page.nextCursor;
  } while (cursor);
  return { retainedSessions };
}
