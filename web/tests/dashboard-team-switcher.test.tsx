import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";

type Catalog = {
  selectedTeamId: string | null;
  teams: Array<{
    id: string;
    name: string;
    personal: boolean;
    permissions: { use: boolean; manageAccounts: boolean };
  }>;
};

let catalog: Catalog | undefined;
let pending = false;
let currentUser: { id: string } | null = { id: "user-1" };
let searchTeam: string | null = null;

mock.module("@stackframe/stack", () => ({
  useUser: () => currentUser,
}));

mock.module("@tanstack/react-query", () => ({
  useQuery: () => ({ data: catalog, isPending: pending }),
  useQueryClient: () => ({ setQueryData: () => undefined }),
}));

mock.module("next-intl", () => ({
  useTranslations: () => (key: string) => key,
}));

mock.module("next/navigation", () => ({
  useSearchParams: () => ({
    get: (name: string) => (name === "team" ? searchTeam : null),
    has: (name: string) => name === "team" && searchTeam !== null,
  }),
}));

mock.module("@/i18n/navigation", () => ({
  usePathname: () => "/dashboard/coderouter",
  useRouter: () => ({ replace: () => undefined, refresh: () => undefined }),
}));

mock.module("@base-ui-components/react/menu", () => ({
  Menu: {
    Root: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Trigger: ({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
      <button {...props}>{children}</button>
    ),
    Portal: ({ children }: { children: React.ReactNode }) => <>{children}</>,
    Positioner: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Popup: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Item: ({ children, ...props }: React.HTMLAttributes<HTMLElement>) => (
      <button data-testid="team-option" {...props}>{children}</button>
    ),
  },
}));

const { DashboardTeamSwitcher, parseTeamCatalog, selectedTeam, permittedTeams } = await import(
  "../app/[locale]/dashboard/dashboard-team-switcher"
);

const twoTeams: Catalog = {
  selectedTeamId: "team-2",
  teams: [
    {
      id: "user-1",
      name: "Lawrence",
      personal: true,
      permissions: { use: true, manageAccounts: true },
    },
    {
      id: "team-2",
      name: "Manaflow",
      personal: false,
      permissions: { use: true, manageAccounts: true },
    },
    {
      id: "team-3",
      name: "No access",
      personal: false,
      permissions: { use: false, manageAccounts: false },
    },
  ],
};

describe("dashboard team switcher", () => {
  test("shows the persisted team as the current scope and lists only permitted teams", () => {
    catalog = twoTeams;
    pending = false;
    searchTeam = null;

    const html = renderToStaticMarkup(<DashboardTeamSwitcher />);

    expect(html).toContain("Manaflow");
    expect(html.match(/data-testid="team-option"/g)).toHaveLength(2);
    expect(html).not.toContain("No access");
    // The trigger names the selected team before the option list does.
    expect(html.indexOf("Manaflow")).toBeLessThan(html.indexOf('data-testid="team-option"'));
  });

  test("lets a ?team= deep link win over the persisted scope, like the server", () => {
    catalog = twoTeams;
    searchTeam = "user-1";

    const html = renderToStaticMarkup(<DashboardTeamSwitcher />);

    expect(html.indexOf("Lawrence")).toBeLessThan(html.indexOf('data-testid="team-option"'));
  });

  test("renders a placeholder while loading and nothing when signed out", () => {
    catalog = undefined;
    pending = true;
    expect(renderToStaticMarkup(<DashboardTeamSwitcher />)).toContain("animate-pulse");

    pending = false;
    currentUser = null;
    expect(renderToStaticMarkup(<DashboardTeamSwitcher />)).toBe("");
    currentUser = { id: "user-1" };
  });

  test("selection order matches the coderouter page", () => {
    const teams = permittedTeams(twoTeams);
    expect(teams.map((team) => team.id)).toEqual(["user-1", "team-2"]);
    expect(selectedTeam(teams, "team-2", null).id).toBe("team-2");
    expect(selectedTeam(teams, "team-2", "user-1").id).toBe("user-1");
    expect(selectedTeam(teams, "stale", "missing").id).toBe("user-1");
    expect(selectedTeam(teams, null, null).id).toBe("user-1");
  });

  test("rejects malformed catalogs instead of rendering them", () => {
    expect(parseTeamCatalog({ selectedTeamId: null, teams: [] })).toEqual({
      selectedTeamId: null,
      teams: [],
    });
    expect(parseTeamCatalog({ teams: [{ id: "a" }] })).toBeNull();
    expect(
      parseTeamCatalog({
        selectedTeamId: null,
        teams: [twoTeams.teams[0], twoTeams.teams[0]],
      }),
    ).toBeNull();
    expect(parseTeamCatalog({ selectedTeamId: " padded ", teams: [] })).toBeNull();
  });
});
