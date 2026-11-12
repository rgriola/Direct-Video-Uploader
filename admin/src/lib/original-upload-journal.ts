import { MAX_ORIGINAL_UPLOAD_BYTES, type OriginalUploadJob } from "./original-upload";

const REQUEST_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256 = /^[0-9a-f]{64}$/;

export interface UploadJournalEntry {
  clientRequestId: string;
  fileName: string;
  sizeBytes: number;
  expectedSha256: string | null;
  reservationRequested: boolean;
  cancellationRequested: boolean;
}

export class UploadFileMismatchError extends Error {
  constructor() {
    super("The selected file does not match the original upload. Choose the original file.");
    this.name = "UploadFileMismatchError";
  }
}

function isEntry(value: unknown): value is UploadJournalEntry {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  if (!("clientRequestId" in value) || typeof value.clientRequestId !== "string"
    || !REQUEST_ID.test(value.clientRequestId)
    || !("fileName" in value) || typeof value.fileName !== "string"
    || !("sizeBytes" in value) || typeof value.sizeBytes !== "number"
    || !Number.isSafeInteger(value.sizeBytes) || value.sizeBytes <= 0
    || value.sizeBytes > MAX_ORIGINAL_UPLOAD_BYTES
    || !("expectedSha256" in value)
    || !(value.expectedSha256 === null
      || (typeof value.expectedSha256 === "string" && SHA256.test(value.expectedSha256)))
    || !("reservationRequested" in value) || typeof value.reservationRequested !== "boolean"
    || !("cancellationRequested" in value) || typeof value.cancellationRequested !== "boolean") {
    return false;
  }
  return !value.reservationRequested || value.expectedSha256 !== null;
}

export class OriginalUploadJournal {
  private readonly prefix: string;

  constructor(ownerId: string, private readonly storage: Storage) {
    this.prefix = `dvu-original-uploads:v1:${encodeURIComponent(ownerId)}:`;
  }

  entries(): UploadJournalEntry[] {
    const entries: UploadJournalEntry[] = [];
    for (let index = 0; index < this.storage.length; index += 1) {
      const key = this.storage.key(index);
      if (!key?.startsWith(this.prefix)) continue;
      const entry = this.get(key.slice(this.prefix.length));
      if (entry) entries.push(entry);
    }
    return entries;
  }

  get(id: string): UploadJournalEntry | undefined {
    let saved: string | null;
    try {
      saved = this.storage.getItem(this.prefix + id);
    } catch {
      throw new Error("Cannot read upload recovery data. Check browser storage and try again.");
    }
    if (saved === null) return undefined;
    let parsed: unknown;
    try {
      parsed = JSON.parse(saved);
    } catch {
      throw new Error("Cannot read upload recovery data. Do not clear browser storage before resolving it.");
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)
      || !("version" in parsed) || parsed.version !== 1
      || !("entry" in parsed) || !isEntry(parsed.entry) || parsed.entry.clientRequestId !== id) {
      throw new Error("Upload recovery data is invalid. Do not clear browser storage before resolving it.");
    }
    return parsed.entry;
  }

  add(entry: UploadJournalEntry): void {
    if (!isEntry(entry) || this.get(entry.clientRequestId)) {
      throw new Error("Cannot create upload recovery data.");
    }
    this.save(entry);
  }

  prepareReservation(job: OriginalUploadJob): void {
    const entry = this.require(job.clientRequestId);
    if (entry.cancellationRequested) throw new Error("This upload is waiting to be cancelled.");
    if (!job.sha256 || !SHA256.test(job.sha256) || job.file.size !== entry.sizeBytes
      || (entry.expectedSha256 !== null && entry.expectedSha256 !== job.sha256)) {
      throw new UploadFileMismatchError();
    }
    this.save({
      ...entry,
      expectedSha256: job.sha256,
      reservationRequested: true,
    });
  }

  requestCancellation(id: string): void {
    this.save({ ...this.require(id), cancellationRequested: true });
  }

  remove(id: string): void {
    this.require(id);
    try {
      this.storage.removeItem(this.prefix + id);
    } catch {
      throw new Error("Cannot remove upload recovery data. Check browser storage and try again.");
    }
  }

  complete(id: string): boolean {
    if (this.require(id).cancellationRequested) return false;
    this.remove(id);
    return true;
  }

  private require(id: string): UploadJournalEntry {
    const entry = this.get(id);
    if (!entry) throw new Error("Upload recovery data is missing.");
    return entry;
  }

  private save(entry: UploadJournalEntry): void {
    try {
      this.storage.setItem(this.prefix + entry.clientRequestId, JSON.stringify({ version: 1, entry }));
    } catch {
      throw new Error("Cannot save upload recovery data. Check browser storage and try again.");
    }
  }
}
