// Last updated: May 11, 2026 - 7:15pm - GitHub Copilot (GPT-5.3-Codex)
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
let _connected = false;

// HMR cleanup — Vite calls import.meta.hot.dispose on module replacement
if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    _socket?.disconnect();
    _socket = null;
    _connected = false;
  });
}

export function useSocket(onAssetChange?: () => void) {
  const onAssetChangeRef = useRef(onAssetChange);
  const [connected, setConnected] = useState(_connected);
  const [socketId, setSocketId] = useState<string | null>(_socket?.id ?? null);
  const [logs, setLogs] = useState<LogEntry[]>([]);

  // Keep the callback ref fresh without causing reconnects
  useEffect(() => {
    onAssetChangeRef.current = onAssetChange;
  }, [onAssetChange]);

  const addLog = useCallback((type: LogEntry["type"], msg: string) => {
    setLogs((prev) => [makeLog(type, msg), ...prev].slice(0, 50));
  }, []);

  const clearLogs = useCallback(() => setLogs([]), []);

  const connect = useCallback(() => {
    const token = getToken();

    // Already connected — skip
    if (_socket?.connected) {
      setConnected(true);
      setSocketId(_socket.id ?? null);
      return;
    }

    // Tear down any stale socket before creating a new one
    if (_socket) {
      _socket.removeAllListeners();
      _socket.disconnect();
      _socket = null;
    }

    const s = io("", {
      auth: {
        ...(token ? { token } : {}),
        clientType: "admin",
      },
      path: "/socket.io",
      addTrailingSlash: false,
      transports: ["websocket"],   // WebSocket only — no polling fallback
      reconnectionAttempts: 5,
      reconnectionDelay: 3000,
    });
    _socket = s;

    s.on("connect", () => {
      _connected = true;
      setConnected(true);
      setSocketId(s.id ?? null);
      addLog("ws", `Connected (${s.id})`);
    });

    s.on("disconnect", () => {
      _connected = false;
      setConnected(false);
      setSocketId(null);
      addLog("ws", "Disconnected");
    });

    s.on("message:new", (data: { content?: { text?: string }; messageType?: string; type?: string }) => {
      addLog("ws", `Message: ${data.content?.text ?? JSON.stringify(data.messageType ?? data.type)}`);
    });

    s.on("upload:complete", (data: { assetId?: string }) => {
      addLog("ws", `Upload complete: ${data.assetId?.slice(0, 8)}...`);
      onAssetChangeRef.current?.();
    });

    s.on("form:request", (data: { assetId?: string }) => {
      addLog("ws", `Form request for asset ${data.assetId?.slice(0, 8)}...`);
    });

    s.on("form:confirmed", (data: { message?: string }) => {
      addLog("ws", `Form confirmed: ${data.message}`);
    });
  }, [addLog]);

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

  return { connected, socketId, logs, addLog, clearLogs, connect, sendPing };
}
