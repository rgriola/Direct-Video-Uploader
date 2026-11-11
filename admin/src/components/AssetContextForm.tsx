import { useId, useState, type FormEvent } from "react";

export interface AssetContextValues {
  slug: string;
  type: "Raw" | "Cut";
  description: string;
  priority: "Low" | "Medium" | "High" | "Critical";
}

const PRIORITIES: AssetContextValues["priority"][] = ["Low", "Medium", "High", "Critical"];
const fieldClass = "w-full px-2 py-1 rounded-(--radius-md) text-(length:--text-sm) bg-(--card) border border-(--border) text-(--foreground) aria-invalid:border-(--accent-red)";

/** Mirrors the server's slug sanitizer: ASCII letters, numbers, dashes, periods, and spaces. */
function sanitizeSlug(value: string) {
  return value.replace(/[^a-zA-Z0-9\-. ]/g, "");
}

export function AssetContextForm({ onSubmit }: { onSubmit: (values: AssetContextValues) => Promise<void> }) {
  const id = useId();
  const [values, setValues] = useState<AssetContextValues>({ slug: "", type: "Raw", description: "", priority: "Low" });
  const [attempted, setAttempted] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const slugMissing = !values.slug.trim();
  const descriptionMissing = !values.description.trim();

  async function submit(event: FormEvent) {
    event.preventDefault();
    setAttempted(true);
    if (slugMissing || descriptionMissing) return;
    setSaving(true);
    setError(null);
    try {
      await onSubmit({ ...values, slug: values.slug.trim(), description: values.description.trim() });
    } catch (submitError) {
      setError(submitError instanceof Error ? submitError.message : "Unknown error");
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={submit} noValidate aria-label="Context form" className="mb-4 flex flex-col gap-3 text-(length:--text-xs)">
      <div>
        <label htmlFor={`${id}-slug`} className="font-semibold">Slug</label>
        <input
          id={`${id}-slug`}
          className={fieldClass}
          maxLength={50}
          value={values.slug}
          aria-invalid={attempted && slugMissing}
          aria-describedby={attempted && slugMissing ? `${id}-slug-error` : undefined}
          onChange={event => setValues({ ...values, slug: sanitizeSlug(event.target.value) })}
        />
        {attempted && slugMissing && <p id={`${id}-slug-error`} className="text-(--accent-red)">Slug is required.</p>}
      </div>
      <div>
        <label htmlFor={`${id}-type`} className="font-semibold">Type</label>
        <select
          id={`${id}-type`}
          className={fieldClass}
          value={values.type}
          onChange={event => setValues({ ...values, type: event.target.value as AssetContextValues["type"] })}
        >
          <option value="Raw">Raw</option>
          <option value="Cut">Cut</option>
        </select>
      </div>
      <div>
        <label htmlFor={`${id}-description`} className="font-semibold">Description</label>
        <textarea
          id={`${id}-description`}
          className={fieldClass}
          rows={3}
          maxLength={500}
          value={values.description}
          aria-invalid={attempted && descriptionMissing}
          aria-describedby={attempted && descriptionMissing ? `${id}-description-error` : undefined}
          onChange={event => setValues({ ...values, description: event.target.value })}
        />
        {attempted && descriptionMissing && (
          <p id={`${id}-description-error`} className="text-(--accent-red)">Description is required.</p>
        )}
      </div>
      <fieldset>
        <legend className="font-semibold">Priority</legend>
        <div className="flex flex-wrap gap-3">
          {PRIORITIES.map(priority => (
            <label key={priority} className="inline-flex items-center gap-1">
              <input
                type="radio"
                name={`${id}-priority`}
                value={priority}
                checked={values.priority === priority}
                onChange={() => setValues({ ...values, priority })}
              />
              {priority}
            </label>
          ))}
        </div>
      </fieldset>
      {error && <p role="alert" className="text-(--accent-red)">Could not save the form: {error}</p>}
      <button
        type="submit"
        disabled={saving}
        className="self-start px-3 py-1 rounded-(--radius-md) bg-(--card) border border-(--border) text-(--foreground) hover:bg-(--card-hover) disabled:opacity-50"
      >
        {saving ? "Saving…" : "Save context"}
      </button>
    </form>
  );
}
