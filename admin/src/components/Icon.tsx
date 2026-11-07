/**
 * Single source of truth for every icon used in the Dashboard.
 *
 * Call sites never import from `lucide-react` directly — they reference a
 * semantic name via <Icon name="..." />. Swapping the underlying icon for
 * any name (or the whole icon library) only ever requires editing the map
 * below. The server-rendered Clip Viewer has its own equivalent registry
 * at `server/src/lib/icons.js` (no React there), using the same names
 * where the two surfaces share a concept (e.g. "date", "organization").
 */
import type { LucideIcon, LucideProps } from "lucide-react";
import {
  Users,
  Package,
  MessageSquare,
  Clapperboard,
  Wrench,
  Radiation,
  AlertTriangle,
  Siren,
  User,
  CheckCircle2,
  XCircle,
  Hourglass,
  Radio,
  Activity,
  Eraser,
  Upload,
  Download,
  Paperclip,
  Hash,
  Map,
  Smartphone,
  BarChart3,
  Database,
  Zap,
  Triangle,
  Flag,
  Globe,
  FileText,
  Building2,
  Calendar,
  RefreshCw,
  Video,
  Ruler,
  MoveHorizontal,
  HardDrive,
  Clock,
  Timer,
  MapPin,
  Mountain,
  Save,
  MonitorPlay,
  PlayCircle,
  Tag,
  ClipboardList,
  Copy,
  AlignLeft,
  Captions,
  Lock,
  Settings,
  ArrowLeft,
  ArrowRight,
  ArrowUpRight,
  Plus,
  Pencil,
  Trash2,
  X,
  Check,
  ChevronDown,
  LogOut,
  Circle,
} from "lucide-react";

const iconMap = {
  users: Users,
  assets: Package,
  messages: MessageSquare,
  clips: Clapperboard,
  tools: Wrench,
  nuclear: Radiation,
  warning: AlertTriangle,
  alert: Siren,
  user: User,
  success: CheckCircle2,
  error: XCircle,
  processing: Hourglass,
  activity: Radio,
  health: Activity,
  cleanup: Eraser,
  outgoing: Upload,
  incoming: Download,
  attachment: Paperclip,
  id: Hash,
  endpoints: Map,
  device: Smartphone,
  status: BarChart3,
  database: Database,
  api: Zap,
  triad: Triangle,
  priority: Flag,
  url: Globe,
  file: FileText,
  organization: Building2,
  date: Calendar,
  refresh: RefreshCw,
  video: Video,
  resolution: Ruler,
  orientation: MoveHorizontal,
  fileSize: HardDrive,
  time: Clock,
  duration: Timer,
  gps: MapPin,
  altitude: Mountain,
  storage: Save,
  stream: MonitorPlay,
  play: PlayCircle,
  tag: Tag,
  form: ClipboardList,
  copy: Copy,
  description: AlignLeft,
  transcript: Captions,
  locked: Lock,
  settings: Settings,
  arrowLeft: ArrowLeft,
  arrowRight: ArrowRight,
  arrowUpRight: ArrowUpRight,
  add: Plus,
  edit: Pencil,
  delete: Trash2,
  close: X,
  confirm: Check,
  expand: ChevronDown,
  logout: LogOut,
  dot: Circle,
} satisfies Record<string, LucideIcon>;

export type IconName = keyof typeof iconMap;

interface IconProps extends Omit<LucideProps, "ref"> {
  name: IconName;
}

/**
 * Renders a registered icon. Defaults to `size="1em"` so it automatically
 * matches the font-size of whatever text it's paired with — pass an
 * explicit `size`/className only when an icon stands alone (no adjacent
 * text at the same scale). Defaults to `aria-hidden` since nearly every
 * use here is paired with a visible text label; pass `aria-label` and omit
 * `aria-hidden` for the rare icon-only, meaningful case.
 */
export function Icon({ name, size = "1em", strokeWidth = 2, ...rest }: IconProps) {
  const Component = iconMap[name];
  return <Component size={size} strokeWidth={strokeWidth} aria-hidden="true" {...rest} />;
}
