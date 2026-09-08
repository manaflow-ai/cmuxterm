import { StackProvider, StackTheme } from "@stackframe/stack";
import { redirect } from "next/navigation";
import { Suspense } from "react";
import {
  DashboardAuthorizationUnavailableError,
  dashboardReturnPath,
  optionalDashboardUser,
  requireDashboardUser,
} from "@/app/lib/dashboard-auth";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { isAdminUser } from "@/services/admin/access";
import { isVaultEnabled } from "@/services/vault/config";
import { DashboardQueryProvider } from "./components/query-provider";
import { DashboardAdminNavGroup } from "./dashboard-admin-nav";
import {
  DashboardAccountMenu,
  DashboardAccountMenuFallback,
} from "./dashboard-account-menu";
import { DashboardShell } from "./dashboard-shell";

// The shell is static. Every session read sits behind its own Suspense
// boundary, so navigations into and between dashboard pages paint the
// sidebar and page frames from the prefetched app shell.
export const instant = true;

export default async function DashboardLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isStackConfigured()) redirect("/");

  return (
    <StackProvider app={getStackServerApp()}>
      <StackTheme>
        <DashboardQueryProvider>
          <DashboardShell
            vaultEnabled={isVaultEnabled()}
            account={
              <Suspense fallback={<DashboardAccountMenuFallback />}>
                <DashboardAccountSlot />
              </Suspense>
            }
            adminNav={
              <Suspense fallback={null}>
                <DashboardAdminNavSlot />
              </Suspense>
            }
          >
            <Suspense fallback={null}>
              <DashboardSessionGuard locale={locale} />
            </Suspense>
            {children}
          </DashboardShell>
        </DashboardQueryProvider>
      </StackTheme>
    </StackProvider>
  );
}

// Streams the identity row once the session resolves; signed-out visitors
// get the sign-in control while the middleware redirect completes.
async function DashboardAccountSlot() {
  const user = await optionalDashboardUser();
  return <DashboardAccountMenu user={user} />;
}

// The admin link is a convenience only; /dashboard/admin and /api/admin/*
// re-check admin membership on the server.
async function DashboardAdminNavSlot() {
  const user = await optionalDashboardUser();
  if (!isAdminUser(user)) return null;
  return <DashboardAdminNavGroup />;
}

// Middleware already turns away requests with no session cookie. This covers
// a cookie whose session Stack rejects, for pages with no private section of
// their own, without holding the page content behind the check.
async function DashboardSessionGuard({ locale }: { locale: string }) {
  try {
    await requireDashboardUser(locale, await dashboardReturnPath());
  } catch (error) {
    // An outage is reported inside each private section. Redirects and
    // unknown failures still propagate.
    if (!(error instanceof DashboardAuthorizationUnavailableError)) throw error;
  }
  return null;
}
