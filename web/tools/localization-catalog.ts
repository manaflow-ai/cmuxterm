import { readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  isStructurallySame,
  parse,
  type MessageFormatElement,
} from "@formatjs/icu-messageformat-parser";

export const parityLocales = [
  "en",
  "ja",
  "zh-CN",
  "zh-TW",
  "ko",
  "de",
  "es",
  "fr",
  "ar",
] as const;

export type ParityLocale = (typeof parityLocales)[number];
export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

export type CatalogLeaf = { path: string; value: JsonValue };
export type TranslationEntry = {
  path: string;
  source: string;
  translation?: string;
  placeholders: string[];
  richTextTags: string[];
};

export type CatalogIssue = {
  locale: string;
  path: string;
  message: string;
  source?: string;
  value?: JsonValue;
};

const webRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const messagesDirectory = path.join(webRoot, "messages");

const identityAllowedValues = new Set([
  "Android",
  "Alacritty",
  "API",
  "CLI",
  "Claude",
  "Claude Code",
  "CodeRouter",
  "Codex",
  "CodexBar",
  "Cursor",
  "Devin",
  "Discord",
  "EULA",
  "FAQ",
  "GitHub",
  "Ghostty",
  "GPU",
  "GPU / CPU",
  "Intel",
  "IT",
  "iOS",
  "CPU",
  "GPT 5.6 Sol",
  "Grok Build CLI",
  "Herdr",
  "JSON",
  "Linux",
  "LinkedIn",
  "macOS",
  "MDM",
  "OpenCode",
  "Python",
  "SSH",
  "tmux",
  "Homebrew",
  "cmux SSH",
  "GPU (libghostty)",
  "opencode",
  "OAuth JSON",
  "TUI",
  "Tailscale",
  "Terminal.app",
  "Twitter",
  "Unix",
  "Windows",
  "WireGuard",
  "YouTube",
  "cmux",
  "cmux.json",
  "cmux Cloud",
  "cmux iOS",
  "cmux NIGHTLY",
  "cmux Pro",
  "cmux TUI",
  "coderouter",
  "founders@manaflow.com",
  "oh-my-codex",
  "oh-my-opencode",
  "sk-ant-...",
  "sk-...",
  "you@example.com",
  "Cmd+Control+U",
  "Cmd+Option+U",
  "Cmd+Shift+U",
  "Claude Code Teams - cmux",
  "GitHub Copilot CLI",
  "iOS TestFlight",
  "iTerm2",
  "Node.js",
  "OSC 777 (simple)",
  "PreToolUse",
  "PreToolUse, PermissionRequest",
  "PreToolUse, PostToolUse",
  "Swift/AppKit plus libghostty",
  "WebAuthn",
  "WezTerm",
  "Windsurf",
  "Zed",
  "macOS + Linux + Windows",
  "macOS, Linux",
  "cmux TUI · open source",
  "macOS, Linux, Windows",
  "02 / AGENTS",
  "04 / MACHINES",
  "pre_tool_call, post_tool_call, pre_approval_request, post_approval_response",
  "beforeShellExecution",
  "Pi",
  "San Francisco",
  "Dimension",
  "Isolation",
]);

const identityAllowedPaths = new Set([
  "browserDownloads.windows.name",
  "browserDownloads.linux.name",
  "browserDownloads.linux.requirements",
  "dashboard.nav.coderouterGroup",
  "dashboard.home.coderouterName",
  "dashboard.coderouter.metaTitle",
  "dashboard.coderouter.title",
  "dashboard.billing.plan.pro",
  "dashboard.aiAccounts.providerClaude",
  "dashboard.aiAccounts.providerCodex",
  "dashboard.aiAccounts.oauthJsonField",
  "dashboard.aiAccounts.anthropicKeyPlaceholder",
  "dashboard.aiAccounts.openAiKeyPlaceholder",
  "dashboard.aiAccounts.codexTool",
  "dashboard.aiAccounts.opencodeTool",
  "footer.eula",
  "footer.github",
  "footer.discord",
  "footer.copyright",
  "brandLogoMenu.label",
  "cloudBillingReturn.eyebrow",
  "legal.eula",
  "nightly.title",
  "enterprise.metaTitle",
  "support.channels.email.label",
  "tui.marketing.sectionLabel",
  "tui.marketing.facts.engine.value",
  "tui.docs.title",
]);

const localeIdentityAllowedPaths: Record<string, Set<string>> = {
  de: new Set([
    "dashboard.nav.iosGroup",
    "dashboard.nav.testflight",
    "dashboard.cloud.nameLabel",
    "dashboard.testflight.title",
    "dashboard.testflight.details.status",
    "dashboard.admin.sections.teams",
    "dashboard.admin.results.team",
    "dashboard.admin.access.team",
    "dashboard.admin.plans.team",
    "dashboard.admin.grant.current",
    "dashboard.admin.grant.by",
    "dashboard.aiAccounts.teamSwitcherLabel",
    "dashboard.claudeUpstream.optionalPlaceholder",
    "vault.cliAuth.coderouterEyebrow",
    "vault.sessions.agent",
    "nav.blog",
    "nav.jobs",
    "footer.blog",
    "footer.jobs",
    "footer.twitter",
    "jobs.section",
    "jobs.details",
    "jobs.location",
    "jobs.foundingDesigner.section",
    "jobs.foundingDesigner.details",
    "jobs.foundingDesigner.location",
    "pricing.team.name",
    "community.linkedin",
    "community.categoryLabels.pi",
    "blog.title",
    "blog.metaTitle",
    "blog.tokenMultitasking.metaKeywords.1",
    "blog.tokenMultitasking.metaKeywords.8",
    "blog.passkeyAuth.metaKeywords.2",
    "blog.cmuxSsh.metaTitle",
    "blog.posts.cmuxSsh.title",
    "docs.remoteTmux.mapTmux",
    "docs.gettingStarted.homebrew",
    "docs.sessionRestore.agentHeader",
    "docs.sessionRestore.feedPermissionRequest",
    "docs.sessionRestore.feedPreToolUsePermissionRequest",
    "docs.sessionRestore.feedBeforeShellExecution",
    "docs.sessionRestore.feedPreToolUse",
    "docs.sessionRestore.feedPrePostToolUse",
    "docs.sessionRestore.feedHermes",
    "docs.concepts.tab",
    "docs.concepts.panelTitle",
    "docs.configuration.settingsFile",
    "docs.keyboardShortcuts.cat.app",
    "docs.keyboardShortcuts.cat.browser",
    "docs.keyboardShortcuts.cat.terminal",
    "docs.notifications.python",
    "docs.notifications.nodejs",
    "docs.notifications.hooksJsonTitle",
    "docs.browserAutomation.navigation",
    "docs.browserAutomation.tabsSection",
    "docs.browserAutomation.downloadsSection",
    "docs.skills.markdownName",
    "docs.skills.suggestSshName",
    "docs.ssh.title",
    "docs.ssh.metaTitle",
    "docs.ssh.deepLinkParam",
    "docs.claudeCodeTeams.metaTitle",
    "docs.navItems.ssh",
    "docs.navItems.dock",
    "docs.navItems.textBox",
    "docs.dock.metaTitle",
    "docs.dock.title",
    "docs.textBox.title",
    "docs.textBox.metaTitle",
    "docs.textBox.configTitle",
    "deeplink.section",
    "deeplink.nativeURL",
    "landing.bestTerminal.thTerminal",
    "landing.bestTerminal.thRenderer",
    "landing.bestTerminal.iterm2Title",
    "landing.bestTerminal.warpTitle",
    "landing.bestTerminal.terminalAppTitle",
    "landing.bestTerminal.tmuxTitle",
    "landing.bestTerminal.rGpuLib",
    "landing.bestTerminal.rCpu",
    "landing.bestTerminal.pMacLinux",
    "landing.bestTerminal.pMacLinuxWin",
    "landing.compare.pages.bestTerminalForAgents.table.rows.3.0",
    "landing.compare.pages.bestTerminalForAgents.table.rows.5.0",
    "landing.compare.pages.bestTerminalForAgents.table.rows.8.0",
    "landing.compare.pages.bestTerminalForAgents.table.rows.9.0",
    "landing.compare.pages.bestTerminalForAgents.table.rows.11.0",
    "landing.compare.pages.bestTerminalForAgents.table.rows.12.0",
    "landing.compare.pages.bestTerminalForAgents.table.rows.13.0",
    "landing.compare.pages.bestTerminalForAgents.table.rows.14.0",
    "landing.compare.pages.bestTerminalForAgents.table.rows.15.0",
    "landing.compare.pages.cmuxVsAlacritty.table.rows.0.0",
    "landing.compare.pages.cmuxVsAlacritty.table.rows.2.0",
    "landing.compare.pages.cmuxVsConductor.table.rows.0.0",
    "landing.compare.pages.multipleClaudeAgents.table.rows.1.0",
    "landing.compare.pages.cmuxVsSuperset.table.rows.0.0",
    "landing.compare.pages.cmuxVsCursor.table.rows.0.0",
    "landing.compare.pages.cmuxVsCursor.table.rows.2.0",
    "landing.compare.pages.cmuxVsDevin.table.rows.0.0",
    "landing.compare.pages.cmuxVsDevin.table.rows.2.0",
    "landing.compare.pages.cmuxVsIterm2.table.rows.0.0",
    "landing.compare.pages.cmuxVsIterm2.table.rows.2.0",
    "landing.compare.pages.cmuxVsKitty.table.rows.0.0",
    "landing.compare.pages.cmuxVsKitty.table.rows.2.0",
    "landing.compare.pages.cmuxVsHerdr.table.rows.0.0",
    "landing.compare.pages.cmuxVsHerdr.table.rows.2.0",
    "landing.compare.pages.cmuxVsOpencode.table.rows.0.0",
    "landing.compare.pages.cmuxVsTmux.table.rows.0.0",
    "landing.compare.pages.cmuxVsTmux.table.rows.2.0",
    "landing.compare.pages.cmuxVsVscode.table.rows.0.0",
    "landing.compare.pages.cmuxVsWindsurf.table.rows.0.0",
    "landing.compare.pages.cmuxVsZed.table.rows.0.0",
    "landing.compare.pages.cmuxVsZed.table.rows.2.0",
    "landing.compare.pages.cmuxVsWarp.table.rows.0.0",
    "landing.compare.pages.cmuxVsWezterm.table.rows.0.0",
    "landing.compare.pages.cmuxVsWezterm.table.rows.2.0",
    "landing.compare.pages.cmuxVsGhostty.table.rows.0.0",
    "platforms.ios",
    "support.form.name",
    "tui.marketing.facts.platforms.value",
    "tui.marketing.features.browser.number",
  ]),
};

const localeIdentityAllowedValues: Record<string, Set<string>> = {
  de: new Set([
    "Actions",
    "Agent",
    "App",
    "Browser",
    "Configuration",
    "Concepts",
    "Details",
    "Dimension",
    "Documentation",
    "Guides",
    "Isolation",
    "Machine",
    "Machines",
    "Name",
    "Navigation",
    "Notifications",
    "Optional",
    "Parameter",
    "Panel",
    "Programmable",
    "Renderer",
    "Scriptable",
    "Source",
    "Status",
    "Surface",
    "Tab",
    "Team",
    "Terminal",
    "Variable",
  ]),
  fr: new Set([
    "Actions",
    "Agent",
    "App",
    "Assistant",
    "Configuration",
    "Concepts",
    "Documentation",
    "Guides",
    "Mode",
    "Machine",
    "Machines",
    "Navigation",
    "Notifications",
    "Parameter",
    "Panel",
    "Pro",
    "Programmable",
    "Scriptable",
    "Source",
    "Status",
    "Suppression",
    "Surface",
    "Surfaces",
    "Action",
    "assistant",
    "Variable",
  ]),
  es: new Set(["Blog", "No"]),
};

function isObject(value: JsonValue): value is { [key: string]: JsonValue } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function flattenCatalog(value: JsonValue, prefix = ""): CatalogLeaf[] {
  if (Array.isArray(value)) {
    return value.flatMap((item, index) =>
      flattenCatalog(item, prefix ? `${prefix}.${index}` : `${index}`),
    );
  }
  if (isObject(value)) {
    return Object.entries(value).flatMap(([key, item]) =>
      flattenCatalog(item, prefix ? `${prefix}.${key}` : key),
    );
  }
  return [{ path: prefix, value }];
}

function matchingBraces(value: string): string[] {
  const matches: string[] = [];
  for (let start = 0; start < value.length; start += 1) {
    if (value[start] !== "{") continue;
    let depth = 0;
    for (let end = start; end < value.length; end += 1) {
      if (value[end] === "{") depth += 1;
      if (value[end] === "}") depth -= 1;
      if (depth === 0) {
        matches.push(value.slice(start, end + 1));
        start = end;
        break;
      }
    }
  }
  return matches;
}

export function syntaxTokens(value: string): {
  placeholders: string[];
  richTextTags: string[];
} {
  return {
    placeholders: matchingBraces(value),
    richTextTags: value.match(/<\/?[a-z][^>]*>/giu) ?? [],
  };
}

function icuStructure(value: string): MessageFormatElement[] | null {
  try {
    return parse(value);
  } catch {
    return null;
  }
}

function hasMatchingIcuStructure(source: string, translation: string): boolean {
  if (!source.includes("{") && !translation.includes("{")) return true;
  const sourceAst = icuStructure(source);
  const translationAst = icuStructure(translation);
  if (sourceAst && translationAst) {
    return isStructurallySame(sourceAst, translationAst).success;
  }
  const sourceSimplePlaceholders = matchingBraces(source).filter((token) =>
    /^[{][\w.-]+[}]$/u.test(token),
  );
  const translationSimplePlaceholders = matchingBraces(translation).filter((token) =>
    /^[{][\w.-]+[}]$/u.test(token),
  );
  return (
    JSON.stringify(sourceSimplePlaceholders) ===
    JSON.stringify(translationSimplePlaceholders)
  );
}

export function isEnglishIdentityAllowed(
  pathname: string,
  value: string,
  locale?: string,
): boolean {
  if (
    identityAllowedPaths.has(pathname) ||
    localeIdentityAllowedPaths[locale ?? ""]?.has(pathname) ||
    localeIdentityAllowedValues[locale ?? ""]?.has(value) ||
    identityAllowedValues.has(value)
  ) {
    return true;
  }
  if (
    locale === "de" &&
    /^landing\.compare\.pages\..+\.table\.headers\.[012]$/u.test(pathname)
  ) {
    return true;
  }
  if (/^(?:https?:\/\/|mailto:|tel:|[\w.+-]+@[\w.-]+\.[a-z]{2,})/iu.test(value)) {
    return true;
  }
  if (/^[\d\s$,+./:#?=&%()\[\]{}<>_@-]+$/u.test(value)) return true;
  if (/^\{[\w.-]+\}(?:\s*·\s*\{[\w.-]+\})?$/u.test(value)) return true;
  if (
    value.includes("\n") &&
    value
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .every((line) =>
        /^(?:[$>#]\s*)?(?:[A-Z_][A-Z\d_]*=|(?:cmux|git|bun|npm|curl|ssh|brew|cargo|zig|python|node|npx|pnpm|docker|cd|mkdir|cat|echo|export|xcrun)\b|[`{}[\]]|https?:\/\/)/u.test(
          line,
        ),
      )
  ) {
    return true;
  }
  return false;
}

export async function readCatalog(locale: string): Promise<JsonValue> {
  return JSON.parse(
    await readFile(path.join(messagesDirectory, `${locale}.json`), "utf8"),
  ) as JsonValue;
}

export async function catalogLeaves(locale: string): Promise<CatalogLeaf[]> {
  return flattenCatalog(await readCatalog(locale));
}

export async function validateCatalog(
  locale: ParityLocale,
  english: JsonValue,
  translation: JsonValue,
): Promise<CatalogIssue[]> {
  const issues: CatalogIssue[] = [];
  const englishLeaves = flattenCatalog(english);
  const translationLeaves = flattenCatalog(translation);
  const englishByPath = new Map(englishLeaves.map((leaf) => [leaf.path, leaf]));
  const translationByPath = new Map(
    translationLeaves.map((leaf) => [leaf.path, leaf]),
  );

  for (const englishLeaf of englishLeaves) {
    const translatedLeaf = translationByPath.get(englishLeaf.path);
    if (!translatedLeaf) {
      issues.push({
        locale,
        path: englishLeaf.path,
        message: "missing key",
        source: typeof englishLeaf.value === "string" ? englishLeaf.value : undefined,
      });
      continue;
    }
    if (
      typeof translatedLeaf.value === "string" &&
      translatedLeaf.value.trim().length === 0
    ) {
      issues.push({ locale, path: englishLeaf.path, message: "empty value" });
    }
    if (typeof englishLeaf.value === "string" && typeof translatedLeaf.value === "string") {
      const sourceTokens = syntaxTokens(englishLeaf.value);
      if (!hasMatchingIcuStructure(englishLeaf.value, translatedLeaf.value)) {
        issues.push({
          locale,
          path: englishLeaf.path,
          message: "placeholder mismatch",
          source: englishLeaf.value,
          value: translatedLeaf.value,
        });
      }
      const translatedTokens = syntaxTokens(translatedLeaf.value);
      if (
        JSON.stringify(sourceTokens.richTextTags) !==
        JSON.stringify(translatedTokens.richTextTags)
      ) {
        issues.push({
          locale,
          path: englishLeaf.path,
          message: "rich-text tag mismatch",
          source: englishLeaf.value,
          value: translatedLeaf.value,
        });
      }
      if (
        locale !== "en" &&
        englishLeaf.value === translatedLeaf.value &&
        !isEnglishIdentityAllowed(englishLeaf.path, englishLeaf.value, locale)
      ) {
        issues.push({
          locale,
          path: englishLeaf.path,
          message: "English-identical value",
          source: englishLeaf.value,
          value: translatedLeaf.value,
        });
      }
    }
  }

  for (const translatedLeaf of translationLeaves) {
    if (!englishByPath.has(translatedLeaf.path)) {
      issues.push({
        locale,
        path: translatedLeaf.path,
        message: "stale key",
        value: translatedLeaf.value,
      });
    }
  }
  return issues;
}

function setLeaf(
  source: JsonValue,
  translations: Map<string, JsonValue>,
  prefix = "",
): JsonValue {
  if (Array.isArray(source)) {
    return source.map((value, index) =>
      setLeaf(value, translations, prefix ? `${prefix}.${index}` : `${index}`),
    );
  }
  if (isObject(source)) {
    return Object.fromEntries(
      Object.entries(source).map(([key, value]) => [
        key,
        setLeaf(value, translations, prefix ? `${prefix}.${key}` : key),
      ]),
    );
  }
  return translations.get(prefix) ?? source;
}

export function mergeTranslations(
  english: JsonValue,
  existing: JsonValue,
  translations: Map<string, string>,
): JsonValue {
  const existingByPath = new Map(flattenCatalog(existing).map((leaf) => [leaf.path, leaf.value]));
  const values = new Map<string, JsonValue>();
  for (const leaf of flattenCatalog(english)) {
    const translated = translations.get(leaf.path);
    if (translated !== undefined) values.set(leaf.path, translated);
    else if (typeof existingByPath.get(leaf.path) === "string") {
      values.set(leaf.path, existingByPath.get(leaf.path) as string);
    }
  }
  return setLeaf(english, values);
}

function entriesNeedingTranslation(
  english: JsonValue,
  translation: JsonValue,
  locale: ParityLocale,
): TranslationEntry[] {
  const translatedByPath = new Map(flattenCatalog(translation).map((leaf) => [leaf.path, leaf.value]));
  return flattenCatalog(english).flatMap((leaf) => {
    if (typeof leaf.value !== "string") return [];
    const current = translatedByPath.get(leaf.path);
    if (
      locale === "en" ||
      (typeof current === "string" &&
        current !== leaf.value &&
        current.trim().length > 0)
    ) {
      return [];
    }
    if (isEnglishIdentityAllowed(leaf.path, leaf.value, locale)) return [];
    const tokens = syntaxTokens(leaf.value);
    return [
      {
        path: leaf.path,
        source: leaf.value,
        placeholders: tokens.placeholders,
        richTextTags: tokens.richTextTags,
      },
    ];
  });
}

async function exportEntries(locale: ParityLocale, batchSize: number, output: string) {
  const english = await readCatalog("en");
  const translation = await readCatalog(locale);
  const entries = entriesNeedingTranslation(english, translation, locale);
  const batches = [];
  for (let index = 0; index < entries.length; index += batchSize) {
    batches.push(entries.slice(index, index + batchSize));
  }
  for (const [index, batch] of batches.entries()) {
    const destination = path.resolve(
      output,
      `${locale}.batch-${String(index + 1).padStart(3, "0")}.json`,
    );
    await writeFile(
      destination,
      `${JSON.stringify({ locale, batch: index + 1, entries: batch }, null, 2)}\n`,
    );
  }
  console.log(JSON.stringify({ locale, entries: entries.length, batches: batches.length }));
}

async function readTranslationInputs(inputs: string[]): Promise<Map<string, string>> {
  const translations = new Map<string, string>();
  for (const input of inputs) {
    const content = JSON.parse(await readFile(path.resolve(input), "utf8")) as
      | Record<string, string>
      | { entries: TranslationEntry[] };
    const entries = "entries" in content ? content.entries : undefined;
    if (entries) {
      for (const entry of entries) {
        if (entry.translation !== undefined) translations.set(entry.path, entry.translation);
      }
    } else {
      for (const [key, value] of Object.entries(content)) translations.set(key, value);
    }
  }
  return translations;
}

async function main() {
  const [command = "audit", ...args] = process.argv.slice(2);
  const english = await readCatalog("en");
  if (command === "audit") {
    for (const locale of parityLocales.slice(1)) {
      const translation = await readCatalog(locale);
      const issues = await validateCatalog(locale, english, translation);
      const missing = issues.filter((issue) => issue.message === "missing key").length;
      const stale = issues.filter((issue) => issue.message === "stale key").length;
      const identical = issues.filter((issue) => issue.message === "English-identical value").length;
      console.log(JSON.stringify({ locale, missing, stale, identical, issues: issues.length }));
    }
    return;
  }
  if (command === "validate") {
    const locales = args.length > 0 ? args : [...parityLocales.slice(1)];
    const issues = [];
    for (const locale of locales as ParityLocale[]) {
      issues.push(...(await validateCatalog(locale, english, await readCatalog(locale))));
    }
    if (issues.length > 0) {
      console.error(JSON.stringify(issues, null, 2));
      process.exitCode = 1;
      return;
    }
    console.log(`Validated ${locales.length} locale catalogs against en.json.`);
    return;
  }
  if (command === "export") {
    const locale = args[0] as ParityLocale | undefined;
    if (!locale || locale === "en") throw new Error("export requires a non-English locale");
    const batchSize = Number(args[1] ?? 100);
    const output = path.resolve(args[2] ?? "localization-batches");
    await exportEntries(locale, batchSize, output);
    return;
  }
  if (command === "merge") {
    const locale = args[0] as ParityLocale | undefined;
    const output = args[1];
    const inputs = args.slice(2);
    if (!locale || !output || inputs.length === 0) {
      throw new Error("merge requires <locale> <output> <translation-json>...");
    }
    const merged = mergeTranslations(
      english,
      await readCatalog(locale),
      await readTranslationInputs(inputs),
    );
    await writeFile(path.resolve(output), `${JSON.stringify(merged, null, 2)}\n`);
    return;
  }
  if (command === "list-batches") {
    const entries = await readdir(path.resolve(args[0] ?? "localization-batches"));
    console.log(entries.filter((entry) => entry.endsWith(".json")).join("\n"));
    return;
  }
  throw new Error(`Unknown command: ${command}`);
}

if (import.meta.main) await main();
