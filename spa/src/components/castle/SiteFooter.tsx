import Link from 'next/link';
import BuildStamp from '../BuildStamp';

export default function SiteFooter() {
  return (
    <footer className="bg-[#0E0F15]" data-track-location="footer">
      <div className="container mx-auto px-4 py-16 md:py-20">
        <div className="grid gap-8 md:grid-cols-2 lg:flex lg:flex-nowrap lg:items-start lg:justify-between lg:gap-6">
          <div className="lg:w-[250px] lg:shrink-0">
            <a data-track-button="true" data-track-label="footer_logo" className="inline-block mb-6 active" href="/" data-status="active" aria-current="page">
              <img alt="QuidMint" className="h-[28px] w-auto" src="/castle/images/brand/castle-logo.svg" />
            </a>
            <p className="text-[16px] text-[#8a8f98] leading-[1.5]">Financial tools for forward-thinking businesses.</p>
          </div>
          <div className="lg:w-[250px] lg:shrink-0">
            <h3 className="mb-6 text-[12px] font-semibold uppercase tracking-wider text-white">Integrations</h3>
            <ul className="space-y-4">
              <li>
                <a href="/sales/automatically-convert-paypal-payments-to-bitcoin" className="text-[14px] text-[#8a8f98] transition-colors hover:text-white">Convert Paypal Payments to bitcoin</a>
              </li>
              <li>
                <a href="/sales/automatically-convert-shopify-sales-to-bitcoin" className="text-[14px] text-[#8a8f98] transition-colors hover:text-white">Convert Shopify Sales to bitcoin</a>
              </li>
              <li>
                <a href="/sales/automatically-convert-stripe-payments-to-bitcoin" className="text-[14px] text-[#8a8f98] transition-colors hover:text-white">Convert Stripe Payments to bitcoin</a>
              </li>
              <li>
                <a href="/sales/automatically-convert-square-sales-to-bitcoin" className="text-[14px] text-[#8a8f98] transition-colors hover:text-white">Convert Square Sales to bitcoin</a>
              </li>
            </ul>
          </div>
          <div className="lg:w-[140px] lg:shrink-0">
            <h3 className="mb-6 text-[12px] font-semibold uppercase tracking-wider text-white">Resources</h3>
            <ul className="space-y-4">
              <li>
                <a href="/faqs" className="text-[14px] text-[#8a8f98] transition-colors hover:text-white">FAQs</a>
              </li>
              <li>
                <a href="/learn" className="text-[14px] text-[#8a8f98] transition-colors hover:text-white">Learn</a>
              </li>
              <li>
                <Link href="/app" className="text-[14px] text-[#8a8f98] transition-colors hover:text-white">Demo</Link>
              </li>
              <li>
                <a href="/security" className="text-[14px] text-[#8a8f98] transition-colors hover:text-white">Security</a>
              </li>
            </ul>
          </div>
          <div className="w-full min-w-0 lg:w-[320px] lg:shrink-0">
            <h3 className="mb-6 text-[16px] font-semibold text-white">Stay Updated</h3>
            <form className="flex min-w-0 gap-2">
              <input placeholder="name@email.com" required className="min-w-0 flex-1 rounded-[8px] bg-white border border-white/30 px-4 py-3 text-[14px] text-[#09090b] placeholder:text-[#7a8190] focus:outline-none focus:ring-1 focus:ring-white/40" type="email" defaultValue="" />
              <button type="submit" data-track-label="footer_subscribe" className="shrink-0 rounded-[8px] bg-[#488BFB] text-white hover:bg-[#3f7ae0] text-[14px] font-semibold px-5 py-3 transition-colors">Subscribe</button>
            </form>
            <div className="mt-5 flex items-center gap-3">
              <a href="https://x.com/savewithcastle" target="_blank" rel="noopener noreferrer" aria-label="QuidMint on X" className="rounded-md p-1.5 text-white/70 transition-colors hover:text-white">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="tabler-icon tabler-icon-brand-x h-5 w-5">
                  <path d="M4 4l11.733 16h4.267l-11.733 -16l-4.267 0" />
                  <path d="M4 20l6.768 -6.768m2.46 -2.46l6.772 -6.772" />
                </svg>
              </a>
              <a href="https://www.linkedin.com/company/savewithcastle" target="_blank" rel="noopener noreferrer" aria-label="QuidMint on LinkedIn" className="rounded-md p-1.5 text-white/70 transition-colors hover:text-white">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="tabler-icon tabler-icon-brand-linkedin h-5 w-5">
                  <path d="M8 11v5" />
                  <path d="M8 8v.01" />
                  <path d="M12 16v-5" />
                  <path d="M16 16v-3a2 2 0 1 0 -4 0" />
                  <path d="M3 7a4 4 0 0 1 4 -4h10a4 4 0 0 1 4 4v10a4 4 0 0 1 -4 4h-10a4 4 0 0 1 -4 -4l0 -10" />
                </svg>
              </a>
              <a href="https://www.facebook.com/savewithcastle" target="_blank" rel="noopener noreferrer" aria-label="QuidMint on Facebook" className="rounded-md p-1.5 text-white/70 transition-colors hover:text-white">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="tabler-icon tabler-icon-brand-facebook h-5 w-5">
                  <path d="M7 10v4h3v7h4v-7h3l1 -4h-4v-2a1 1 0 0 1 1 -1h3v-4h-3a5 5 0 0 0 -5 5v2h-3" />
                </svg>
              </a>
              <a href="https://www.instagram.com/savewithcastle" target="_blank" rel="noopener noreferrer" aria-label="QuidMint on Instagram" className="rounded-md p-1.5 text-white/70 transition-colors hover:text-white">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="tabler-icon tabler-icon-brand-instagram h-5 w-5">
                  <path d="M4 8a4 4 0 0 1 4 -4h8a4 4 0 0 1 4 4v8a4 4 0 0 1 -4 4h-8a4 4 0 0 1 -4 -4l0 -8" />
                  <path d="M9 12a3 3 0 1 0 6 0a3 3 0 0 0 -6 0" />
                  <path d="M16.5 7.5v.01" />
                </svg>
              </a>
              <a href="https://www.tiktok.com/@savewithcastle" target="_blank" rel="noopener noreferrer" aria-label="QuidMint on TikTok" className="rounded-md p-1.5 text-white/70 transition-colors hover:text-white">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="tabler-icon tabler-icon-brand-tiktok h-5 w-5">
                  <path d="M21 7.917v4.034a9.948 9.948 0 0 1 -5 -1.951v4.5a6.5 6.5 0 1 1 -8 -6.326v4.326a2.5 2.5 0 1 0 4 2v-11.5h4.083a6.005 6.005 0 0 0 4.917 4.917" />
                </svg>
              </a>
              <a href="https://www.youtube.com/@SaveWithQuidMint" target="_blank" rel="noopener noreferrer" aria-label="QuidMint on YouTube" className="rounded-md p-1.5 text-white/70 transition-colors hover:text-white">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="tabler-icon tabler-icon-brand-youtube h-5 w-5">
                  <path d="M2 8a4 4 0 0 1 4 -4h12a4 4 0 0 1 4 4v8a4 4 0 0 1 -4 4h-12a4 4 0 0 1 -4 -4v-8" />
                  <path d="M10 9l5 3l-5 3l0 -6" />
                </svg>
              </a>
            </div>
          </div>
        </div>
      </div>
      <div className="border-t border-white/10 bg-[#15161C]">
        <div className="container mx-auto px-4 py-6">
          <div className="flex flex-wrap items-center gap-6">
            <a href="/terms-and-conditions" className="text-[14px] text-white/90 transition-colors hover:text-white">Terms &amp; Conditions</a>
            <a href="/privacy-policy" className="text-[14px] text-white/90 transition-colors hover:text-white">Privacy Policy</a>
            <BuildStamp className="ml-auto" />
          </div>
        </div>
      </div>
    </footer>
  );
}
