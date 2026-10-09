import type { Metadata } from "next";
import "./globals.css";
import { Providers } from "./providers";
import { Nav } from "@/components/Nav";

export const metadata: Metadata = {
  title: "Holdcredit - portfolio-margin credit lines",
  description: "Pledge a portfolio of stock tokens and draw a revolving stablecoin credit line without selling.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Nav />
          <main className="container">{children}</main>
          <footer className="container">
            Holdcredit is experimental, unaudited software. Credit lines can be liquidated. Not investment advice.
            Stock tokens are third-party products and are not available in all jurisdictions.{" "}
            <a href="/risk">Read the risk disclosure</a>.
          </footer>
        </Providers>
      </body>
    </html>
  );
}
