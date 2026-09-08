import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";

let currentUser: {
  id: string;
  displayName: string;
  primaryEmail: string;
  signOut: () => Promise<void>;
} | null = null;
const routerPush = mock(() => undefined);
const routerReplace = mock(() => undefined);
const routerRefresh = mock(() => undefined);

mock.module("@stackframe/stack", () => ({
  useUser: () => currentUser,
  UserAvatar: ({ size }: { size: number }) => (
    <span data-testid="avatar" data-size={size} />
  ),
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
    Item: ({
      children,
      render,
      ...props
    }: React.HTMLAttributes<HTMLElement> & { render?: React.ReactElement }) =>
      render
        ? <span {...props}>{render}{children}</span>
        : <button {...props}>{children}</button>,
    Separator: () => <hr />,
    SubmenuRoot: ({ children }: { children: React.ReactNode }) => <div data-testid="team-submenu">{children}</div>,
    SubmenuTrigger: ({ children, ...props }: React.HTMLAttributes<HTMLElement>) => (
      <button {...props}>{children}</button>
    ),
  },
}));

let resolvedTheme = "dark";
const themeToggle = mock(() => undefined);
mock.module("@/app/[locale]/theme", () => ({
  useThemeToggle: () => ({ resolvedTheme, toggle: themeToggle }),
}));

let teamScope: unknown = { status: "unavailable" };
mock.module("../app/[locale]/dashboard/dashboard-team-scope", () => ({
  useDashboardTeamScope: () => teamScope,
}));

mock.module("next/navigation", () => ({
  ...createNextNavigationMock((target: unknown) => {
    throw new Error(`redirect:${target}`);
  }),
}));

mock.module("next-intl", () => ({
  useLocale: () => "en",
  useTranslations: () => (key: string) => key,
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({
    href,
    children,
    ...props
  }: React.AnchorHTMLAttributes<HTMLAnchorElement> & { href: string }) => (
    <a href={href} {...props}>{children}</a>
  ),
  useRouter: () => ({
    push: routerPush,
    replace: routerReplace,
    refresh: routerRefresh,
  }),
}));

const { DashboardAccountMenu } = await import(
  "../app/[locale]/dashboard/dashboard-account-menu"
);

describe("dashboard account menu", () => {
  test("matches the chatmux identity row and exposes the account menu", () => {
    currentUser = {
      id: "user-lawrence",
      displayName: "Lawrence",
      primaryEmail: "lawrence@example.com",
      signOut: async () => undefined,
    };
    const html = renderToStaticMarkup(<DashboardAccountMenu />);

    expect(html).toContain("Lawrence");
    expect(html).toContain("lawrence@example.com");
    expect(html).toContain('data-size="24"');
    expect(html).toContain('href="/dashboard/team"');
    expect(html).toContain('href="/dashboard/billing"');
    expect(html).toContain("signOut");
    // Without a team catalog the menu has no team entry at all.
    expect(html).not.toContain("team-submenu");
  });

  test("offers the theme switch inside the menu, named after the theme it switches to", () => {
    currentUser = {
      id: "user-lawrence",
      displayName: "Lawrence",
      primaryEmail: "lawrence@example.com",
      signOut: async () => undefined,
    };
    resolvedTheme = "dark";
    expect(renderToStaticMarkup(<DashboardAccountMenu />)).toContain(">themeLight<");
    resolvedTheme = "light";
    const html = renderToStaticMarkup(<DashboardAccountMenu />);
    expect(html).toContain(">themeDark<");
    expect(html.indexOf(">themeDark<")).toBeGreaterThan(html.indexOf("/dashboard/team"));
    expect(html.indexOf(">themeDark<")).toBeLessThan(html.indexOf("/dashboard/billing"));
  });

  test("lists every permitted team in a submenu and shows the current one on the trigger", () => {
    currentUser = {
      id: "user-lawrence",
      displayName: "Lawrence",
      primaryEmail: "lawrence@example.com",
      signOut: async () => undefined,
    };
    const teams = [
      { id: "user-lawrence", name: "Lawrence", personal: true, permissions: { use: true, manageAccounts: true } },
      { id: "team-2", name: "Manaflow", personal: false, permissions: { use: true, manageAccounts: true } },
      { id: "team-3", name: "Side project", personal: false, permissions: { use: true, manageAccounts: false } },
    ];
    teamScope = { status: "ready", teams, selected: teams[1], switchTeam: () => undefined };
    const html = renderToStaticMarkup(<DashboardAccountMenu />);
    teamScope = { status: "unavailable" };

    expect(html.match(/data-testid="team-submenu"/g)).toHaveLength(1);
    const submenu = html.slice(html.indexOf('data-testid="team-submenu"'));
    expect(submenu).toContain("Manaflow");
    expect(submenu).toContain("Side project");
    expect(submenu).toContain(">Lawrence<");
    expect(submenu.match(/aria-checked="true"/g)).toHaveLength(1);
    expect(submenu.match(/aria-checked="false"/g)).toHaveLength(2);
    // The trigger row names the current team under the user's name.
    expect(html.indexOf("Manaflow")).toBeLessThan(html.indexOf("/dashboard/team"));
    // Order: settings, theme, billing, team, then sign out.
    const order = ["/dashboard/team", ">themeLight<", "/dashboard/billing", 'data-testid="team-submenu"', "signOut"]
      .map((marker) => html.indexOf(marker));
    expect(order.every((index) => index >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
  });

  test("uses the unlocalized auth handler and names the compact sign-in link", () => {
    currentUser = null;
    const html = renderToStaticMarkup(<DashboardAccountMenu />);

    expect(html).toContain('aria-label="signIn"');
    expect(html).toContain('href="/handler/sign-in?');
    expect(html).toContain("dashboard");
    expect(html).not.toContain("/en/handler/sign-in");
  });
});
