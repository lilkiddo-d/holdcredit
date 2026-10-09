"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { tokenFeaturesEnabled } from "@/config/deployments";

const links = [
  { href: "/", label: "Borrow" },
  { href: "/trade", label: "Trade in account" },
  { href: "/lend", label: "Lend" },
  ...(tokenFeaturesEnabled ? [{ href: "/stake", label: "Stake $HOLD" }] : []),
  { href: "/risk", label: "Risks" },
];

export function Nav() {
  const path = usePathname();
  return (
    <nav className="nav">
      <Link href="/" className="brand">
        Hold<span>credit</span>
      </Link>
      <div className="nav-links">
        {links.map((l) => (
          <Link key={l.href} href={l.href} className={path === l.href ? "active" : ""}>
            {l.label}
          </Link>
        ))}
      </div>
      <ConnectButton chainStatus="icon" showBalance={false} />
    </nav>
  );
}
