import { useState, FormEvent } from "react";
import { login, setToken } from "@/lib/api";
import type { User } from "@/lib/types";

interface LoginFormProps {
  onSuccess: (user: User) => void;
}

export function LoginForm({ onSuccess }: LoginFormProps) {
  const [phoneNumber, setPhoneNumber] = useState("");
  const [pin, setPin] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  /** Strip non-digits and cap at 10 characters */
  const handlePhoneChange = (value: string) => {
    setPhoneNumber(value.replace(/\D/g, "").slice(0, 10));
  };

  /** Strip non-digits and cap at 8 characters */
  const handlePinChange = (value: string) => {
    setPin(value.replace(/\D/g, "").slice(0, 8));
  };

  const isPhoneValid = phoneNumber.length === 10;
  const isPinValid = pin.length > 0;

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!isPhoneValid) {
      setError("Phone number -10 digits");
      return;
    }
    if (!isPinValid) {
      setError("PIN");
      return;
    }
    setError(null);
    setLoading(true);

    try {
      const res = await login(phoneNumber, pin);
      setToken(res.token);
      onSuccess(res.user);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Login failed");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center p-4 bg-[radial-gradient(ellipse_at_top,rgba(74,158,255,0.08)_0%,transparent_60%)]">
      <div className="w-full max-w-sm">
        {/* Logo */}
        <div className="flex items-center gap-4 mb-8">
          <div className="w-16 h-16 rounded-(--radius-2xl) overflow-hidden shadow-[0_8px_32px_color-mix(in_srgb,var(--accent-blue)_30%,transparent)] shrink-0">
            <img
              src="/fixer-icon.png"
              alt="Fixer"
              className="w-full h-full object-cover"
            />
          </div>
          <div className="ml-auto text-right">
            <h1 className="text-(length:--text-2xl) font-bold tracking-tight">Fixer</h1>
            <p className="text-(length:--text-sm) text-(--muted-foreground) mt-1">
              Admin Dashboard
            </p>
          </div>
        </div>

        {/* Form */}
        <form
          onSubmit={handleSubmit}
          className="bg-(--card) border border-(--border) rounded-(--radius-2xl) p-6 space-y-4 shadow-xl"
        >
          <div className="space-y-2">
            <label
              htmlFor="phone"
              className="block text-(length:--text-sm) font-medium text-(--muted-foreground)"
            >
              Phone Number
            </label>
            <input
              id="phone"
              type="tel"
              inputMode="numeric"
              autoComplete="tel"
              pattern="\d{10}"
              required
              value={phoneNumber}
              onChange={(e) => handlePhoneChange(e.target.value)}
              placeholder="e.g. 8001234567"
              maxLength={10}
              className="w-full px-4 py-2 rounded-(--radius-lg) 
              bg-(--secondary) border border-(--border) text-(--foreground) 
              text-(length:--text-sm) placeholder:text-(--muted-foreground) focus:outline-none focus:ring-2 focus:ring-(--accent-blue) focus:border-transparent transition-all"
            />
          </div>

          <div className="space-y-2">
            <label
              htmlFor="pin"
              className="block text-(length:--text-sm) font-medium text-(--muted-foreground)"
            >
              PIN
            </label>
            <input
              id="pin"
              type="password"
              inputMode="numeric"
              autoComplete="current-password"
              required
              value={pin}
              onChange={(e) => handlePinChange(e.target.value)}
              placeholder="••••"
              maxLength={8}
              className="w-full px-4 py-2 rounded-(--radius-lg) bg-(--secondary) border border-(--border) text-(--foreground) text-(length:--text-sm) placeholder:text-(--muted-foreground) focus:outline-none focus:ring-2 focus:ring-(--accent-blue) focus:border-transparent transition-all"
            />
          </div>

          {error && (
            <p className="text-(length:--text-sm) text-(--accent-red) bg-(--accent-red-glow) border border-(--accent-red) rounded-(--radius-lg) px-3 py-2">
              {error}
            </p>
          )}

          <button
            type="submit"
            disabled={loading}
            className="w-full py-2 rounded-(--radius-lg) bg-(--accent-blue) text-white text-(length:--text-sm) font-semibold tracking-wide hover:opacity-90 active:opacity-75 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed cursor-pointer"
          >
            {loading ? "Signing in…" : "Sign In"}
          </button>
        </form>
      </div>
    </div>
  );
}
