import { Suspense } from "react";
import { getTranslations } from "next-intl/server";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { hostedSubrouterCutoverReadyForTeam } from "@/services/subrouter/cutover";
import { createHostedSubrouterClient } from "@/services/subrouter/hostedClient";
import {
  authorizedSubrouterTeams,
} from "@/services/subrouter/routeHelpers";
import {
  isSubrouterAuthorizationError,
  SubrouterAuthorizationUnavailableError,
  verifySubrouterRequest,
  withSubrouterAuthorizationDeadline,
} from "@/services/vms/auth";
import {
  loadCoderouterTeamMetrics,
  type CoderouterTeamMetrics,
} from "@/services/coderouter/teamMetrics";
import { loadMachineUsage, MachineUsageSection } from "./machine-usage";
import {
  coderouterOrganizationFromCookieHeader,
} from "@/services/coderouter/organizationScope";
import { listClaudeAccounts } from "@/services/coderouter/claudeUpstream";
import {
  CoderouterAccountsSection,
  type ClaudeAccountsState,
  type SharedAccountsState,
} from "../components/coderouter-accounts";
import { CoderouterPageHeader } from "../components/dashboard-page-headers";
import { withPrioritySpan } from "@/services/telemetry";
import { withStackAuthSpan } from "@/services/auth/stackTelemetry";

// The page resolves as one server render. Keeping the auth and data work in
// this Suspense boundary prevents a header-only response while the private
// content is still loading.
export const instant = true;
// The page reads the live browser session and team grants. Do not put a
// private RSC response in the prefetch cache before the click is authorized.
export const prefetch = "force-disabled";

type PageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ team?: string | string[] }>;
};

type DashboardTeam = {
  readonly id: string;
  readonly name: string;
  readonly use: boolean;
  readonly manageAccounts: boolean;
  readonly personal: boolean;
};

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "dashboard.coderouter" });
  const alternates = buildAlternates(locale, "/dashboard/coderouter");
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default function CoderouterOverviewPage(props: PageProps) {
  if (!isStackConfigured()) {
    redirect("/");
  }

  return (
    <Suspense fallback={null}>
      <ResolvedCoderouterOverviewContent {...props} />
    </Suspense>
  );
}

async function ResolvedCoderouterOverviewContent({ params, searchParams }: PageProps) {
  // Framework promises are not stable cache keys across prerender phases.
  const [{ locale }, { team: teamParam }] = await Promise.all([params, searchParams]);
  const team = Array.isArray(teamParam) ? teamParam[0] : teamParam;

  return <CoderouterOverviewContent locale={locale} team={team} />;
}

type CoderouterAuthorization = {
  readonly selectedTeam: DashboardTeam;
  readonly accessToken: string;
};

type CoderouterAuthorizationResult =
  | { readonly kind: "authorized"; readonly value: CoderouterAuthorization }
  | { readonly kind: "missing" }
  | { readonly kind: "noTeams" }
  | { readonly kind: "unavailable" };

export async function CoderouterOverviewContent({
  locale,
  team,
}: {
  locale: string;
  team?: string;
}) {
  // Authorization and the access token are resolved for every request. There
  // is no private page cache here, so a prefetched response cannot outlive a
  // team grant or expose management controls after revocation.
  const requestHeaders = await headers();
  const authorization = await withPrioritySpan(
    "cmux-coderouter-dashboard",
    "cmux.coderouter.auth",
    { "http.route": "/dashboard/coderouter", "cmux.locale": locale },
    () => resolveCoderouterAuthorization(requestHeaders, team),
  );
  if (authorization.kind === "unavailable") {
    return renderCoderouterLoadError(locale);
  }
  if (authorization.kind === "missing") {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/coderouter")));
  }
  if (authorization.kind === "noTeams") {
    redirect("/dashboard");
  }

  const { selectedTeam, accessToken } = authorization.value;
  const [tPage, sharedAccounts, metrics, claudeAccounts, machineUsage] = await Promise.all([
    getTranslations({ locale, namespace: "dashboard.coderouter" }),
    withPrioritySpan(
      "cmux-coderouter-dashboard",
      "cmux.coderouter.accounts",
      { "cmux.team_scope": "selected" },
      () => loadSharedAccounts(selectedTeam, accessToken),
    ),
    withPrioritySpan(
      "cmux-coderouter-dashboard",
      "cmux.coderouter.team_metrics",
      { "cmux.team_scope": "selected" },
      () => loadCoderouterTeamMetrics(selectedTeam.id),
    ),
    withPrioritySpan(
      "cmux-coderouter-dashboard",
      "cmux.coderouter.claude_upstream",
      { "cmux.team_scope": "selected" },
      () => loadClaudeAccounts(selectedTeam.id),
    ),
    withPrioritySpan(
      "cmux-coderouter-dashboard",
      "cmux.coderouter.machine_usage",
      { "cmux.team_scope": "selected" },
      () => loadMachineUsage(selectedTeam.id),
    ),
  ]);

  return (
    <CoderouterPageFrame>
      <TeamMetricsSection
        locale={locale}
        metrics={metrics}
        teamName={selectedTeam.name}
      />

      <CoderouterAccountsSection
        teamId={selectedTeam.id}
        canManage={selectedTeam.manageAccounts}
        claude={claudeAccounts}
        shared={sharedAccounts}
      />

      <MachineUsageSection
        locale={locale}
        t={tPage}
        teamName={selectedTeam.name}
        usage={machineUsage}
      />
    </CoderouterPageFrame>
  );
}

async function resolveCoderouterAuthorization(
  requestHeaders: Headers,
  requestedTeamId: string | undefined,
): Promise<CoderouterAuthorizationResult> {
  try {
    const authenticated = await withSubrouterAuthorizationDeadline(
      async (signal) => {
        const user = await verifySubrouterRequest(
          new Request("https://cmux.com/dashboard/coderouter", {
            headers: Object.fromEntries(requestHeaders.entries()),
          }),
          signal,
          { allowCookie: true, listAllTeams: true },
        );
        if (!user) return null;
        const [authorized, authJson] = await Promise.all([
          authorizedSubrouterTeams(user),
          withStackAuthSpan(
            "get_auth_json",
            () => getStackServerApp().getAuthJson({
              tokenStore: {
                headers: {
                  get: (name: string) => requestHeaders.get(name),
                },
              },
            }),
            { "cmux.auth.flow": "coderouter_dashboard" },
          ).catch(() => {
            throw new SubrouterAuthorizationUnavailableError(
              "Stack session refresh unavailable",
            );
          }),
        ]);
        return {
          user,
          authorized,
          accessToken: authJson?.accessToken ?? null,
        };
      },
    );
    if (!authenticated) return { kind: "missing" };

    const teams = authenticated.authorized
      .filter((candidate) => candidate.use || candidate.manageAccounts)
      .map((candidate) => ({
        id: candidate.teamId,
        name: candidate.teamName,
        use: candidate.use,
        manageAccounts: candidate.manageAccounts,
        personal: candidate.personal,
      }));
    if (teams.length === 0) {
      return { kind: "noTeams" };
    }
    const accessToken = authenticated.accessToken;
    if (!accessToken) return { kind: "missing" };
    const selectedTeam = selectTeam(
      teams,
      requestedTeamId,
      coderouterOrganizationFromCookieHeader(
        requestHeaders.get("cookie"),
        authenticated.user.id,
      ),
      authenticated.user.selectedTeamId,
    );
    return {
      kind: "authorized",
      value: {
        selectedTeam,
        accessToken,
      },
    };
  } catch (error) {
    if (!isSubrouterAuthorizationError(error)) throw error;
    return { kind: "unavailable" };
  }
}

async function renderCoderouterLoadError(locale: string) {
  const t = await getTranslations({ locale, namespace: "dashboard.coderouterAccounts" });
  return (
    <CoderouterPageFrame>
      <StatusPanel title={t("pageErrorTitle")} body={t("pageErrorBody")} />
    </CoderouterPageFrame>
  );
}

function CoderouterPageFrame({ children }: React.PropsWithChildren) {
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <CoderouterPageHeader />
      {children}
    </div>
  );
}

function TeamMetricsSection({
  locale,
  metrics,
  teamName,
}: {
  readonly locale: string;
  readonly metrics: CoderouterTeamMetrics;
  readonly teamName: string;
}) {
  const copy = metricsCopy(locale);
  if (metrics.kind === "unavailable") {
    return (
      <section className="mb-4 border border-border p-3">
        <h2 className="text-sm font-medium">{copy.title}</h2>
        <p className="mt-1 text-xs text-muted">{copy.unavailable}</p>
      </section>
    );
  }

  const number = new Intl.NumberFormat(locale, {
    notation: "compact",
    maximumFractionDigits: 1,
  });
  const currency = new Intl.NumberFormat(locale, {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 2,
  });
  const percent = new Intl.NumberFormat(locale, {
    style: "percent",
    maximumFractionDigits: 0,
  });
  const coverage = metrics.totals.totalTokens > 0
    ? metrics.totals.pricedTokens / metrics.totals.totalTokens
    : 1;
  const maxDailyTokens = Math.max(
    1,
    ...metrics.daily.map((day) => day.totalTokens),
  );

  return (
    <section className="mb-4 border border-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-sm font-medium">{copy.title}</h2>
          <p className="mt-1 text-xs text-muted">
            {copy.scope.replace("{team}", teamName)}
          </p>
        </div>
        <span className="font-mono text-[11px] text-muted">
          {copy.period.replace("{days}", String(metrics.periodDays))}
        </span>
      </div>

      <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-5">
        <MetricCard
          label={copy.tokens}
          value={number.format(metrics.totals.totalTokens)}
        />
        <MetricCard
          label={copy.inputTokens}
          value={number.format(metrics.totals.inputTokens)}
        />
        <MetricCard
          label={copy.outputTokens}
          value={number.format(metrics.totals.outputTokens)}
        />
        <MetricCard
          label={copy.apiEquivalent}
          value={currency.format(metrics.totals.apiEquivalentUsd)}
        />
        <MetricCard
          label={copy.pricingCoverage}
          value={percent.format(coverage)}
        />
      </div>

      <div
        className="mt-3 flex h-24 items-end gap-px border border-border px-2 pt-2"
        role="img"
        aria-label={copy.chartLabel}
      >
        {metrics.daily.map((day) => {
          const height = day.totalTokens === 0
            ? 0
            : Math.max(3, (day.totalTokens / maxDailyTokens) * 100);
          return (
            <div
              key={day.day}
              className="min-w-0 flex-1 bg-foreground/70"
              style={{ height: `${height}%` }}
              title={`${day.day}: ${number.format(day.totalTokens)} ${copy.tokens.toLowerCase()}`}
            />
          );
        })}
      </div>

      <p className="mt-2 text-[11px] leading-5 text-muted">
        {copy.privacy}
      </p>
      <p className="text-[11px] leading-5 text-muted">
        {copy.estimate.replace("{version}", metrics.rateCardVersion)}
      </p>
    </section>
  );
}

function MetricCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="border border-border p-2">
      <div className="text-[11px] text-muted">{label}</div>
      <div className="mt-1 font-mono text-lg tabular-nums">{value}</div>
    </div>
  );
}

function metricsCopy(locale: string) {
  if (locale === "ja") {
    return {
      title: "30日間の使用状況",
      scope: "{team} のチーム集計",
      period: "過去{days}日間",
      inputTokens: "入力トークン",
      outputTokens: "出力トークン",
      tokens: "合計トークン",
      apiEquivalent: "API換算額",
      pricingCoverage: "価格対応率",
      chartLabel: "日別のCodeRouterトークン使用量",
      privacy:
        "プロンプト、出力、アカウントラベル、メンバーIDは記録・表示しません。",
      estimate:
        "API換算額は公開定価（レート表 {version}）による推定で、実際の請求額ではありません。価格不明のモデルは換算額から除外されます。",
      unavailable: "チーム使用状況は現在利用できません。",
    };
  }
  return {
    title: "30-day usage",
    scope: "Team aggregate for {team}",
    period: "Last {days} days",
    inputTokens: "Input tokens",
    outputTokens: "Output tokens",
    tokens: "Total tokens",
    apiEquivalent: "API-equivalent value",
    pricingCoverage: "Pricing coverage",
    chartLabel: "Daily CodeRouter token usage",
    privacy:
      "No prompts, outputs, account labels, or member identities are recorded or shown.",
    estimate:
      "API-equivalent value is an estimate using public list prices (rate card {version}), not actual spend. Models without a known price are excluded.",
    unavailable: "Team usage is temporarily unavailable.",
  };
}

function StatusPanel({ title, body }: { title: string; body: string }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{title}</h2>
      <p className="mt-1 max-w-2xl text-xs text-muted">{body}</p>
    </section>
  );
}

function selectTeam(
  teams: readonly DashboardTeam[],
  requestedTeamId: string | undefined,
  scopedTeamId: string | null,
  selectedTeamId: string | null,
): DashboardTeam {
  const requested = requestedTeamId?.trim();
  if (requested) {
    const selected = teams.find((team) => team.id === requested);
    if (selected) return selected;
  }
  if (scopedTeamId) {
    const scoped = teams.find((team) => team.id === scopedTeamId);
    if (scoped) return scoped;
  }
  if (selectedTeamId) {
    const selected = teams.find((team) => team.id === selectedTeamId);
    if (selected) return selected;
  }
  const personal = teams.find((team) => team.personal);
  if (personal) return personal;
  return teams[0];
}

async function loadSharedAccounts(
  team: DashboardTeam,
  accessToken: string,
): Promise<SharedAccountsState> {
  try {
    if (!await hostedSubrouterCutoverReadyForTeam(team.id)) {
      return { kind: "migrationPending" };
    }
    const client = createHostedSubrouterClient();
    if (!client.tenantControlConfigured) {
      return { kind: "notConfigured" };
    }
    const tenant = await client.exchangeTeam(accessToken, {
      teamId: team.id,
      teamName: team.name,
      use: team.use,
      manageAccounts: team.manageAccounts,
    });
    const accounts = await client.listAccounts(tenant.tenantKey);
    return { kind: "ok", accounts };
  } catch {
    return { kind: "error" };
  }
}

async function loadClaudeAccounts(teamId: string): Promise<ClaudeAccountsState> {
  try {
    return { kind: "ok", accounts: await listClaudeAccounts(teamId) };
  } catch {
    return { kind: "error" };
  }
}
