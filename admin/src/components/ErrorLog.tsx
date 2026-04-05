import { useQuery } from "@tanstack/react-query";
import { fetchErrors } from "@/lib/api";
import { panelHeader } from "@/lib/types";
import { subTextPanelHeader } from "@/lib/types";

interface ErrorEntry {
    id: string;
    source: string;
    category: string;
    message: string;
    severity: string;
    createdAt: string;
    userId?: string | null;
}

const severityColors: Record<string, string> = {
    CRITICAL: "bg-(--accent-red-glow) text-(--accent-red)",
    ERROR: "bg-(--accent-red-glow) text-(--accent-red)",
    WARNING: "bg-(--accent-amber-glow) text-(--accent-amber)",
    INFO: "bg-(--accent-blue-glow) text-(--accent-blue)",
};

const severityIcons: Record<string, string> = {
    CRITICAL: "🔴",
    ERROR: "🟠",
    WARNING: "🟡",
    INFO: "🔵",
};

export function ErrorLog() {
    const { data, isLoading } = useQuery({
        queryKey: ["errors"],
        queryFn: fetchErrors,
        refetchInterval: 30_000,
    });

    const errors: ErrorEntry[] = data?.errors ?? [];

    return (
        <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) overflow-hidden">

            <div className={panelHeader}>

                <h2 className="text-lg font-semibold flex items-center gap-2">
                    ⚠️ Error Log{" "}
                    <span className={subTextPanelHeader}>
                        {errors.length}
                    </span>
                </h2>
            </div>

            <div className="max-h-75 overflow-y-auto scrollbar-hide">
                {isLoading ? (
                    <Empty text="Loading errors..." />
                ) : errors.length === 0 ? (
                    <Empty text="No errors logged — everything is running smoothly." />
                ) : (
                    errors.map((err) => (
                        <div
                            key={err.id}
                            className="flex items-start gap-3 px-6 py-3 border-b border-(--border-subtle) last:border-b-0"
                        >
                            <span className="text-sm mt-0.5 shrink-0">{severityIcons[err.severity] ?? "⚪"}</span>
                            <div className="flex-1 min-w-0">
                                <div className="flex items-center gap-2 mb-0.5">
                                    <span
                                        className={`inline-flex items-center px-1.5 py-0.5 rounded text-[11px] font-bold uppercase ${severityColors[err.severity] ?? ""}`}
                                    >
                                        {err.severity}
                                    </span>
                                    <span className="text-[11px] text-(--muted-foreground) font-mono">
                                        {err.source}/{err.category}
                                    </span>
                                </div>
                                <p className="text-xs text-(--foreground) leading-snug max-w-[65ch]">{err.message}</p>
                                <p className="text-[11px] text-(--muted-foreground) mt-1">
                                    {new Date(err.createdAt).toLocaleString()}
                                </p>
                            </div>
                        </div>
                    ))
                )}
            </div>
        </div>
    );
}

function Empty({ text }: { text: string }) {
    return (
        <div className="py-10 px-6 text-center text-(--muted-foreground) text-sm">
            <div className="text-[32px] mb-2 opacity-50">✅</div>
            {text}
        </div>
    );
}
