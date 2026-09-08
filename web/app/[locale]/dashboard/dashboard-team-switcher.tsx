"use client";

import { Menu } from "@base-ui-components/react/menu";
import { useUser } from "@stackframe/stack";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useTranslations } from "next-intl";
import { useSearchParams } from "next/navigation";
import { usePathname, useRouter } from "@/i18n/navigation";
import { persistCoderouterOrganizationScope } from "@/services/coderouter/organizationScope";

export type DashboardTeamCatalog = {
  readonly selectedTeamId: string | null;
  readonly teams: readonly DashboardCatalogTeam[];
};

export type DashboardCatalogTeam = {
  readonly id: string;
  readonly name: string;
  readonly personal: boolean;
  readonly permissions: {
    readonly use: boolean;
    readonly manageAccounts: boolean;
  };
};

const CATALOG_TIMEOUT_MS = 10_000;

const menuItemClass =
  "flex min-h-9 w-full cursor-default select-none items-center gap-2 px-2.5 py-2 text-left text-sm text-foreground outline-none data-[highlighted]:bg-code-bg";

/**
 * The dashboard-wide team scope, shown at the bottom of the sidebar. Every
 * team-scoped page reads the same persisted scope on the server, so switching
 * here changes what the whole dashboard shows without a page-level picker.
 */
export function DashboardTeamSwitcher() {
  const t = useTranslations("dashboard.teamSwitcher");
  const user = useUser({ or: "return-null" });
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const queryClient = useQueryClient();
  const queryKey = ["dashboard-team-catalog", user?.id ?? null] as const;
  const { data, isPending } = useQuery({
    queryKey,
    queryFn: ({ signal }) => loadTeamCatalog(signal),
    enabled: user !== null,
    staleTime: 0,
    refetchOnWindowFocus: "always",
    refetchOnReconnect: "always",
  });

  if (!user) return null;
  if (isPending) {
    return <div aria-hidden="true" className="h-8 w-full animate-pulse bg-code-bg" />;
  }
  if (!data) return null;

  const teams = permittedTeams(data);
  if (teams.length === 0) return null;
  const selected = selectedTeam(teams, data.selectedTeamId, searchParams.get("team"));

  const switchTeam = (team: DashboardCatalogTeam) => {
    if (team.id === selected.id) return;
    // The scope cookie is what the server reads. Persisting it before the
    // refresh means the very next render already shows the chosen team.
    persistCoderouterOrganizationScope(user.id, team.id);
    queryClient.setQueryData<DashboardTeamCatalog>(
      queryKey,
      (current) => current ? { ...current, selectedTeamId: team.id } : current,
    );
    if (searchParams.has("team")) {
      // A deep-linked team in the URL would keep overriding the new scope.
      router.replace(pathname);
    }
    router.refresh();
  };

  return (
    <div className="min-w-0">
      <Menu.Root>
        <Menu.Trigger
          aria-label={t("label")}
          className="flex w-full min-w-0 items-center gap-2 px-1.5 py-1 text-left outline-none hover:bg-code-bg focus-visible:bg-code-bg"
        >
          <TeamGlyph name={selected.name} />
          <span className="min-w-0 flex-1 truncate text-xs">
            <span className="block truncate font-medium">{selected.name}</span>
            <span className="block truncate text-[11px] text-muted">
              {selected.personal ? t("personal") : t("team")}
            </span>
          </span>
          <ChevronsUpDown />
        </Menu.Trigger>
        <Menu.Portal>
          <Menu.Positioner side="top" align="start" sideOffset={8} className="z-50">
            <Menu.Popup className="w-56 border border-border bg-background p-1 text-foreground shadow-xl shadow-black/10 outline-none">
              <div className="px-2.5 py-1.5 text-[11px] font-semibold text-muted">{t("label")}</div>
              {teams.map((team) => (
                <Menu.Item
                  key={team.id}
                  className={menuItemClass}
                  onClick={() => switchTeam(team)}
                >
                  <TeamGlyph name={team.name} />
                  <span className="min-w-0 flex-1 truncate">{team.name}</span>
                  {team.personal ? (
                    <span className="shrink-0 text-[11px] text-muted">{t("personal")}</span>
                  ) : null}
                  {team.id === selected.id ? <CheckIcon /> : <span className="size-3.5 shrink-0" />}
                </Menu.Item>
              ))}
            </Menu.Popup>
          </Menu.Positioner>
        </Menu.Portal>
      </Menu.Root>
    </div>
  );
}

/** Teams the dashboard can show: route users and account-only managers. */
export function permittedTeams(catalog: DashboardTeamCatalog): readonly DashboardCatalogTeam[] {
  return catalog.teams.filter(
    (team) => team.permissions.use || team.permissions.manageAccounts,
  );
}

/**
 * Mirrors the server: an explicit `?team=` deep link wins, then the persisted
 * scope the catalog already resolved, then the personal team, then the first.
 */
export function selectedTeam(
  teams: readonly DashboardCatalogTeam[],
  catalogSelectedId: string | null,
  requestedId: string | null,
): DashboardCatalogTeam {
  const requested = requestedId?.trim();
  const byRequest = requested ? teams.find((team) => team.id === requested) : undefined;
  if (byRequest) return byRequest;
  const byCatalog = catalogSelectedId
    ? teams.find((team) => team.id === catalogSelectedId)
    : undefined;
  if (byCatalog) return byCatalog;
  return teams.find((team) => team.personal) ?? teams[0];
}

async function loadTeamCatalog(cancellationSignal: AbortSignal): Promise<DashboardTeamCatalog> {
  const response = await fetch("/api/subrouter/teams", {
    headers: { accept: "application/json" },
    signal: AbortSignal.any([cancellationSignal, AbortSignal.timeout(CATALOG_TIMEOUT_MS)]),
  });
  if (!response.ok) throw new Error("Could not load dashboard teams");
  const parsed = parseTeamCatalog(await response.json());
  if (!parsed) throw new Error("Invalid dashboard team response");
  return parsed;
}

export function parseTeamCatalog(value: unknown): DashboardTeamCatalog | null {
  if (!isPlainRecord(value) || !Array.isArray(value.teams)) return null;
  const selectedTeamId = value.selectedTeamId;
  if (selectedTeamId !== null && !validText(selectedTeamId)) return null;
  const teams: DashboardCatalogTeam[] = [];
  const seen = new Set<string>();
  for (const raw of value.teams) {
    if (
      !isPlainRecord(raw) ||
      !validText(raw.id) ||
      !validText(raw.name) ||
      typeof raw.personal !== "boolean" ||
      !isPlainRecord(raw.permissions) ||
      typeof raw.permissions.use !== "boolean" ||
      typeof raw.permissions.manageAccounts !== "boolean" ||
      seen.has(raw.id)
    ) {
      return null;
    }
    seen.add(raw.id);
    teams.push({
      id: raw.id,
      name: raw.name,
      personal: raw.personal,
      permissions: {
        use: raw.permissions.use,
        manageAccounts: raw.permissions.manageAccounts,
      },
    });
  }
  return { selectedTeamId, teams };
}

function validText(value: unknown): value is string {
  return typeof value === "string" &&
    value.length > 0 &&
    value.length <= 200 &&
    value === value.trim();
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function TeamGlyph({ name }: { readonly name: string }) {
  const initial = [...name.trim()][0]?.toUpperCase() ?? "?";
  return (
    <span
      aria-hidden="true"
      className="flex size-6 shrink-0 items-center justify-center border border-border bg-code-bg font-mono text-[11px] text-foreground"
    >
      {initial}
    </span>
  );
}

function ChevronsUpDown() {
  return (
    <svg
      aria-hidden="true"
      className="size-3.5 shrink-0 text-muted"
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

function CheckIcon() {
  return (
    <svg
      aria-hidden="true"
      className="size-3.5 shrink-0"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="m3 8.5 3 3 7-7" />
    </svg>
  );
}
