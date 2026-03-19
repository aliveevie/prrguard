import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "PrrrGuard Dashboard",
  description:
    "Permissionless DeFi attack detection powered by the Prrr mechanism",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          fontFamily:
            '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace',
          background: "#0a0a0f",
          color: "#e0e0e0",
          minHeight: "100vh",
        }}
      >
        {children}
      </body>
    </html>
  );
}
