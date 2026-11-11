// @vitest-environment node
import { describe, expect, it, vi } from "vitest";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex } from "@noble/hashes/utils.js";
import { ApiError } from "@/lib/api";
import {
  cancelOriginalUpload,
  hashFile,
  runOriginalUpload,
  validateOriginalFile,
  type OriginalUploadJob,
  type UploadProgress,
  type UploadTransport,
} from "@/lib/original-upload";

const PART = 4;
const ASSET_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const REQUEST_ID = "33333333-3333-4333-8333-333333333333";

function makeFile(text: string) {
  return new File([text], "clip.mov", { type: "video/quicktime" });
}

function session(status: string, size: number, received: number[] = []) {
  return {
    uploadSession: {
      id: SESSION_ID,
      status,
      partSizeBytes: PART,
      partCount: Math.ceil(size / PART),
      parts: received.map(partNumber => ({ partNumber, sizeBytes: String(PART) })),
    },
  };
}

function fakeTransport(routes: (method: string, path: string, body?: unknown) => unknown) {
  const calls: { method: string; path: string; body?: unknown }[] = [];
  const puts: { url: string; text: string }[] = [];
  const transport: UploadTransport & { failPuts: number } = {
    failPuts: 0,
    request: async <T,>(method: string, path: string, body?: unknown) => {
      calls.push({ method, path, body });
      const result = routes(method, path, body);
      if (result instanceof Error) throw result;
      return result as T;
    },
    putPart: async (url, blob, onProgress) => {
      if (transport.failPuts > 0) {
        transport.failPuts -= 1;
        throw new ApiError("Invalid or expired upload URL", 403);
      }
      puts.push({ url, text: await blob.text() });
      onProgress(blob.size);
    },
    sleep: vi.fn(async () => {}),
  };
  return { transport, calls, puts };
}

function uploadRoutes(file: File, received: number[] = []) {
  return (method: string, path: string) => {
    if (path === "/api/assets/original-uploads") return { asset: { id: ASSET_ID } };
    if (path === `/api/assets/${ASSET_ID}/upload-sessions`) return session("OPEN", file.size, received);
    const sign = path.match(/parts\/(\d+)\/sign$/);
    if (sign) {
      const partNumber = Number(sign[1]);
      return { url: `/put/${partNumber}`, sizeBytes: Math.min(PART, file.size - (partNumber - 1) * PART) };
    }
    if (path.endsWith("/complete")) return session("COMPLETED", file.size, [1, 2, 3]);
    throw new Error(`Unexpected ${method} ${path}`);
  };
}

describe("original upload client", () => {
  it("rejects empty and oversized files", () => {
    expect(validateOriginalFile(makeFile(""))).toMatch(/empty/);
    const huge = makeFile("x");
    Object.defineProperty(huge, "size", { value: 500 * 1024 * 1024 + 1 });
    expect(validateOriginalFile(huge)).toMatch(/500 MiB/);
    expect(validateOriginalFile(makeFile("ok"))).toBeNull();
  });

  it("hashes the whole file incrementally", async () => {
    const text = "store-first original";
    const digest = await hashFile(makeFile(text), () => {}, new AbortController().signal);
    expect(digest).toBe(bytesToHex(sha256(new TextEncoder().encode(text))));
  });

  it("reserves, uploads each part from the file, and verifies the original", async () => {
    const file = makeFile("abcdefghij");
    const { transport, calls, puts } = fakeTransport(uploadRoutes(file));
    const job: OriginalUploadJob = { clientRequestId: REQUEST_ID, file };
    const phases: UploadProgress[] = [];

    await runOriginalUpload(job, progress => phases.push(progress), new AbortController().signal, transport);

    expect(calls[0]).toEqual({
      method: "POST",
      path: "/api/assets/original-uploads",
      body: {
        clientRequestId: REQUEST_ID,
        fileName: "clip.mov",
        expectedSizeBytes: "10",
        expectedSha256: bytesToHex(sha256(new TextEncoder().encode("abcdefghij"))),
        uploadSource: "WEB",
      },
    });
    expect(puts).toEqual([
      { url: "/put/1", text: "abcd" },
      { url: "/put/2", text: "efgh" },
      { url: "/put/3", text: "ij" },
    ]);
    expect(calls[calls.length - 1]).toMatchObject({ method: "POST", path: `/api/upload-sessions/${SESSION_ID}/complete` });
    expect(phases.map(progress => progress.phase)).toEqual(
      expect.arrayContaining(["hashing", "reserving", "uploading", "verifying"]));
    expect(job.assetId).toBe(ASSET_ID);
    expect(job.reservationRequested).toBe(true);
  });

  it("resumes by skipping parts the server already stored", async () => {
    const file = makeFile("abcdefghij");
    const { transport, calls, puts } = fakeTransport(uploadRoutes(file, [1, 2]));
    const job: OriginalUploadJob = { clientRequestId: REQUEST_ID, file, sha256: "a".repeat(64), assetId: ASSET_ID };

    await runOriginalUpload(job, () => {}, new AbortController().signal, transport);

    expect(calls.some(call => call.path === "/api/assets/original-uploads")).toBe(false);
    expect(puts).toEqual([{ url: "/put/3", text: "ij" }]);
  });

  it("re-signs and retries a part after an expired URL", async () => {
    const file = makeFile("abcd");
    const { transport, calls, puts } = fakeTransport(uploadRoutes(file));
    transport.failPuts = 2;

    await runOriginalUpload({ clientRequestId: REQUEST_ID, file }, () => {}, new AbortController().signal, transport);

    expect(calls.filter(call => call.path.endsWith("/parts/1/sign"))).toHaveLength(3);
    expect(transport.sleep).toHaveBeenCalledTimes(2);
    expect(puts).toHaveLength(1);
  });

  it("does not retry a rejected part", async () => {
    const file = makeFile("abcd");
    const routes = uploadRoutes(file);
    const { transport, calls } = fakeTransport((method, path) => path.endsWith("/sign")
      ? new ApiError("Upload session is not open", 409)
      : routes(method, path));

    await expect(runOriginalUpload(
      { clientRequestId: REQUEST_ID, file }, () => {}, new AbortController().signal, transport,
    )).rejects.toThrow("Upload session is not open");
    expect(calls.filter(call => call.path.endsWith("/sign"))).toHaveLength(1);
    expect(transport.sleep).not.toHaveBeenCalled();
  });

  it("cancels the reservation and aborts every paged session", async () => {
    const second = "44444444-4444-4444-8444-444444444444";
    const { transport, calls } = fakeTransport((method, path) => {
      if (path.endsWith("/cancel")) return { assetId: ASSET_ID, sessionIds: [SESSION_ID] };
      if (path.endsWith("/sessions")) return { sessionIds: [SESSION_ID], nextCursor: SESSION_ID };
      if (path.endsWith(`/sessions?after=${SESSION_ID}`)) return { sessionIds: [second], nextCursor: null };
      if (path === `/api/upload-sessions/${second}`) return new ApiError("Completed originals cannot be aborted", 409);
      return { uploadSession: { id: SESSION_ID, status: "ABORTED" } };
    });

    await expect(cancelOriginalUpload(REQUEST_ID, transport)).resolves.toEqual({ retainedSessions: 1 });
    expect(calls.map(call => `${call.method} ${call.path}`)).toEqual([
      `POST /api/assets/original-uploads/${REQUEST_ID}/cancel`,
      `GET /api/assets/original-uploads/${REQUEST_ID}/sessions`,
      `DELETE /api/upload-sessions/${SESSION_ID}`,
      `GET /api/assets/original-uploads/${REQUEST_ID}/sessions?after=${SESSION_ID}`,
      `DELETE /api/upload-sessions/${second}`,
    ]);
    expect(calls[0].body).toBeUndefined();
  });
});
