import Link from 'next/link'
import SiteHeader from './SiteHeader'
import SiteFooter from './SiteFooter'

// Reusable content/legal/docs page shell in the QuidMint (site) theme. Mirrors the
// landing's structure (fixed header + footer) and exposes a `.castle-prose`
// container so plain copy (headings, paragraphs, lists) renders cleanly. Drop
// real copy in as children — no rebuild needed.
export default function ContentPage({
  eyebrow,
  title,
  subtitle,
  lastUpdated,
  children,
}: {
  eyebrow?: string
  title: string
  subtitle?: string
  lastUpdated?: string
  children?: React.ReactNode
}) {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />
      <main className="flex-1">
        <div className="px-4 sm:px-8 pt-[140px] md:pt-[160px] pb-20 md:pb-28">
          <article className="mx-auto max-w-[760px]">
            {eyebrow && (
              <div className="mb-3 text-[12px] font-semibold uppercase tracking-wider text-castle-blue">
                {eyebrow}
              </div>
            )}
            <h1 className="font-px-grotesk text-[40px] md:text-[56px] font-normal tracking-[-0.04em] leading-[1.02] text-[#09090b]">
              {title}
            </h1>
            {subtitle && <p className="mt-4 text-[18px] leading-relaxed text-[#525866]">{subtitle}</p>}
            {lastUpdated && <p className="mt-2 text-[13px] text-[#8a8f98]">Last updated: {lastUpdated}</p>}
            <div className="castle-prose mt-10">
              {children ?? (
                <p className="text-[#8a8f98]">
                  We&apos;re putting the finishing touches on this page. Copy coming soon.
                </p>
              )}
            </div>
            <div className="mt-14 border-t border-[#e6e7eb] pt-6">
              <Link href="/" className="text-[14px] font-semibold text-castle-blue hover:underline">
                ← Back to home
              </Link>
            </div>
          </article>
        </div>
      </main>
      <SiteFooter />
    </div>
  )
}
