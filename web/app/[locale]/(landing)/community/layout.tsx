import { NextIntlClientProvider } from "next-intl";
import { getMessages } from "next-intl/server";
import { pruneClientMessages } from "@/i18n/client-messages";

// The project browser reads the `community` namespace on the client, which
// the shared catalog omits. A nested provider replaces the catalog here.
export default async function CommunityLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const messages = pruneClientMessages(await getMessages());
  return (
    <NextIntlClientProvider messages={messages}>{children}</NextIntlClientProvider>
  );
}
