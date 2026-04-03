import { LogOut } from "lucide-react";

interface HeaderProps {
  onLogout: () => void;
  userName?: string | null;
  userPhone?: string | null;
}

export function Header({ onLogout, userName, userPhone }: HeaderProps) {
  return (
    <header className="flex items-center justify-between gap-2 mb-6 pb-5 border-b border-(--border-subtle) sm:mb-8 sm:pb-6 sm:gap-4">
      <div className="flex items-center gap-3 min-w-0 flex-1">
        <div className="w-10 h-10 sm:w-12 sm:h-12 shrink-0 rounded-xl overflow-hidden shadow-[0_4px_16px_rgba(74,158,255,0.25)]">
          <img src="/fixer-icon.png" alt="Fixer" className="w-full h-full object-cover" />
        </div>
        <div className="min-w-0">
          <h1 className="text-xl sm:text-2xl font-bold tracking-tight truncate">Fixer</h1>
          <p className="text-xs text-(--muted-foreground) mt-0.5 hidden sm:block">Server Dashboard · Live Data</p>
        </div>
      </div>

      <div className="flex items-center gap-2 shrink-0">
        {/* Logged-in user identity */}
        {userName && (
          <div className="flex flex-col items-end leading-tight">
            <span className="text-sm sm:text-base font-semibold text-(--foreground) whitespace-nowrap">{userName}</span>
            {userPhone && <span className="text-xs text-(--muted-foreground) mt-0.5 hidden sm:block">{userPhone}</span>}
          </div>
        )}

        {/* Logout button */}
        <button
          onClick={onLogout}
          className="flex items-center gap-1 px-3 py-2 rounded-lg text-sm font-medium bg-(--card) border border-(--border) text-(--muted-foreground) hover:bg-(--card-hover) hover:text-(--accent-red) hover:border-(--accent-red)/50 transition-all cursor-pointer shrink-0"
        >
          <LogOut className="w-3.5 h-3.5" />
        </button>
      </div>
    </header>
  );
}
