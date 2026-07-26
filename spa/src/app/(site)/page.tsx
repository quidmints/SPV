import SiteHeader from '@/components/castle/SiteHeader'
import Hero from '@/components/castle/Hero'
import LogosStrip from '@/components/castle/LogosStrip'
import FeatureA from '@/components/castle/FeatureA'
import FeatureC from '@/components/castle/FeatureC'
import FeatureD from '@/components/castle/FeatureD'
import OpenAccountCta from '@/components/castle/OpenAccountCta'
import SiteFooter from '@/components/castle/SiteFooter'

// QuidMint marketing landing (clone of savewithcastle.com). Page-level wrappers
// mirror the original DOM: a fixed header, a padded hero card, the FinTech
// disclaimer line, feature sections, the open-account CTA card, and footer.
// Every "Sign up / Log in / Get started" CTA inside these components routes to
// /app (the QU!D dashboard) instead of redirecting off-site.
export default function QuidMintLanding() {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />
      <main className="flex-1">
        <div className="px-2 sm:px-3 pt-2 sm:pt-3 pb-4 sm:pb-6 bg-white">
          <Hero />
        </div>
        <p className="mx-auto px-4 text-center text-xs text-[#525866]">
          QuidMint is a financial technology company, not a bank. Banking services are provided through Quid Labs partner banks.
        </p>
        <LogosStrip />
        <FeatureA />
        <FeatureC />
        <FeatureD />
        <div className="px-2 pt-16 sm:px-3 md:pt-24 pb-4 sm:pb-6 bg-white">
          <OpenAccountCta />
        </div>
      </main>
      <SiteFooter />
    </div>
  )
}
