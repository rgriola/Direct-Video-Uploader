// May 12, 2026 - 3:52pm - GitHub Copilot (GPT-5.3-Codex)
import { useState } from "react";
import { toast } from "sonner";
import { createOrganization, updateOrganization, deleteOrganization } from "@/lib/api";
import type { Organization } from "@/lib/types";
import { panelHeader, subTextPanelHeader } from "@/lib/types";
import { Building2, Plus, Pencil, Trash2, X, Check, Users, ShieldCheck } from "lucide-react";

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
  const [editSsoEnabled, setEditSsoEnabled] = useState(false);
  const [editSamlMetadataURL, setEditSamlMetadataURL] = useState("");
  const [editSamlEntityId, setEditSamlEntityId] = useState("");
  const [editSamlAttributeMapping, setEditSamlAttributeMapping] = useState("");
  const [deletingCode, setDeletingCode] = useState<string | null>(null);

  const NAME_RE = /^[A-Za-z\s]{1,50}$/;
  const CODE_RE = /^[A-Za-z]{3,4}$/;

  function isValidURL(value: string): boolean {
    try {
      const parsed = new URL(value);
      return ["https:", "http:"].includes(parsed.protocol);
    } catch {
      return false;
    }
  }

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

    const metadataUrl = editSamlMetadataURL.trim();
    const entityId = editSamlEntityId.trim();
    if (metadataUrl && !isValidURL(metadataUrl)) {
      toast.error("SAML metadata URL must be a valid http(s) URL");
      return;
    }
    if (editSsoEnabled && (!metadataUrl || !entityId)) {
      toast.error("SSO enabled orgs require metadata URL and entity ID");
      return;
    }

    let attributeMapping: Record<string, string> | null = null;
    if (editSamlAttributeMapping.trim()) {
      try {
        const parsed = JSON.parse(editSamlAttributeMapping);
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
          throw new Error("Attribute mapping must be a JSON object");
        }
        const normalized: Record<string, string> = {};
        for (const [key, value] of Object.entries(parsed)) {
          if (typeof value === "string" && value.trim()) {
            normalized[key] = value.trim();
          }
        }
        attributeMapping = normalized;
      } catch {
        toast.error("Attribute mapping must be valid JSON object text");
        return;
      }
    }

    try {
      const data: {
        companyName?: string;
        companyCode?: string;
        ssoEnabled?: boolean;
        samlMetadataUrl?: string | null;
        samlEntityId?: string | null;
        samlAttributeMapping?: Record<string, string> | null;
      } = {};
      if (editName.trim()) data.companyName = editName.trim();
      if (editCode.trim() && editCode.trim().toUpperCase() !== code) data.companyCode = editCode.trim();
      data.ssoEnabled = editSsoEnabled;
      data.samlMetadataUrl = metadataUrl || null;
      data.samlEntityId = entityId || null;
      data.samlAttributeMapping = attributeMapping;
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
    "px-3 py-1.5 rounded-lg text-sm bg-(--secondary) border border-(--border) text-(--secondary-foreground) placeholder:text-(--secondary-foreground) focus:outline-none focus:border-(--accent-blue) transition-colors";

  return (
    <div className="bg-(--card) border border-(--border-subtle) rounded-(--radius) overflow-hidden">
      <div className={panelHeader}>
        <h2 className="text-lg font-semibold flex items-center gap-2">
          <Building2 className="w-5 h-5" /> Organizations
          <span className={subTextPanelHeader}>{organizations.length}</span>
        </h2>
      </div>

      <div className="divide-y divide-(--border-subtle)">
        {isLoading && organizations.length === 0 && (
          <div className="px-6 py-8 text-center text-(--muted-foreground) text-sm">Loading...</div>
        )}

        {!isLoading && organizations.length === 0 && (
          <div className="px-6 py-8 text-center text-(--muted-foreground) text-sm">
            No organizations yet. Create one below.
          </div>
        )}

        {organizations.map((org) => (
          <div key={org.companyCode} className="px-6 py-3">
            {editingCode === org.companyCode ? (
              /* Edit mode */
              <div className="w-full space-y-2">
                <div className="flex items-center gap-2 flex-wrap">
                <input
                  className={`${inputClass} flex-1 min-w-30`}
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
                <label className="inline-flex items-center gap-1.5 px-2 py-1 rounded-md text-xs bg-(--accent-blue)/10 text-(--accent-blue)">
                  <input
                    type="checkbox"
                    checked={editSsoEnabled}
                    onChange={(e) => setEditSsoEnabled(e.target.checked)}
                    className="accent-(--accent-blue)"
                  />
                  SSO enabled
                </label>
                <button
                  onClick={() => handleUpdate(org.companyCode)}
                  className="p-1.5 rounded-md bg-(--accent-green)/15 text-(--accent-green) hover:bg-(--accent-green)/25 transition-colors cursor-pointer"
                >
                  <Check className="w-4 h-4" />
                </button>
                <button
                  onClick={() => setEditingCode(null)}
                  className="p-1.5 rounded-md bg-(--secondary) text-(--muted-foreground) hover:text-(--foreground) transition-colors cursor-pointer"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>

                <div className="grid gap-2 md:grid-cols-2">
                  <input
                    className={inputClass}
                    value={editSamlMetadataURL}
                    onChange={(e) => setEditSamlMetadataURL(e.target.value)}
                    placeholder="SAML metadata URL"
                  />
                  <input
                    className={inputClass}
                    value={editSamlEntityId}
                    onChange={(e) => setEditSamlEntityId(e.target.value)}
                    placeholder="SAML entity ID"
                  />
                </div>

                <textarea
                  className={`${inputClass} w-full min-h-18 font-mono text-xs`}
                  value={editSamlAttributeMapping}
                  onChange={(e) => setEditSamlAttributeMapping(e.target.value)}
                  placeholder='Attribute mapping JSON, e.g. {"email":"mail","name":"displayName"}'
                />
              </div>
            ) : (
              /* Display mode */
              <div className="flex items-center gap-3">
                <div className="flex-1 min-w-0">
                  <span className="text-sm font-medium text-(--foreground)">{org.companyName}</span>
                  <span className="ml-2 px-2 py-0.5 rounded-md text-[11px] font-bold bg-(--accent-purple)/15 text-(--accent-purple) tracking-wider">
                    {org.companyCode}
                  </span>
                  <span className={`ml-2 inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[11px] font-semibold ${org.ssoEnabled ? "bg-(--accent-green)/15 text-(--accent-green)" : "bg-(--secondary) text-(--muted-foreground)"}`}>
                    <ShieldCheck className="w-3 h-3" /> {org.ssoEnabled ? "SSO" : "PIN"}
                  </span>
                  {org.ssoEnabled && (
                    <div className="mt-1 text-[11px] text-(--muted-foreground) truncate">
                      {org.samlEntityId || "(no entity ID)"}
                    </div>
                  )}
                </div>

                <span className="flex items-center gap-1 text-xs text-(--muted-foreground) shrink-0">
                  <Users className="w-3 h-3" /> {org.userCount}
                </span>

                <button
                  onClick={() => {
                    setEditingCode(org.companyCode);
                    setEditName(org.companyName);
                    setEditCode(org.companyCode);
                    setEditSsoEnabled(!!org.ssoEnabled);
                    setEditSamlMetadataURL(org.samlMetadataUrl ?? "");
                    setEditSamlEntityId(org.samlEntityId ?? "");
                    setEditSamlAttributeMapping(org.samlAttributeMapping ? JSON.stringify(org.samlAttributeMapping, null, 2) : "");
                  }}
                  className="p-1.5 rounded-md text-(--muted-foreground) hover:text-(--accent-blue) hover:bg-(--accent-blue)/10 transition-colors cursor-pointer"
                  title="Edit"
                >
                  <Pencil className="w-3.5 h-3.5" />
                </button>

                {deletingCode === org.companyCode ? (
                  <div className="flex items-center gap-1">
                    <button
                      onClick={() => handleDelete(org.companyCode)}
                      className="px-2 py-1 rounded-md text-xs font-semibold bg-(--accent-red) text-white hover:opacity-90 transition-opacity cursor-pointer"
                    >
                      Confirm
                    </button>
                    <button
                      onClick={() => setDeletingCode(null)}
                      className="px-2 py-1 rounded-md text-xs text-(--muted-foreground) hover:text-(--foreground) cursor-pointer"
                    >
                      Cancel
                    </button>
                  </div>
                ) : (
                  <button
                    onClick={() => handleDelete(org.companyCode)}
                    className="p-1.5 rounded-md text-(--muted-foreground) hover:text-(--accent-red) hover:bg-(--accent-red)/10 transition-colors cursor-pointer"
                    title="Delete"
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
            className={`${inputClass} flex-1 min-w-30`}
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
            className="flex items-center gap-1 px-3 py-1.5 rounded-lg text-sm font-semibold bg-(--accent-blue) text-white hover:opacity-90 transition-opacity cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <Plus className="w-4 h-4" />
            {creating ? "Adding..." : "Add"}
          </button>
        </div>
      </form>
    </div>
  );
}
