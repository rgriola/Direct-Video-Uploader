import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { clearToken, fetchMe, getToken, logoutClipSession, setToken } from "@/lib/api";
import { useRefreshDashboard } from "@/hooks/use-dashboard";
import { useSocket } from "@/hooks/use-socket";
import type { LogEntry, SessionUser } from "@/lib/types";

const AUTH_TOKEN_KEY = "fixer_admin_token";

interface AuthContextValue {
  initializing: boolean;
  loggedIn: boolean;
  user: SessionUser | null;
  refreshingAccess: boolean;
  accessError: string | null;
  connected: boolean;
  logs: LogEntry[];
  addLog: (type: LogEntry["type"], message: string) => void;
  clearLogs: () => void;
  login: (user: SessionUser) => void;
  logout: () => void;
  retryAccess: () => void;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) throw new Error("useAuth must be used within AuthProvider");
  return context;
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const refreshDashboard = useRefreshDashboard();
  const [initializing, setInitializing] = useState(true);
  const [loggedIn, setLoggedIn] = useState(false);
  const [user, setUser] = useState<SessionUser | null>(null);
  const [refreshingAccess, setRefreshingAccess] = useState(false);
  const [accessError, setAccessError] = useState<string | null>(null);
  const authGeneration = useRef(0);

  const forgetSession = useCallback(() => {
    authGeneration.current += 1;
    clearToken();
    localStorage.removeItem(AUTH_TOKEN_KEY);
    queryClient.clear();
    setLoggedIn(false);
    setUser(null);
    setRefreshingAccess(false);
    setAccessError(null);
    void logoutClipSession();
  }, [queryClient]);

  const clearScopedDashboard = useCallback(() => {
    authGeneration.current += 1;
    queryClient.clear();
    setUser(null);
    setAccessError(null);
    setRefreshingAccess(true);
  }, [queryClient]);

  const reloadAccess = useCallback(() => {
    const token = getToken();
    if (!token) return;
    clearScopedDashboard();
    const generation = authGeneration.current;
    void fetchMe().then(({ user: currentUser }) => {
      if (authGeneration.current !== generation || getToken() !== token) return;
      if (!currentUser) throw new Error("Account unavailable");
      setUser(currentUser);
      setRefreshingAccess(false);
    }).catch((error: unknown) => {
      if (authGeneration.current !== generation || getToken() !== token) return;
      setAccessError(error instanceof Error ? error.message : "Could not verify dashboard access.");
    });
  }, [clearScopedDashboard]);

  const { connected, logs, addLog, clearLogs, connect, disconnect, retryConnection } = useSocket({
    onAssetChange: () => refreshDashboard("upload:complete"),
    onAuthorizationLost: () => {
      clearLogs();
      clearScopedDashboard();
    },
    onReconnected: () => {
      clearLogs();
      reloadAccess();
    },
    onConnectionError: (error) => {
      if (["Account unavailable", "Invalid token", "Authentication required"].includes(error.message)) {
        disconnect();
        forgetSession();
        toast.error("Your session expired or your account is unavailable. Sign in again.");
      } else {
        setAccessError("Could not connect to live updates. Retry the connection or sign in again.");
      }
    },
  });

  useEffect(() => {
    const saved = localStorage.getItem(AUTH_TOKEN_KEY);
    if (!saved) {
      setInitializing(false);
      return;
    }
    const generation = ++authGeneration.current;

    async function restoreSession(token: string) {
      try {
        setToken(token);
        const { user: currentUser } = await fetchMe();
        if (authGeneration.current !== generation || getToken() !== token) return;
        if (!currentUser) throw new Error("Account unavailable");
        setLoggedIn(true);
        setUser(currentUser);
        addLog("auth", `Session restored: ${currentUser.name}`);
        connect();
      } catch (error) {
        if (authGeneration.current !== generation || getToken() !== token) return;
        const message = error instanceof Error ? error.message : "";
        if (["HTTP 401", "HTTP 403", "Unauthorized", "Admin access required", "Account suspended", "Account unavailable"].includes(message)) {
          clearToken();
          localStorage.removeItem(AUTH_TOKEN_KEY);
          toast.error("Your session expired or your account is unavailable. Sign in again.");
        } else {
          toast.error("Could not restore your session. Check the connection and sign in again.");
        }
      } finally {
        if (authGeneration.current === generation) setInitializing(false);
      }
    }

    void restoreSession(saved);
  }, [addLog, connect]);

  const login = useCallback((currentUser: SessionUser) => {
    const token = getToken();
    if (!token) throw new Error("Sign-in did not return a session token.");
    authGeneration.current += 1;
    localStorage.setItem(AUTH_TOKEN_KEY, token);
    queryClient.clear();
    setRefreshingAccess(false);
    setAccessError(null);
    setLoggedIn(true);
    setUser(currentUser);
    clearLogs();
    addLog("auth", `Dashboard auth: ${currentUser.name}`);
    connect();
  }, [addLog, clearLogs, connect, queryClient]);

  const logout = useCallback(() => {
    disconnect();
    forgetSession();
  }, [disconnect, forgetSession]);

  const retryAccess = useCallback(() => {
    setAccessError(null);
    if (connected) reloadAccess();
    else retryConnection();
  }, [connected, reloadAccess, retryConnection]);

  return (
    <AuthContext.Provider value={{
      initializing, loggedIn, user, refreshingAccess, accessError, connected, logs,
      addLog, clearLogs, login, logout, retryAccess,
    }}>
      {children}
    </AuthContext.Provider>
  );
}
