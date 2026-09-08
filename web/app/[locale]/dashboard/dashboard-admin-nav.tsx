"use client";

import { useTranslations } from "next-intl";
import { usePathname } from "@/i18n/navigation";
import { DashboardNavGroupView, useDashboardNav } from "./dashboard-shell";

/**
 * The admin group is rendered by a server slot only for admin users, so the
 * static shell never carries the link and no client user read is needed.
 */
export function DashboardAdminNavGroup() {
  const t = useTranslations("dashboard.nav");
  const pathname = usePathname();
  const { onNavigate } = useDashboardNav();
  return (
    <DashboardNavGroupView
      group={{
        label: t("adminGroup"),
        items: [
          {
            href: "/dashboard/admin",
            label: t("adminPro"),
            active: pathname.startsWith("/dashboard/admin"),
          },
        ],
      }}
      onNavigate={onNavigate}
    />
  );
}
