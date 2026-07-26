import type { Metadata } from 'next'
import BuildStamp from '@/components/BuildStamp'

// The QU!D dashboard lives under /app. This layout restores the dark,
// monospace shell the dashboard was originally designed against (it used to
// come from the root <body>; the root is now theme-neutral so the QuidMint
// landing can be light). `app-shell` scopes JetBrains Mono to this subtree.
export const metadata: Metadata = {
  title: 'QU!D Protocol',
  description: 'Stablecoin Infrastructure Protocol',
}

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="app-shell min-h-screen bg-[#0a0b0d] text-white">
      {children}
      <div className="pointer-events-none fixed bottom-2 right-3 z-50 opacity-70">
        <BuildStamp />
      </div>
    </div>
  )
}
