import { useState } from "react";
import { toast } from "sonner";
import { nuclearReset, createUser } from "@/lib/api";

export function AdminTools({ onReset }: { onReset: () => void }) {
  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) overflow-hidden mb-8">
      <div className="flex items-center justify-between px-6 py-4 border-b border-(--border-subtle)">
        <h2 className="text-lg font-semibold flex items-center gap-2">
          🔧 Admin Tools
        </h2>
        <span className="text-[11px] bg-(--secondary) text-(--muted-foreground) px-2 py-0.5 rounded-[10px] font-semibold">
          Demo Management
        </span>
      </div>

      <div className="grid grid-cols-2 gap-6 px-6 py-4 max-[900px]:grid-cols-1">
        <NuclearReset onReset={onReset} />
        <CreateUser />
      </div>
    </div>
  );
}

/* ─── Nuclear Reset ─── */

function NuclearReset({ onReset }: { onReset: () => void }) {
  const [confirming, setConfirming] = useState(false);
  const [running, setRunning] = useState(false);

  async function handleReset() {
    if (!confirming) {
      setConfirming(true);
      return;
    }
    setRunning(true);
    try {
      const res = await nuclearReset();
      const d = res.deleted;
      toast.success(res.message, {
        description: `${d.assets} assets, ${d.clips} clips, ${d.chatMessages} messages deleted. Mux: ${res.mux.deleted} deleted${res.mux.failed ? `, ${res.mux.failed} failed` : ""}${res.mux.skipped ? " (Mux not configured)" : ""}`,
        duration: 8000,
      });
      onReset();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Nuclear reset failed");
    } finally {
      setRunning(false);
      setConfirming(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      <h3 className="text-sm font-semibold text-(--muted-foreground) uppercase tracking-wide">
        ☢️ Nuclear Reset
      </h3>
      <p className="text-sm text-(--muted-foreground) leading-relaxed">
        Wipe all assets, clips, Mux videos, chat messages, form responses, and
        error logs. <strong>User accounts are preserved.</strong>
      </p>
      {confirming && !running && (
        <p className="text-xs text-(--accent-red) font-semibold">
          ⚠️ This cannot be undone. Click again to confirm.
        </p>
      )}
      <div className="flex gap-2">
        <button 
          onClick={handleReset}
          disabled={running}
          className={`px-4 py-2 rounded-lg text-sm font-semibold border transition-all cursor-pointer ${
            confirming
              ? "bg-(--accent-red) border-(--accent-red) text-white hover:opacity-90"
              : "bg-(--secondary) border-(--border) text-(--foreground) hover:bg-(--accent-red-glow) hover:border-(--accent-red)/50 hover:text-(--accent-red)"
          } disabled:opacity-50 disabled:cursor-not-allowed`}
        >
          {running ? "Resetting..." : confirming ? "Confirm Reset" : "Reset Everything"}
        </button>
        {confirming && !running && (
          <button
            onClick={() => setConfirming(false)}
            className="px-4 py-2 rounded-lg text-sm font-medium bg-(--secondary) border border-(--border) text-(--muted-foreground) hover:text-(--foreground) transition-all cursor-pointer"
          >
            Cancel
          </button>
        )}
      </div>
    </div>
  );
}

/* ─── Create User ─── */

function CreateUser() {
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [team, setTeam] = useState("");
  const [creating, setCreating] = useState(false);

  async function handleCreate(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim() || !phone.trim()) {
      toast.error("Name and phone number are required");
      return;
    }
    setCreating(true);
    try {
      const res = await createUser({
        name: name.trim(),
        phoneNumber: phone.replace(/\D/g, ""),
        email: email.trim() || undefined,
        team: team.trim() || undefined,
      });
      toast.success(res.message);
      setName("");
      setPhone("");
      setEmail("");
      setTeam("");
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to create user");
    } finally {
      setCreating(false);
    }
  }

  const inputClass =
    "w-full px-3 py-1.5 rounded-lg text-sm bg-(--secondary) border border-(--border) text-(--foreground) placeholder:text-(--muted-foreground) focus:outline-none focus:border-(--accent-blue) transition-colors";

  return (
    <div className="flex flex-col gap-3">
      <h3 className="text-sm font-semibold text-(--muted-foreground) uppercase tracking-wide">
        👤 Create Demo User
      </h3>
      <p className="text-sm text-(--muted-foreground)">
        PIN defaults to <strong>0000</strong>, role defaults to <strong>USER</strong>.
      </p>
      <form onSubmit={handleCreate} className="flex flex-col gap-2">
        <div className="grid grid-cols-2 gap-2">
          <input
            className={inputClass}
            placeholder="Name *"
            value={name}
            onChange={(e) => setName(e.target.value)}
            required
          />
          <input
            className={inputClass}
            placeholder="Phone *"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            required
          />
        </div>
        <div className="grid grid-cols-2 gap-2">
          <input
            className={inputClass}
            placeholder="Email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
          <input
            className={inputClass}
            placeholder="Team"
            value={team}
            onChange={(e) => setTeam(e.target.value)}
          />
        </div>
        <button
          type="submit"
          disabled={creating}
          className="self-start px-4 py-2 rounded-lg text-sm font-semibold bg-(--accent-blue) text-white border border-(--accent-blue) hover:brightness-110 transition-all cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {creating ? "Creating..." : "Create User"}
        </button>
      </form>
    </div>
  );
}
