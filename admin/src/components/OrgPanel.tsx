import { useState } from "react";
import { toast } from "sonner";
import { createOrganization, updateOrganization, deleteOrganization } from "@/lib/api";
import type { Organization } from "@/lib/types";
import { panelHeader, subTextPanelHeader } from "@/lib/types";
import { Building2, Plus, Pencil, Trash2, X, Check, Users } from "lucide-react";

interface OrgPanelProps {
  organizations: Organization[];
  isLoading: boolean;
  onRefresh: () => void;
}

export function OrgPanel({ organizations, isLoading, onRefresh }: OrgPanelProps) {
  const [newName, setNewName] = useState("");
  const [newCode, setNewCode] = useState("");
  const [creating, setCreating] = useState(false);
  const [editingCode, setEditingCode] = useState<string | null>(null);
  const [editName, setEditName] = useState("");
  const [editCode, setEditCode] = useState("");
  const [deletingCode, setDeletingCode] = useState<string | null>(null);

  const NAME_RE = /^[A-Za-z\s]{1,50}$/;
  const CODE_RE = /^[A-Za-z]{3,4}$/;

  async function handleCreate(e: React.FormEvent) {
    e.preventDefault();
    if (!NAME_RE.test(newName.trim())) {
      toast.error("Company name: 1–50 characters, letters and spaces only");
      return;
    }
    if (!CODE_RE.test(newCode.trim())) {
      toast.error("Company code: 3–4 letters (A–Z, a–z)");
      return;
    }
    setCreating(true);
    try {
      const res = await createOrganization({ companyName: newName.trim(), companyCode: newCode.trim() });
      toast.success(res.message);
      setNewName("");
      setNewCode("");
      onRefresh();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to create organization");
    } finally {
      setCreating(false);
    }
  }

  async function handleUpdate(code: string) {
    if (editName && !NAME_RE.test(editName.trim())) {
      toast.error("Company name: 1–50 characters, letters and spaces only");
      return;
    }
    if (editCode && !CODE_RE.test(editCode.trim())) {
      toast.error("Company code: 3–4 letters (A–Z, a–z)");
      return;
    }
    try {
      const data: { companyName?: string; companyCode?: string } = {};
      if (editName.trim()) data.companyName = editName.trim();
      if (editCode.trim() && editCode.trim().toUpperCase() !== code) data.companyCode = editCode.trim();
      const res = await updateOrganization(code, data);
      toast.success(res.message);
      setEditingCode(null);
      onRefresh();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to update organization");
    }
  }

  async function handleDelete(code: string) {
    if (deletingCode !== code) {
      setDeletingCode(code);
      return;
    }
    try {
      const res = await deleteOrganization(code);
      toast.success(res.message);
      setDeletingCode(null);
      onRefresh();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to delete organization");
      setDeletingCode(null);
    }
  }

  const inputClass =
    "px-3 py-1.5 rounded-(--radius-lg) text-(length:--text-sm) bg-(--secondary) border border-(--border) text-(--secondary-foreground) placeholder:text-(--secondary-foreground) focus:outline-none focus:border-(--accent-blue) transition-colors";

  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius-xl) overflow-hidden">
      <div className={panelHeader}>
        <h2 className="text-(length:--text-lg) font-semibold flex items-center gap-2">
          <Building2 className="w-5 h-5" /> Organizations
          <span className={subTextPanelHeader}>{organizations.length}</span>
        </h2>
      </div>

      <div className="divide-y divide-(--border-subtle)">
        {isLoading && organizations.length === 0 && (
          <div className="px-6 py-8 text-center text-(--muted-foreground) text-(length:--text-sm)">Loading...</div>
        )}

        {!isLoading && organizations.length === 0 && (
          <div className="px-6 py-8 text-center text-(--muted-foreground) text-(length:--text-sm)">
            No organizations yet. Create one below.
          </div>
        )}

        {organizations.map((org) => (
          <div key={org.companyCode} className="px-6 py-3">
            {editingCode === org.companyCode ? (
              /* Edit mode */
              <div className="flex items-center gap-2 flex-wrap">
                <input
                  className={`${inputClass} flex-1 min-w-[120px]`}
                  value={editName}
                  onChange={(e) => setEditName(e.target.value)}
                  placeholder="Company Name"
                  maxLength={50}
                />
                <input
                  className={`${inputClass} w-20`}
                  value={editCode}
                  onChange={(e) => setEditCode(e.target.value.replace(/[^A-Za-z]/g, "").slice(0, 4))}
                  placeholder="CODE"
                  maxLength={4}
                />
                <button
                  onClick={() => handleUpdate(org.companyCode)}
                  aria-label="Save changes"
                  className="p-1.5 rounded-(--radius-md) bg-(--accent-green)/15 text-(--accent-green) hover:bg-(--accent-green)/25 transition-colors cursor-pointer"
                >
                  <Check className="w-4 h-4" />
                </button>
                <button
                  onClick={() => setEditingCode(null)}
                  aria-label="Cancel editing"
                  className="p-1.5 rounded-(--radius-md) bg-(--secondary) text-(--muted-foreground) hover:text-(--foreground) transition-colors cursor-pointer"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>
            ) : (
              /* Display mode */
              <div className="flex items-center gap-3">
                <div className="flex-1 min-w-0">
                  <span className="text-(length:--text-sm) font-medium text-(--foreground)">{org.companyName}</span>
                  <span className="ml-2 px-2 py-0.5 rounded-(--radius-md) text-(length:--text-xs) font-bold bg-(--accent-purple)/15 text-(--accent-purple) tracking-wider">
                    {org.companyCode}
                  </span>
                </div>

                <span className="flex items-center gap-1 text-(length:--text-xs) text-(--muted-foreground) shrink-0">
                  <Users className="w-3 h-3" /> {org.userCount}
                </span>

                <button
                  onClick={() => {
                    setEditingCode(org.companyCode);
                    setEditName(org.companyName);
                    setEditCode(org.companyCode);
                  }}
                  className="p-1.5 rounded-(--radius-md) text-(--muted-foreground) hover:text-(--accent-blue) hover:bg-(--accent-blue)/10 transition-colors cursor-pointer"
                  title="Edit"
                  aria-label="Edit organization"
                >
                  <Pencil className="w-3.5 h-3.5" />
                </button>

                {deletingCode === org.companyCode ? (
                  <div className="flex items-center gap-1">
                    <button
                      onClick={() => handleDelete(org.companyCode)}
                      className="px-2 py-1 rounded-(--radius-md) text-(length:--text-xs) font-semibold bg-(--accent-red) text-white hover:opacity-90 transition-opacity cursor-pointer"
                    >
                      Confirm
                    </button>
                    <button
                      onClick={() => setDeletingCode(null)}
                      className="px-2 py-1 rounded-(--radius-md) text-(length:--text-xs) text-(--muted-foreground) hover:text-(--foreground) cursor-pointer"
                    >
                      Cancel
                    </button>
                  </div>
                ) : (
                  <button
                    onClick={() => handleDelete(org.companyCode)}
                    className="p-1.5 rounded-(--radius-md) text-(--muted-foreground) hover:text-(--accent-red) hover:bg-(--accent-red)/10 transition-colors cursor-pointer"
                    title="Delete"
                    aria-label="Delete organization"
                  >
                    <Trash2 className="w-3.5 h-3.5" />
                  </button>
                )}
              </div>
            )}
          </div>
        ))}
      </div>

      {/* Create form */}
      <form onSubmit={handleCreate} className="px-6 py-4 border-t border-(--border-subtle) bg-(--secondary)/30">
        <div className="flex items-center gap-2 flex-wrap">
          <input
            className={`${inputClass} flex-1 min-w-[120px]`}
            placeholder="Company Name"
            value={newName}
            onChange={(e) => setNewName(e.target.value.replace(/[^A-Za-z\s]/g, "").slice(0, 50))}
            maxLength={50}
          />
          <input
            className={`${inputClass} w-20`}
            placeholder="CODE"
            value={newCode}
            onChange={(e) => setNewCode(e.target.value.replace(/[^A-Za-z]/g, "").slice(0, 4))}
            maxLength={4}
          />
          <button
            type="submit"
            disabled={creating || !newName.trim() || !newCode.trim()}
            className="flex items-center gap-1 px-3 py-1.5 rounded-(--radius-lg) text-(length:--text-sm) font-semibold bg-(--accent-blue) text-white hover:opacity-90 transition-opacity cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <Plus className="w-4 h-4" />
            {creating ? "Adding..." : "Add"}
          </button>
        </div>
      </form>
    </div>
  );
}
