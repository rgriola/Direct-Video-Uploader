import { createLocalStorageDriver } from "./local-driver.js";

const factories = new Map();
const requiredMethods = [
  "createUpload",
  "assertStorageLocation",
  "uploadPart",
  "listParts",
  "listPartNumbers",
  "recoverUpload",
  "withCompletionLock",
  "completeUpload",
  "abortUpload",
  "getReadStream",
  "delete",
  "stat",
];

export function registerStorageDriver(name, factory) {
  if (typeof name !== "string" || !/^[a-z][a-z0-9-]*$/.test(name) || typeof factory !== "function") {
    throw new TypeError("Storage driver registration requires a valid name and factory");
  }
  if (factories.has(name)) throw new Error(`Storage driver "${name}" is already registered`);
  factories.set(name, factory);
}

export function createStorageDriver({
  provider = process.env.STORAGE_DRIVER || "local",
  ...options
} = {}) {
  const factory = factories.get(provider);
  if (!factory) throw new Error(`Storage driver "${provider}" is not registered`);

  const driver = factory(options);
  const missing = requiredMethods.filter(method => typeof driver?.[method] !== "function");
  if (missing.length > 0) {
    throw new TypeError(`Storage driver "${provider}" is missing methods: ${missing.join(", ")}`);
  }
  return driver;
}

registerStorageDriver("local", createLocalStorageDriver);
