import type { Metadata } from 'next'

// The QU!D landing page lives at `/`. It is the whole of the web product: everything a depositor
// does happens in the mobile app, and `/app` is the transitional browser build of that.
export const metadata: Metadata = {
  title: 'QU!D | Money that matures on a date you choose',
  description:
    'A dollar claim bought at a discount and redeemed at face value in a month you pick. Backed by a diversified reserve that earns while you wait.',
}

export default function SiteLayout({ children }: { children: React.ReactNode }) {
  return <div className="min-h-screen bg-white text-[#09090b]">{children}</div>
}
