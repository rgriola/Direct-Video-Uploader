import { useEffect, useState } from "react";
import { fetchMessages } from "@/lib/api";
import { panelHeader } from "@/lib/types";
import { subTextPanelHeader } from "@/lib/types";

interface Message {
  id: string;
  userId?: string | null;
  assetId?: string | null;
  direction: string;
  messageType: string;
  content?: { text?: string; fileName?: string; mediasourceId?: string };
  createdAt: string;
}

interface ChatHistoryProps {
  onClose: () => void;
}

const directionIcon: Record<string, string> = {
  OUTGOING: "📤",
  INCOMING: "📥",
};

const typeColors: Record<string, string> = {
  TEXT: "var(--foreground)",
  VIDEO: "var(--accent-blue)",
  GREETING: "var(--accent-green)",
  CONFIRMATION: "var(--accent-amber)",
  FORM: "var(--accent-purple)",
};

function formatTime(dateStr: string): string {
  const d = new Date(dateStr);
  return d.toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

export function ChatHistory({ onClose }: ChatHistoryProps) {
  const [messages, setMessages] = useState<Message[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      try {
        const res = await fetchMessages();
        if (!cancelled) {
          setMessages((res.messages ?? []) as Message[]);
          setLoading(false);
        }
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : "Failed to load");
          setLoading(false);
        }
      }
    }

    void load();
    return () => { cancelled = true; };
  }, []);

  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius-xl) overflow-hidden mb-8">
      <div className={panelHeader}>
        <h2 className="text-(--text-lg) font-semibold flex items-center gap-2">
          💬 Chat History
          <span className={subTextPanelHeader}>
            {messages.length} messages
          </span>
        </h2>
        <button
          onClick={onClose}
          className="px-2 py-1 rounded-(--radius-lg) text-(--text-xs) font-medium bg-(--card) border border-(--border) text-(--muted-foreground) hover:bg-(--card-hover) hover:text-(--foreground) transition-all cursor-pointer"
        >
          Close
        </button>
      </div>

      <div className="max-h-100 overflow-y-auto scrollbar-hide">
        {loading ? (
          <div className="py-10 text-center text-(--muted-foreground) text-(--text-sm)">
            <div className="text-(--text-3xl) mb-2 opacity-50">💬</div>
            Loading messages...
          </div>
        ) : error ? (
          <div className="py-10 text-center text-(--accent-red) text-(--text-sm)">
            <div className="text-(--text-3xl) mb-2">❌</div>
            {error}
          </div>
        ) : messages.length === 0 ? (
          <div className="py-10 text-center text-(--muted-foreground) text-(--text-sm)">
            <div className="text-(--text-3xl) mb-2 opacity-50">💬</div>
            No messages yet. Send a text from the iOS app.
          </div>
        ) : (
          messages.map((msg) => (
            <div
              key={msg.id}
              className="flex items-start gap-3 px-6 py-3 border-b border-(--border-subtle) last:border-b-0 hover:bg-(--card-hover) transition-colors"
            >
              <span className="text-(--text-lg) shrink-0 mt-0.5">
                {directionIcon[msg.direction] ?? "💬"}
              </span>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 mb-0.5">
                  <span
                    className="text-(--text-xs) font-bold px-1.5 py-px rounded-(--radius-sm)"
                    style={{
                      color: typeColors[msg.messageType] ?? "var(--foreground)",
                      background: "var(--secondary)",
                    }}
                  >
                    {msg.messageType}
                  </span>
                  <span className="text-(--text-xs) text-(--muted-foreground)">
                    {msg.direction === "OUTGOING" ? "User →" : "← Server"}
                  </span>
                  <span className="text-(--text-xs) text-(--muted-foreground)">
                    {formatTime(msg.createdAt)}
                  </span>
                </div>
                <p className="text-(--text-sm) text-(--foreground) wrap-break-word">
                  {msg.content?.text ?? "(no text)"}
                </p>
                {msg.content?.fileName && (
                  <p className="text-(--text-xs) text-(--muted-foreground) mt-0.5">
                    📎 {msg.content.fileName}
                  </p>
                )}
                {msg.content?.mediasourceId && (
                  <p className="text-(--text-xs) text-(--muted-foreground) mt-0.5">
                    🆔 {msg.content.mediasourceId}
                  </p>
                )}
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
