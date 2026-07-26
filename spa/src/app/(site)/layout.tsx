import type { Metadata } from 'next'

// The QuidMint marketing landing lives at /. Light theme, Inter + PX Grotesk
// (set on <body> in globals.css). Its "Sign up / Get started" CTAs route to
// the QU!D dashboard at /app instead of redirecting off-site.
export const metadata: Metadata = {
  title: 'QuidMint | Banking that stacks bitcoin, not fees',
  description: 'Earn yield today and accumulate bitcoin for tomorrow — the modern way businesses compound their treasury.',
}

export default function SiteLayout({ children }: { children: React.ReactNode }) {
  return <div className="castle-root min-h-screen bg-white text-[#09090b]">{children}</div>
}
