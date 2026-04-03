/* ─── API Types ─── */

export interface User {
  id: string;
  name: string;
  phoneNumber: string;
  email?: string | null;
  team?: string | null;
  role?: string;
  status: string;
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

export interface Endpoint {
  method: "GET" | "POST" | "WS";
  path: string;
  description: string;
}
