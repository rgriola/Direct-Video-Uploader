// May 10, 2026 - 3:19pm - GitHub Copilot (GPT-5.3-Codex)
/* ─── WebSocket hook (Socket.IO) — module-level singleton ─── */

import { useEffect, useRef, useState, useCallback } from "react";
import { io, type Socket } from "socket.io-client";
import { getToken } from "@/lib/api";
import type { LogEntry } from "@/lib/types";

let logId = 0;

function makeLog(type: LogEntry["type"], msg: string): LogEntry {
  const now = new Date();
  return {
    id: String(++logId),
    time: now.toLocaleTimeString("en-US", { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit" }),
    type,
    msg,
  };
}

// ─── Module-level singleton ─────────────────────────────────
// Survives HMR remounts — only ONE socket ever exists.
let _socket: Socket | null = null;
let _socketToken: string | null = null;
let _connected = false;

// HMR cleanup — Vite calls import.meta.hot.dispose on module replacement
if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    _socket?.disconnect();
    _socket = null;
    _socketToken = null;
    _connected = false;
  });
}

interface SocketCallbacks {
  onAssetChange?: () => void;
  onAuthorizationLost?: () => void;
  onReconnected?: () => void;
  onConnectionError?: (error: Error) => void;
}

export function useSocket(callbacks: SocketCallbacks = {}) {
  const callbacksRef = useRef(callbacks);
  const [connected, setConnected] = useState(_connected);
  const [socketId, setSocketId] = useState<string | null>(_socket?.id ?? null);
  const [logs, setLogs] = useState<LogEntry[]>([]);

  // Keep the callback ref fresh without causing reconnects
  useEffect(() => {
    callbacksRef.current = callbacks;
  }, [callbacks]);

  const addLog = useCallback((type: LogEntry["type"], msg: string) => {
    setLogs((prev) => [makeLog(type, msg), ...prev].slice(0, 50));
  }, []);

  const clearLogs = useCallback(() => setLogs([]), []);

  const disconnect = useCallback(() => {
    if (_socket) {
      _socket.removeAllListeners();
      _socket.disconnect();
      _socket = null;
    }
    _socketToken = null;
    _connected = false;
    setConnected(false);
    setSocketId(null);
    setLogs([]);
  }, []);

  const connect = useCallback((reauthorize = false) => {
    const token = getToken();
    if (!token) return;

    // Already connected — skip
    if (_socket?.connected && _socketToken === token) {
      setConnected(true);
      setSocketId(_socket.id ?? null);
      return;
    }

    // Tear down any stale socket before creating a new one
    if (_socket) {
      _socket.removeAllListeners();
      _socket.disconnect();
      _socket = null;
      _socketToken = null;
      _connected = false;
      setConnected(false);
      setSocketId(null);
    }

    const s = io("", {
      auth: { token, clientType: "admin" },
      path: "/socket.io",
      addTrailingSlash: false,
      transports: ["websocket"],   // WebSocket only — no polling fallback
      reconnectionAttempts: 5,
      reconnectionDelay: 3000,
    });
    _socket = s;
    _socketToken = token;
    let hasConnected = false;
    let needsAccessRefresh = reauthorize;

    s.on("connect", () => {
      _connected = true;
      setConnected(true);
      setSocketId(s.id ?? null);
      if ((hasConnected || needsAccessRefresh) && _socket === s && getToken() === token) {
        callbacksRef.current.onReconnected?.();
      }
      hasConnected = true;
      needsAccessRefresh = false;
      addLog("ws", `Connected (${s.id})`);
    });

    s.on("disconnect", (reason) => {
      _connected = false;
      setConnected(false);
      setSocketId(null);
      addLog("ws", "Disconnected");
      if (reason === "io server disconnect" && _socket === s && getToken() === token) {
        callbacksRef.current.onAuthorizationLost?.();
        s.connect();
      }
    });

    s.on("connect_error", (error) => {
      addLog("ws", `Connection failed: ${error.message}`);
      if (_socket === s && getToken() === token) {
        needsAccessRefresh = true;
        callbacksRef.current.onConnectionError?.(error);
      }
    });

    s.on("message:new", (data: { content?: { text?: string }; messageType?: string; type?: string }) => {
      addLog("ws", `Message: ${data.content?.text ?? JSON.stringify(data.messageType ?? data.type)}`);
    });

    s.on("upload:complete", (data: { assetId?: string }) => {
      addLog("ws", `Upload complete: ${data.assetId?.slice(0, 8)}...`);
      callbacksRef.current.onAssetChange?.();
    });

    s.on("mux:ready", (data: { assetId?: string }) => {
      addLog("ws", `Video ready: ${data.assetId?.slice(0, 8)}...`);
      callbacksRef.current.onAssetChange?.();
    });

    s.on("dashboard:asset-changed", () => {
      callbacksRef.current.onAssetChange?.();
    });

    s.on("form:request", (data: { assetId?: string }) => {
      addLog("ws", `Form request for asset ${data.assetId?.slice(0, 8)}...`);
    });

    s.on("form:confirmed", (data: { message?: string }) => {
      addLog("ws", `Form confirmed: ${data.message}`);
      callbacksRef.current.onAssetChange?.();
    });
  }, [addLog]);

  const retryConnection = useCallback(() => {
    if (_socket?.connected) {
      callbacksRef.current.onReconnected?.();
    } else if (_socket) {
      _socket.connect();
    } else {
      connect(true);
    }
  }, [connect]);

  const sendPing = useCallback(() => {
    _socket?.emit("message:send", { text: "Dashboard ping 🏓" });
    addLog("ws", "Sent ping");
  }, [addLog]);

  // Cleanup only on full page unload — not on HMR
  useEffect(() => {
    return () => {
      // Don't disconnect on HMR — module dispose handles that
    };
  }, []);

  return { connected, socketId, logs, addLog, clearLogs, connect, disconnect, retryConnection, sendPing };
}
