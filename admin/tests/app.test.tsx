import { StrictMode } from "react";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { createMemoryHistory } from "@tanstack/react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App, { createAppRouter, queryClient } from "@/App";
import { clearToken, getToken } from "@/lib/api";
import type { Asset, User } from "@/lib/types";

type SocketListener = (...args: unknown[]) => void;

interface TestSocket {
  connected: boolean;
  id: string;
  on: (event: string, listener: SocketListener) => TestSocket;
  connect: () => TestSocket;
  disconnect: () => TestSocket;
  removeAllListeners: () => TestSocket;
  emit: (...args: unknown[]) => void;
  serverEmit: (event: string, ...args: unknown[]) => void;
}

const socketHarness = vi.hoisted(() => ({ sockets: [] as TestSocket[] }));

vi.mock("socket.io-client", () => ({
  io: vi.fn(() => {
    const listeners = new Map<string, SocketListener>();
    const socket: TestSocket = {
      connected: false,
      id: "test-socket",
      on(event, listener) {
        listeners.set(event, listener);
        return socket;
      },
      connect: vi.fn(() => socket),
      disconnect: vi.fn(() => {
        socket.connected = false;
        return socket;
      }),
      removeAllListeners: vi.fn(() => {
        listeners.clear();
        return socket;
      }),
      emit: vi.fn(),
      serverEmit(event, ...args) {
        if (event === "connect") socket.connected = true;
        if (event === "disconnect") socket.connected = false;
        listeners.get(event)?.(...args);
      },
    };
    socketHarness.sockets.push(socket);
    return socket;
  }),
}));

type Role = "SUPER_ADMIN" | "ADMIN" | "USER";

function account(role: Role, companyCode: string | null = "NEWS"): User {
  return {
    id: `${role.toLowerCase()}-id`,
    name: `${role} account`,
    phoneNumber: "1234567890",
    status: "ACTIVE",
    role,
    companyCode,
    companyName: companyCode ? "News" : null,
  };
}

function video(id: string, title: string, overrides: Partial<Asset> = {}): Asset {
  return {
    id,
    status: "READY",
    moderation: "ACTIVE",
    mediaPlaybackUnavailable: false,
    mediasourceId: id,
    mediasourceUrl: `/clips/${id}`,
    clipCount: 1,
    formResponse: { id: `form-${id}`, slug: title },
    clips: [{ id: `clip-${id}`, resolution: "1920x1080" }],
    ...overrides,
  };
}

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

interface RequestRecord {
  path: string;
  options?: RequestInit;
}

let currentUser: User;
let token: string;
let tokenSequence = 0;
let myAssets: Asset[];
let originalUploads: boolean;
let adminAssets: Asset[];
let requests: RequestRecord[];
let loginResponse: () => Promise<Response>;
let meResponse: () => Promise<Response>;
let myAssetsResponse: () => Promise<Response>;
let adminAssetsResponse: () => Promise<Response>;
let testRouter: ReturnType<typeof createAppRouter>;

async function respondToRequest(input: RequestInfo | URL, options?: RequestInit): Promise<Response> {
  if (typeof input !== "string") throw new Error("Unexpected non-string request");
  requests.push({ path: input, options });

  switch (input) {
    case "/api/auth/login":
      return loginResponse();
    case "/api/auth/me":
      return meResponse();
    case "/api/assets/mine":
      return myAssetsResponse();
    case "/api/upload-capabilities":
      return jsonResponse({ originalUploads });
    case "/api/admin/stats":
      return jsonResponse({
        users: 0, activeUsers: 0, loggedInUsers: 0, onlineUsers: 0, assets: 0,
        readyAssets: 0, uploadingAssets: 0, messages: 0, clips: 0, iosClients: 0, wsConnections: 0,
      });
    case "/api/admin/users":
      return jsonResponse({ users: [] });
    case "/api/admin/assets":
      return adminAssetsResponse();
    case "/api/admin/status":
      return jsonResponse({
        triad: {
          database: { status: "ok" },
          server: { status: "ok" },
          ios: { status: "disconnected" },
          admin: { status: "connected" },
        },
        connectedUsers: 0,
        totalWsConnections: 0,
      });
    case "/api/admin/monitoring":
      return jsonResponse({ enabled: false, checkedAt: null, checks: [], stale: false });
    case "/api/admin/organizations":
      return jsonResponse({ organizations: [] });
    case "/api/admin/errors":
      return jsonResponse({ errors: [] });
    case "/api/admin/audit-logs?limit=50":
      return jsonResponse({ logs: [] });
    case "/api/admin/media-issues":
      return jsonResponse({ issues: [], hasMore: false });
    case "/clips/logout":
      return new Response(null, { status: 204 });
    default:
      throw new Error(`Unexpected request: ${input}`);
  }
}

function renderApp(path = "/") {
  testRouter = createAppRouter(createMemoryHistory({ initialEntries: [path] }));
  return render(<StrictMode><App appRouter={testRouter} /></StrictMode>);
}

async function signIn() {
  fireEvent.change(await screen.findByLabelText("Phone Number"), { target: { value: "1234567890" } });
  fireEvent.change(screen.getByLabelText("PIN"), { target: { value: "1234" } });
  fireEvent.click(screen.getByRole("button", { name: "Sign In" }));
}

function latestSocket(): TestSocket {
  const socket = socketHarness.sockets[socketHarness.sockets.length - 1];
  if (!socket) throw new Error("Expected an authenticated socket");
  return socket;
}

function requestPaths() {
  return requests.map(({ path }) => path);
}

beforeEach(() => {
  currentUser = account("USER");
  token = `test-token-${++tokenSequence}`;
  myAssets = [];
  originalUploads = false;
  adminAssets = [];
  requests = [];
  loginResponse = async () => jsonResponse({ token, user: currentUser });
  meResponse = async () => jsonResponse({ user: currentUser });
  myAssetsResponse = async () => jsonResponse({ assets: myAssets });
  adminAssetsResponse = async () => jsonResponse({ assets: adminAssets });
  socketHarness.sockets.length = 0;
  localStorage.clear();
  clearToken();
  queryClient.clear();
  queryClient.setDefaultOptions({ queries: { staleTime: 10_000, retry: false } });
  vi.stubGlobal("scrollTo", vi.fn());
  vi.stubGlobal("fetch", vi.fn(respondToRequest));
});

afterEach(() => {
  const logout = screen.queryByRole("button", { name: "Log out" });
  if (logout) fireEvent.click(logout);
  cleanup();
  queryClient.clear();
  clearToken();
  vi.unstubAllGlobals();
});

describe("role-separated web application", () => {
  it("signs a user in with the existing phone and PIN policy and shows only their videos", async () => {
    myAssets = [
      video("10001", "Ready story"),
      video("10002", "Paused story", { moderation: "PAUSED", mediaPlaybackUnavailable: true }),
      video("10003", "Unavailable story", { mediaPlaybackUnavailable: true, mediaSyncState: "ERROR" }),
      video("10004", "Link pending", { mediasourceId: null, mediasourceUrl: null }),
    ];
    renderApp();
    await signIn();

    await screen.findByRole("heading", { name: "My Videos" });
    expect(testRouter.state.location.pathname).toBe("/videos");
    const loginRequest = requests.find(({ path }) => path === "/api/auth/login");
    expect(JSON.parse(String(loginRequest?.options?.body))).toEqual({
      phoneNumber: "1234567890", pin: "1234", clientType: "admin",
    });
    expect(localStorage.getItem("fixer_admin_token")).toBe(token);
    await screen.findByText("Ready story");
    expect(requestPaths()).toContain("/api/assets/mine");
    expect(requestPaths().filter((path) => path.startsWith("/api/admin/"))).toEqual([]);
    expect(screen.queryByRole("heading", { name: "Quick Actions" })).toBeNull();
    expect(screen.queryByText("MEDIA NEEDS ATTENTION")).toBeNull();
    expect(requestPaths()).toContain("/api/upload-capabilities");
    expect(screen.queryByRole("heading", { name: "Upload originals" })).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: /Ready story/ }));
    expect(screen.getByRole("link", { name: /Play Clip/ }).getAttribute("href")).toBe("/clips/10001");
    fireEvent.click(screen.getByRole("button", { name: /Paused story/ }));
    expect(screen.getByText("Playback disabled while paused")).toBeTruthy();
    expect(screen.queryByRole("link", { name: /Play Clip/ })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: /Unavailable story/ }));
    expect(screen.getByText("Playback is temporarily unavailable")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: /Link pending/ }));
    expect(screen.getByText("Clip link is not available yet")).toBeTruthy();
  });

  it("offers original uploads only when the server enables them", async () => {
    originalUploads = true;
    renderApp();
    await signIn();

    expect(await screen.findByRole("heading", { name: "Upload originals" })).toBeTruthy();
    expect(screen.getByLabelText(/Choose video files/)).toBeTruthy();
  });

  it.each([
    ["SUPER_ADMIN", "/super", "Triad Status"],
    ["ADMIN", "/team", "Quick Actions"],
    ["USER", "/videos", "My Videos"],
  ] as const)("routes %s to %s", async (role, path, heading) => {
    currentUser = account(role);
    renderApp();
    await signIn();

    await screen.findByRole("heading", { name: heading });
    expect(testRouter.state.location.pathname).toBe(path);
    if (role === "SUPER_ADMIN") {
      expect(screen.getByRole("heading", { name: "Storage & Backup Monitoring" })).toBeTruthy();
      expect(screen.getByRole("heading", { name: /Organizations/ })).toBeTruthy();
      expect(screen.getByRole("heading", { name: /Moderation Audit/ })).toBeTruthy();
      expect(screen.getByRole("heading", { name: "Error Log 0" })).toBeTruthy();
    } else if (role === "ADMIN") {
      expect(screen.getByRole("heading", { name: "Admin Tools" })).toBeTruthy();
      expect(screen.queryByRole("heading", { name: "Triad Status" })).toBeNull();
      expect(screen.queryByRole("heading", { name: "Storage & Backup Monitoring" })).toBeNull();
      expect(screen.queryByRole("heading", { name: /Moderation Audit/ })).toBeNull();
      expect(requestPaths()).not.toContain("/api/admin/status");
      expect(requestPaths()).not.toContain("/api/admin/monitoring");
      expect(requestPaths()).not.toContain("/api/admin/errors");
      expect(requestPaths()).not.toContain("/api/admin/media-issues");
    }
  });

  it("warns an unassigned team admin and does not expose team-management controls", async () => {
    currentUser = account("ADMIN", null);
    renderApp();
    await signIn();

    await screen.findByRole("alert");
    expect(screen.getByText(/needs an organization/)).toBeTruthy();
    expect(screen.queryByRole("heading", { name: "Admin Tools" })).toBeNull();
    expect(requestPaths()).not.toContain("/api/admin/organizations");
  });

  it("reports invalid credentials without starting an authenticated session", async () => {
    loginResponse = async () => jsonResponse({ error: "Invalid credentials" }, 401);
    renderApp();
    await signIn();

    await screen.findByRole("alert");
    expect(screen.getByText("Invalid credentials")).toBeTruthy();
    expect(getToken()).toBeNull();
    expect(localStorage.getItem("fixer_admin_token")).toBeNull();
    expect(socketHarness.sockets).toHaveLength(0);
    expect(requestPaths()).not.toContain("/api/assets/mine");
  });

  it.each([
    ["USER", "/super"],
    ["USER", "/team"],
    ["ADMIN", "/super"],
    ["SUPER_ADMIN", "/team"],
    ["SUPER_ADMIN", "/videos"],
  ] as const)("denies %s direct access to %s without mounting another role's queries", async (role, path) => {
    currentUser = account(role);
    renderApp(path);
    await signIn();

    await screen.findByRole("heading", { name: "Access denied" });
    expect(testRouter.state.location.pathname).toBe(path);
    expect(requestPaths().filter((requestPath) => requestPath.startsWith("/api/admin/"))).toEqual([]);
    expect(requestPaths()).not.toContain("/api/assets/mine");
    fireEvent.click(screen.getByRole("link", { name: "Go to your dashboard" }));
    await screen.findByRole("heading", { name: role === "USER" ? "My Videos" : "Quick Actions" });
  });

  it("shows a 404 for an unknown route and links back to the role home", async () => {
    renderApp("/does-not-exist");
    await signIn();

    await screen.findByRole("heading", { name: "Page not found" });
    expect(requestPaths()).not.toContain("/api/assets/mine");
    fireEvent.click(screen.getByRole("link", { name: "Go to your dashboard" }));
    await screen.findByRole("heading", { name: "My Videos" });
    expect(testRouter.state.location.pathname).toBe("/videos");
  });

  it("opens a hash deep link with the production history", async () => {
    window.history.replaceState(null, "", "/#/videos");
    testRouter = createAppRouter();
    render(<StrictMode><App appRouter={testRouter} /></StrictMode>);
    await signIn();

    await screen.findByRole("heading", { name: "My Videos" });
    expect(window.location.hash).toBe("#/videos");
    await waitFor(() => expect(requestPaths()).toContain("/api/assets/mine"));
  });

  it("restores a saved session before rendering the matching role", async () => {
    const response = deferred<Response>();
    meResponse = async () => (await response.promise).clone();
    localStorage.setItem("fixer_admin_token", token);
    renderApp();

    await screen.findByText("Restoring your session...");
    expect(screen.queryByRole("button", { name: "Sign In" })).toBeNull();
    await act(async () => response.resolve(jsonResponse({ user: account("USER") })));

    await screen.findByRole("heading", { name: "My Videos" });
    const profileRequest = requests.find(({ path }) => path === "/api/auth/me");
    expect(new Headers(profileRequest?.options?.headers).get("Authorization")).toBe(`Bearer ${token}`);
    expect(getToken()).toBe(token);
  });

  it.each([
    [401, "Unauthorized", false],
    [503, "Temporarily unavailable", true],
  ] as const)("handles a %s session restoration error", async (status, error, retainToken) => {
    localStorage.setItem("fixer_admin_token", token);
    meResponse = async () => jsonResponse({ error }, status);
    renderApp();

    await screen.findByRole("button", { name: "Sign In" });
    expect(localStorage.getItem("fixer_admin_token")).toBe(retainToken ? token : null);
    expect(getToken()).toBe(retainToken ? token : null);
    await screen.findByText(retainToken
      ? "Could not restore your session. Check the connection and sign in again."
      : "Your session expired or your account is unavailable. Sign in again.");
  });

  it("clears the token, socket, cached data and clip session on logout", async () => {
    myAssets = [video("10001", "Private story")];
    renderApp();
    await signIn();
    await screen.findByText("Private story");
    const socket = latestSocket();

    fireEvent.click(screen.getByRole("button", { name: "Log out" }));

    await screen.findByRole("button", { name: "Sign In" });
    await waitFor(() => expect(testRouter.state.location.pathname).toBe("/"));
    expect(localStorage.getItem("fixer_admin_token")).toBeNull();
    expect(getToken()).toBeNull();
    expect(queryClient.getQueryCache().getAll()).toHaveLength(0);
    expect(socket.disconnect).toHaveBeenCalled();
    expect(requestPaths()).toContain("/clips/logout");
    expect(screen.queryByText("Private story")).toBeNull();
  });

  it("shows video loading failures and retries without presenting an empty-success state", async () => {
    myAssetsResponse = async () => jsonResponse({ error: "Videos temporarily unavailable" }, 503);
    renderApp();
    await signIn();

    await screen.findByText("Could not load your videos: Videos temporarily unavailable");
    expect(screen.queryByText("Your uploaded videos will appear here.")).toBeNull();
    myAssets = [video("10001", "Recovered story")];
    myAssetsResponse = async () => jsonResponse({ assets: myAssets });
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    await screen.findByText("Recovered story");
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("refreshes the owner's videos for upload, ready and form events", async () => {
    myAssets = [video("10001", "Initial story")];
    renderApp();
    await signIn();
    await screen.findByText("Initial story");
    const socket = latestSocket();
    act(() => socket.serverEmit("connect"));

    for (const [event, title] of [
      ["upload:complete", "Uploaded story"],
      ["mux:ready", "Ready story"],
      ["form:confirmed", "Form story"],
      ["dashboard:asset-changed", "Changed story"],
    ] as const) {
      myAssets = [video("10001", title)];
      act(() => socket.serverEmit(event, { assetId: "10001", message: "Confirmed" }));
      await screen.findByText(title);
    }
    expect(requestPaths().filter((path) => path === "/api/assets/mine").length).toBeGreaterThanOrEqual(5);
  });

  it.each([
    ["USER", "/api/assets/mine", ["upload:complete", "mux:ready"]],
    ["ADMIN", "/api/admin/assets", ["dashboard:asset-changed"]],
    ["SUPER_ADMIN", "/api/admin/assets", ["dashboard:asset-changed"]],
  ] as const)("refreshes %s thumbnails from scoped socket events", async (role, path, events) => {
    currentUser = account(role);
    const initial = video("10001", "Live thumbnail story", { status: "PROCESSING" });
    if (role === "USER") myAssets = [initial];
    else adminAssets = [initial];
    renderApp();
    await signIn();
    await screen.findByText("Live thumbnail story");
    const row = () => {
      const button = screen.getByText("Live thumbnail story").closest("button");
      if (!button) throw new Error("Expected the video row");
      return button;
    };
    expect(row().querySelector("img")).toBeNull();
    const socket = latestSocket();
    act(() => socket.serverEmit("connect"));

    for (const [index, event] of events.entries()) {
      const playbackId = `playback-${index}`;
      const ready = video("10001", "Live thumbnail story", {
        clips: [{ id: "clip-10001", thumbnailUrl: `https://image.mux.com/${playbackId}/thumbnail.png?width=640` }],
      });
      if (role === "USER") myAssets = [ready];
      else adminAssets = [ready];
      act(() => socket.serverEmit(event, { assetId: "10001" }));
      await waitFor(() => expect(row().querySelector("img")?.getAttribute("src"))
        .toBe(`https://image.mux.com/${playbackId}/thumbnail.webp?width=320&fit_mode=smartcrop`));
    }

    const paused = video("10001", "Live thumbnail story", {
      moderation: "PAUSED",
      mediaPlaybackUnavailable: true,
      clips: [{ id: "clip-10001", thumbnailUrl: "https://image.mux.com/stale/thumbnail.png" }],
    });
    if (role === "USER") myAssets = [paused];
    else adminAssets = [paused];
    act(() => socket.serverEmit(role === "USER" ? "mux:ready" : "dashboard:asset-changed", { assetId: "10001" }));
    await screen.findByText("Paused");
    expect(row().querySelector("img")).toBeNull();
    expect(requestPaths().filter((requestPath) => requestPath === path).length)
      .toBeGreaterThanOrEqual(events.length + 2);
  });

  it("clears privileged data while reconnecting and enforces a changed role", async () => {
    currentUser = account("SUPER_ADMIN");
    adminAssets = [video("10001", "Super-only story")];
    myAssets = [video("20001", "My own story")];
    renderApp();
    await signIn();
    await screen.findByText("Super-only story");
    const socket = latestSocket();
    act(() => socket.serverEmit("connect"));
    currentUser = account("USER");

    act(() => socket.serverEmit("disconnect", "io server disconnect"));
    expect(screen.getByText("Refreshing dashboard access...")).toBeTruthy();
    expect(screen.queryByText("Super-only story")).toBeNull();
    expect(queryClient.getQueryData(["assets", "default"])).toBeUndefined();
    const adminRequestsBeforeReconnect = requestPaths().filter((path) => path.startsWith("/api/admin/")).length;

    act(() => socket.serverEmit("connect"));
    await screen.findByRole("heading", { name: "Access denied" });
    expect(requestPaths().filter((path) => path.startsWith("/api/admin/"))).toHaveLength(adminRequestsBeforeReconnect);
    fireEvent.click(screen.getByRole("link", { name: "Go to your dashboard" }));
    await screen.findByText("My own story");
    expect(screen.queryByText("Super-only story")).toBeNull();
  });

  it("re-fetches team data after an organization change", async () => {
    currentUser = account("ADMIN", "NEWS");
    adminAssets = [video("10001", "Old team story")];
    renderApp();
    await signIn();
    await screen.findByText("Old team story");
    const socket = latestSocket();
    act(() => socket.serverEmit("connect"));

    currentUser = { ...account("ADMIN", "SPORT"), companyName: "Sports" };
    adminAssets = [video("20001", "New team story")];
    act(() => socket.serverEmit("disconnect", "io server disconnect"));
    expect(screen.queryByText("Old team story")).toBeNull();
    act(() => socket.serverEmit("connect"));
    await screen.findByText("New team story");
    expect(screen.queryByText("Old team story")).toBeNull();
    expect(screen.getByText("Sports")).toBeTruthy();
    expect(requestPaths().filter((path) => path === "/api/admin/assets").length).toBeGreaterThanOrEqual(2);
  });

  it("keeps scoped data hidden on a transient access-check failure and retries", async () => {
    currentUser = account("ADMIN");
    adminAssets = [video("10001", "Team story")];
    renderApp();
    await signIn();
    await screen.findByText("Team story");
    const socket = latestSocket();
    act(() => socket.serverEmit("connect"));
    meResponse = async () => jsonResponse({ error: "Access temporarily unavailable" }, 503);

    act(() => socket.serverEmit("disconnect", "io server disconnect"));
    act(() => socket.serverEmit("connect"));
    await screen.findByText("Access temporarily unavailable");
    expect(screen.queryByText("Team story")).toBeNull();
    expect(queryClient.getQueryCache().getAll()).toHaveLength(0);

    meResponse = async () => jsonResponse({ user: currentUser });
    fireEvent.click(screen.getByRole("button", { name: "Retry access check" }));
    await screen.findByText("Team story");
    expect(screen.queryByText("Access temporarily unavailable")).toBeNull();
  });

  it("signs out an account rejected during socket reauthorization", async () => {
    myAssets = [video("10001", "Private story")];
    renderApp();
    await signIn();
    await screen.findByText("Private story");
    const socket = latestSocket();
    act(() => socket.serverEmit("connect"));
    act(() => socket.serverEmit("disconnect", "io server disconnect"));
    act(() => socket.serverEmit("connect_error", new Error("Account unavailable")));

    await screen.findByRole("button", { name: "Sign In" });
    expect(screen.queryByText("Private story")).toBeNull();
    expect(localStorage.getItem("fixer_admin_token")).toBeNull();
    expect(getToken()).toBeNull();
    expect(queryClient.getQueryCache().getAll()).toHaveLength(0);
    expect(socket.disconnect).toHaveBeenCalled();
  });

  it("discards a late privileged query result after a role change", async () => {
    currentUser = account("SUPER_ADMIN");
    const response = deferred<Response>();
    adminAssetsResponse = () => response.promise;
    myAssets = [video("20001", "My own story")];
    renderApp();
    await signIn();
    await screen.findByRole("heading", { name: "Triad Status" });
    await waitFor(() => expect(requestPaths()).toContain("/api/admin/assets"));
    const socket = latestSocket();
    act(() => socket.serverEmit("connect"));
    currentUser = account("USER");
    act(() => socket.serverEmit("disconnect", "io server disconnect"));
    act(() => socket.serverEmit("connect"));
    await screen.findByRole("heading", { name: "Access denied" });
    fireEvent.click(screen.getByRole("link", { name: "Go to your dashboard" }));
    await screen.findByText("My own story");

    await act(async () => response.resolve(jsonResponse({ assets: [video("10001", "Late secret story")] })));
    expect(screen.queryByText("Late secret story")).toBeNull();
    expect(queryClient.getQueryData(["assets", "default"])).toBeUndefined();
  });

  it("ignores an in-flight access refresh after logout", async () => {
    currentUser = account("SUPER_ADMIN");
    adminAssets = [video("10001", "Old account story")];
    renderApp();
    await signIn();
    await screen.findByText("Old account story");
    const socket = latestSocket();
    act(() => socket.serverEmit("connect"));
    const response = deferred<Response>();
    meResponse = () => response.promise;
    act(() => socket.serverEmit("disconnect", "io server disconnect"));
    act(() => socket.serverEmit("connect"));
    await waitFor(() => expect(requestPaths()).toContain("/api/auth/me"));

    fireEvent.click(screen.getByRole("button", { name: "Log out" }));
    await screen.findByRole("button", { name: "Sign In" });
    currentUser = account("USER");
    token = `test-token-${++tokenSequence}`;
    myAssets = [video("20001", "New account story")];
    await signIn();
    await screen.findByText("New account story");
    expect(testRouter.state.location.pathname).toBe("/videos");
    await act(async () => response.resolve(jsonResponse({ user: account("SUPER_ADMIN") })));
    expect(screen.getByText("New account story")).toBeTruthy();
    expect(screen.queryByText("Old account story")).toBeNull();
    expect(getToken()).toBe(token);
  });
});
