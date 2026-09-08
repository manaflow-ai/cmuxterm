"use client";

import { Menu } from "@base-ui-components/react/menu";
import { UserAvatar, useUser } from "@stackframe/stack";
import { useLocale, useTranslations } from "next-intl";
import { useState } from "react";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { Link, useRouter } from "@/i18n/navigation";
import { clearCoderouterOrganizationScope } from "@/services/coderouter/organizationScope";
import { useDashboardTeamScope, type DashboardCatalogTeam } from "./dashboard-team-scope";

const menuItemClass =
  "flex min-h-9 w-full cursor-default select-none items-center gap-2 px-2.5 py-2 text-left text-sm text-foreground no-underline outline-none data-[highlighted]:bg-code-bg";

export function DashboardAccountMenu() {
  const t = useTranslations("dashboard.accountMenu");
  const locale = useLocale();
  const router = useRouter();
  const user = useUser({ or: "return-null" });
  const teamScope = useDashboardTeamScope(user?.id ?? null);
  const [signOutPending, setSignOutPending] = useState(false);
  const [signOutError, setSignOutError] = useState(false);
  const signInHref = vaultSignInHref(localizedVaultPath(locale, "/dashboard"));

  if (!user) {
    return (
      <a
        href={signInHref}
        aria-label={t("signIn")}
        className="flex min-w-0 flex-1 items-center gap-2.5 px-1.5 py-1 text-muted hover:bg-code-bg hover:text-foreground"
      >
        <UserAvatar size={24} user={null} />
        <span className="hidden truncate font-medium sm:block">{t("signIn")}</span>
      </a>
    );
  }

  return (
    <div className="flex min-w-0 flex-1 flex-col gap-1">
      <Menu.Root>
        <Menu.Trigger
          className="flex w-full min-w-0 items-center gap-2.5 px-1.5 py-1 text-left outline-none hover:bg-code-bg focus-visible:bg-code-bg"
          aria-label={t("label")}
        >
          <UserAvatar size={24} user={user} />
          <span className="hidden min-w-0 flex-1 sm:block">
            <span className="block truncate font-medium">
              {user.displayName || user.primaryEmail}
            </span>
            {teamScope.status === "ready" ? (
              <span className="block truncate text-[11px] text-muted">
                {teamScope.selected.name}
              </span>
            ) : null}
          </span>
          <ChevronsUpDown />
        </Menu.Trigger>
        <Menu.Portal>
          <Menu.Positioner side="top" align="start" sideOffset={8} className="z-50">
            <Menu.Popup className="w-52 border border-border bg-background p-1 text-foreground shadow-xl shadow-black/10 outline-none">
              <div className="border-b border-border px-2.5 py-2">
                <div className="truncate text-sm font-medium">
                  {user.displayName || user.primaryEmail}
                </div>
                {user.displayName ? (
                  <div className="truncate text-xs text-muted">{user.primaryEmail}</div>
                ) : null}
              </div>
              <Menu.Item render={<Link href="/dashboard/team" />} className={menuItemClass}>
                <SettingsIcon />
                <span>{t("settings")}</span>
              </Menu.Item>
              <Menu.Item render={<Link href="/dashboard/billing" />} className={menuItemClass}>
                <BillingIcon />
                <span>{t("billing")}</span>
              </Menu.Item>
              {teamScope.status === "ready" ? (
                <TeamSubmenu
                  teams={teamScope.teams}
                  selected={teamScope.selected}
                  onSelect={teamScope.switchTeam}
                />
              ) : null}
              <Menu.Separator className="mx-1 my-1 h-px bg-border" />
              <Menu.Item
                className={`${menuItemClass} text-red-600 dark:text-red-400`}
                disabled={signOutPending}
                onClick={async (event) => {
                  event.preventDefault();
                  if (signOutPending) return;
                  setSignOutPending(true);
                  setSignOutError(false);
                  try {
                    await user.signOut();
                    clearCoderouterOrganizationScope();
                    router.replace("/");
                    router.refresh();
                  } catch {
                    setSignOutPending(false);
                    setSignOutError(true);
                  }
                }}
              >
                <SignOutIcon />
                <span>{signOutPending ? t("signingOut") : t("signOut")}</span>
              </Menu.Item>
              {signOutError ? (
                <p role="alert" className="px-2.5 py-1.5 text-xs text-red-600 dark:text-red-400">
                  {t("signOutError")}
                </p>
              ) : null}
            </Menu.Popup>
          </Menu.Positioner>
        </Menu.Portal>
      </Menu.Root>
    </div>
  );
}

/**
 * The team scope lives inside the account menu so one control at the bottom
 * left owns identity and team. Every permitted team is listed, the current
 * one is checked, and picking another persists the dashboard-wide scope.
 */
function TeamSubmenu({
  teams,
  selected,
  onSelect,
}: {
  readonly teams: readonly DashboardCatalogTeam[];
  readonly selected: DashboardCatalogTeam;
  readonly onSelect: (team: DashboardCatalogTeam) => void;
}) {
  const t = useTranslations("dashboard.teamSwitcher");
  return (
    <Menu.SubmenuRoot>
      <Menu.SubmenuTrigger className={`${menuItemClass} justify-between`} aria-label={t("label")}>
        <span className="flex min-w-0 items-center gap-2">
          <TeamIcon />
          <span className="min-w-0">
            <span className="block text-sm">{t("label")}</span>
            <span className="block truncate text-xs text-muted">{selected.name}</span>
          </span>
        </span>
        <ChevronRight />
      </Menu.SubmenuTrigger>
      <Menu.Portal>
        <Menu.Positioner side="right" align="end" sideOffset={4} className="z-50">
          <Menu.Popup className="w-56 border border-border bg-background p-1 text-foreground shadow-xl shadow-black/10 outline-none">
            {teams.map((team) => (
              <Menu.Item
                key={team.id}
                className={menuItemClass}
                aria-checked={team.id === selected.id}
                onClick={() => onSelect(team)}
              >
                <span className="min-w-0 flex-1 truncate">{team.name}</span>
                {team.personal ? (
                  <span className="shrink-0 text-[11px] text-muted">{t("personal")}</span>
                ) : null}
                {team.id === selected.id ? <CheckIcon /> : <span className="size-4 shrink-0" />}
              </Menu.Item>
            ))}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.SubmenuRoot>
  );
}

function TeamIcon() {
  return (
    <svg aria-hidden="true" className="size-4" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
      <circle cx="5.5" cy="5.5" r="2" />
      <circle cx="11" cy="6.5" r="1.75" />
      <path d="M1.75 12.5c.5-2 1.9-3 3.75-3s3.25 1 3.75 3M9.5 12.5c.35-1.4 1.1-2.1 2.25-2.1 1.2 0 2.05.7 2.5 2.1" />
    </svg>
  );
}

function ChevronRight() {
  return (
    <svg aria-hidden="true" className="size-3.5 shrink-0 text-muted" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round">
      <path d="m6 4 4 4-4 4" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg aria-hidden="true" className="size-4 shrink-0" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="m3 8.5 3 3 7-7" />
    </svg>
  );
}

function ChevronsUpDown() {
  return (
    <svg
      aria-hidden="true"
      className="hidden size-3.5 shrink-0 text-muted sm:block"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.25"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="m5 6 3-3 3 3" />
      <path d="m5 10 3 3 3-3" />
    </svg>
  );
}

function SettingsIcon() {
  return (
    <svg aria-hidden="true" className="size-4" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
      <circle cx="8" cy="8" r="2.25" />
      <path d="M8 1.75v1.5M8 12.75v1.5M1.75 8h1.5M12.75 8h1.5M3.6 3.6l1.05 1.05M11.35 11.35l1.05 1.05M12.4 3.6l-1.05 1.05M4.65 11.35 3.6 12.4" />
    </svg>
  );
}

function BillingIcon() {
  return (
    <svg aria-hidden="true" className="size-4" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
      <rect x="1.75" y="3.25" width="12.5" height="9.5" />
      <path d="M1.75 6h12.5M4 10h2.5" />
    </svg>
  );
}

function SignOutIcon() {
  return (
    <svg aria-hidden="true" className="size-4" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
      <path d="M6.75 2.25h-3.5v11.5h3.5M9.25 5l3 3-3 3M12 8H6" />
    </svg>
  );
}
