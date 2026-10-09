import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional geoblock. GEOBLOCK_COUNTRIES="US,CA,GB,CH" blocks those ISO countries using the edge geo header
 * (Vercel: x-vercel-ip-country; Cloudflare: cf-ipcountry). Empty/unset = off. The risk page stays reachable.
 */
export function middleware(req: NextRequest) {
  const list = (process.env.GEOBLOCK_COUNTRIES || "")
    .split(",")
    .map((s) => s.trim().toUpperCase())
    .filter(Boolean);
  if (list.length === 0) return NextResponse.next();
  const country = (req.headers.get("x-vercel-ip-country") || req.headers.get("cf-ipcountry") || "").toUpperCase();
  if (country && list.includes(country)) {
    const url = req.nextUrl.clone();
    url.pathname = "/blocked";
    return NextResponse.rewrite(url);
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next|favicon.ico|risk|blocked).*)"],
};
