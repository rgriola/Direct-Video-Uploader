import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  createHashHistory,
  createRootRoute,
  createRoute,
  createRouter,
  Link,
  Navigate,
  Outlet,
  RouterProvider,
  useNavigate,
  type RouterHistory,
} from "@tanstack/react-router";
import { Toaster } from "sonner";
import { AuthProvider, useAuth } from "@/auth/AuthProvider";
import { AdminDashboard } from "@/components/AdminDashboard";
import { Header } from "@/components/Header";
import { LoginForm } from "@/components/LoginForm";
import { UserDashboard } from "@/components/UserDashboard";

type HomePath = "/super" | "/team" | "/videos";

function homeForRole(role: string | undefined): HomePath | null {
  switch (role) {
    case "SUPER_ADMIN": return "/super";
    case "ADMIN": return "/team";
    case "USER": return "/videos";
    default: return null;
  }
}

function AppLayout() {
  const { initializing, loggedIn, user, refreshingAccess, accessError, connected, login, logout, retryAccess } = useAuth();
  const navigate = useNavigate();

  if (initializing) {
    return <p role="status" className="p-6">Restoring your session...</p>;
  }
  if (!loggedIn) {
    return <LoginForm onSuccess={login} />;
  }

  const home = homeForRole(user?.role);
  return (
    <div className="max-w-330 mx-auto px-4 sm:px-6 pt-5 sm:pt-8 pb-12 sm:pb-16">
      <Header
        onLogout={() => {
          logout();
          void navigate({ to: "/", replace: true });
        }}
        userName={user?.name}
        userPhone={user?.phoneNumber}
        userCompany={user?.companyName}
        subtitle={user?.role === "USER" ? "My Videos" : undefined}
      />
      {home && (
        <nav aria-label="Primary navigation" className="mb-6">
          <Link to={home} className="text-(length:--text-sm) font-semibold text-(--accent-blue) hover:underline">
            {user?.role === "USER" ? "My Videos" : "Dashboard"}
          </Link>
        </nav>
      )}

      {(refreshingAccess || accessError) && (
        <div className="mb-6">
          <p role={accessError ? "alert" : "status"}>{accessError ?? "Refreshing dashboard access..."}</p>
          {accessError && (
            <button type="button" className="underline" onClick={retryAccess}>
              {connected ? "Retry access check" : "Retry connection"}
            </button>
          )}
        </div>
      )}

      {!refreshingAccess && user && <main><Outlet /></main>}

      <footer className="mt-16 pt-6 border-t border-(--border-subtle) flex flex-wrap items-center justify-between gap-3">
        <p className="text-xs text-(--foreground)">© 2025 Sea Lion Media LLC. All rights reserved.</p>
        <div className="flex items-center gap-4">
          <a href="/privacy-policy.html" target="_blank" rel="noopener noreferrer" className="text-xs text-(--foreground) hover:underline">
            Privacy Policy
          </a>
          <a href="/privacy-policy.html#support" target="_blank" rel="noopener noreferrer" className="text-xs text-(--foreground) hover:underline">
            Support
          </a>
        </div>
      </footer>
    </div>
  );
}

function ForbiddenPage() {
  const { user } = useAuth();
  const home = homeForRole(user?.role);
  return (
    <section role="alert">
      <h2 className="text-(length:--text-2xl) font-bold">Access denied</h2>
      <p className="mt-2">Your account cannot open this page.</p>
      {home ? (
        <Link to={home} className="mt-3 inline-block text-(--accent-blue) underline">Go to your dashboard</Link>
      ) : (
        <p className="mt-3">Contact an administrator to verify your account role.</p>
      )}
    </section>
  );
}

function NotFoundPage() {
  return (
    <section>
      <h2 className="text-(length:--text-2xl) font-bold">Page not found</h2>
      <p className="mt-2">This page does not exist.</p>
      <Link to="/" className="mt-3 inline-block text-(--accent-blue) underline">Go to your dashboard</Link>
    </section>
  );
}

function HomePage() {
  const { user } = useAuth();
  const home = homeForRole(user?.role);
  return home ? <Navigate to={home} replace /> : <ForbiddenPage />;
}

function SuperAdminPage() {
  const { user } = useAuth();
  return user?.role === "SUPER_ADMIN" ? <AdminDashboard /> : <ForbiddenPage />;
}

function TeamAdminPage() {
  const { user } = useAuth();
  return user?.role === "ADMIN" ? <AdminDashboard /> : <ForbiddenPage />;
}

function VideosPage() {
  const { user } = useAuth();
  return user?.role === "USER" ? <UserDashboard /> : <ForbiddenPage />;
}

const rootRoute = createRootRoute({ component: AppLayout, notFoundComponent: NotFoundPage });
const indexRoute = createRoute({ getParentRoute: () => rootRoute, path: "/", component: HomePage });
const superRoute = createRoute({ getParentRoute: () => rootRoute, path: "/super", component: SuperAdminPage });
const teamRoute = createRoute({ getParentRoute: () => rootRoute, path: "/team", component: TeamAdminPage });
const videosRoute = createRoute({ getParentRoute: () => rootRoute, path: "/videos", component: VideosPage });

const routeTree = rootRoute.addChildren([indexRoute, superRoute, teamRoute, videosRoute]);

export function createAppRouter(history: RouterHistory = createHashHistory()) {
  return createRouter({ routeTree, history });
}

export const router = createAppRouter();

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

export const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 10_000, retry: 1 } },
});

export default function App({ appRouter = router }: { appRouter?: typeof router }) {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <RouterProvider router={appRouter} />
        <Toaster
          position="bottom-right"
          theme="dark"
          toastOptions={{
            style: {
              background: "var(--secondary)",
              border: "1px solid var(--border)",
              color: "var(--foreground)",
              fontFamily: "var(--font-sans)",
            },
          }}
        />
      </AuthProvider>
    </QueryClientProvider>
  );
}
