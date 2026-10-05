/* ─── API Types ─── */

export interface User {
  id: string;
  name: string;
  phoneNumber: string;
  email?: string | null;
  team?: string | null;
  role?: string;
  status: string;
  companyCode?: string | null;
  companyName?: string | null;
  assetCount?: number;
  createdAt?: string;
  lastLoginAt?: string | null;
  isOnline?: boolean;
  hasIosConnection?: boolean;
}

export interface Clip {
  id: string;
  storageUrl: string;
  fileSize?: string | null;
  resolution?: string | null;
  codec?: string | null;
  orientation?: string | null;
  duration?: number | null;
  metadata?: Record<string, unknown>;
}

export interface Asset {
  id: string;
  mediasourceId?: string | null;
  mediasourceUrl?: string | null;
  status: string;
  clipCount?: number;
  totalDuration?: number;
  clips?: Clip[];
  user?: Pick<User, "id" | "name" | "phoneNumber" | "team">;
  createdAt?: string;
  formResponse?: {
    id: string;
    slug?: string;
    type?: string;
    description?: string | null;
    priority?: string;
    submittedAt?: string;
  } | null;
}

export interface Stats {
  users: number;
  activeUsers: number;
  loggedInUsers: number;
  onlineUsers: number;
  assets: number;
  readyAssets: number;
  uploadingAssets: number;
  messages: number;
  clips: number;
  iosClients: number;
  wsConnections: number;
}

export interface TriadService {
  status: string;
  message?: string;
  clients?: number;
  uptime?: number;
}

export interface TriadStatus {
  triad: {
    database: TriadService;
    server: TriadService;
    ios: TriadService;
    admin: TriadService;
  };
  connectedUsers: number;
  totalWsConnections: number;
}

export interface LogEntry {
  id: string;
  time: string;
  type: "ws" | "http" | "auth" | "error" | "triad";
  msg: string;
}

export interface Organization {
  id: string;
  companyName: string;
  companyCode: string;
  createdAt: string;
  userCount: number;
}

export interface Endpoint {
  method: "GET" | "POST" | "WS";
  path: string;
  description: string;
}

export const panelHeader =
  "bg-(--secondary) text-(--secondary-foreground) flex items-center justify-between px-6 py-4 border-b border-(--border-subtle)";

export const subTextPanelHeader =
  "text-(length:--text-xs) text-(--secondary) bg-(--secondary-dark-shade) px-2 py-2 rounded-(--radius-sm) font-semibold";

export const userTeamText =
  "hidden sm:inline-flex shrink-0 items-center px-2 py-0.5 rounded-(--radius-md) text-(length:--text-xs) font-semibold bg-(--secondary) text-(--muted-foreground)";
