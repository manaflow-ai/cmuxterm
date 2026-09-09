import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import proxy from "../proxy";

describe("locale preference during router revalidation", () => {
  for (const locale of ["ko", "ja"]) {
    test(`background ${locale} requests cannot overwrite explicit English`, () => {
      // Next strips its RSC/prefetch headers before invoking the proxy.
      // Sec-Fetch-Dest survives and identifies a fetch, not a document visit.
      const response = proxy(new NextRequest(`https://cmux.com/${locale}/blog`, {
        headers: {
          cookie: "NEXT_LOCALE=en",
          "accept-language": "ko-KR,ko;q=0.9,en;q=0.8",
          "sec-fetch-dest": "empty",
        },
      }));

      expect(response.status).toBe(200);
      expect(response.cookies.get("NEXT_LOCALE")).toBeUndefined();
    });

    test(`a real ${locale} document visit still updates the preference`, () => {
      const response = proxy(new NextRequest(`https://cmux.com/${locale}/blog`, {
        headers: {
          cookie: "NEXT_LOCALE=en",
          "sec-fetch-dest": "document",
        },
      }));

      expect(response.status).toBe(200);
      expect(response.cookies.get("NEXT_LOCALE")?.value).toBe(locale);
    });
  }

  test("clients without Fetch Metadata keep document locale detection", () => {
    const response = proxy(new NextRequest("https://cmux.com/ja/blog", {
      headers: { cookie: "NEXT_LOCALE=en" },
    }));

    expect(response.cookies.get("NEXT_LOCALE")?.value).toBe("ja");
  });
});
