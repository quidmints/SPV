import Link from 'next/link'
import { SplitText } from '@/components/castle/anim'

export default function FeatureA() {
  return (
    <section className="py-16 md:py-24 bg-white">
      <div className="container mx-auto px-4">
        <div className="mb-12">
          <SplitText as="h2" text="Three accounts. One compounding treasury." highlight="compounding treasury." className="mt-6 text-[32px] md:text-[44px] lg:text-[58px] font-light tracking-[-0.05em] leading-[1.03] text-[#09090b] font-px-grotesk max-w-[18ch] md:max-w-none" />
          <div>
            <p className="mt-3 text-[20px] text-[#4F4D55] leading-[30px]">Pair liquid operating cash with a high yield reserve and a long-term bitcoin position — all in one platform.</p>
          </div>
        </div>
        <div className="grid gap-8 md:gap-4 lg:gap-5 md:grid-cols-3">
          <div className="relative">
            <div aria-hidden="true" className="pointer-events-none absolute inset-x-10 -bottom-1 h-14 rounded-[100%] opacity-30 blur-2xl" style={{ backgroundColor: 'rgb(5, 150, 105)' }}>
            </div>
            <div role="link" tabIndex={0} className="group relative z-10 flex h-full cursor-pointer flex-col overflow-hidden rounded-2xl border border-border/70 bg-white p-6 shadow-sm transition-shadow hover:shadow-md focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-[#09090b]/40 md:p-7">
              <div className="absolute inset-x-0 top-0 h-1" style={{ backgroundColor: 'rgba(5, 150, 105, 0.4)' }}>
              </div>
              <div className="mb-5 flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="flex items-center justify-center rounded-full p-2.5 bg-[#DCF4EA]">
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-dollar-sign size-5 text-[#059669]" aria-hidden="true">
                      <line x1="12" x2="12" y1="2" y2="22"></line>
                      <path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"></path>
                    </svg>
                  </div>
                  <h3 className="text-2xl font-bold tracking-tighter">Cash</h3>
                </div>
                <div className="text-right">
                  <span className="text-2xl font-bold tracking-tighter" style={{ color: 'rgb(5, 150, 105)' }}>3.5%</span>
                </div>
              </div>
              <p className="mb-5 text-sm font-normal text-[#27272a]">Stop letting your business cash sit idle, earn a premium on every dollar.</p>
              <div className="mb-6 flex flex-1 flex-col gap-2">
                <div className="flex items-start gap-3 rounded-xl border border-border/60 bg-white p-3">
                  <div className="mt-0.5 flex size-5 flex-shrink-0 items-center justify-center rounded-md bg-[#DCF4EA]">
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check size-2.5 text-[#059669]" aria-hidden="true">
                      <path d="M20 6 9 17l-5-5"></path>
                    </svg>
                  </div>
                  <span className="text-xs leading-relaxed text-[#27272a]">Reserves backed by short-term U.S. Treasuries — never fractional.</span>
                </div>
                <div className="flex items-start gap-3 rounded-xl border border-border/60 bg-white p-3">
                  <div className="mt-0.5 flex size-5 flex-shrink-0 items-center justify-center rounded-md bg-[#DCF4EA]">
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check size-2.5 text-[#059669]" aria-hidden="true">
                      <path d="M20 6 9 17l-5-5"></path>
                    </svg>
                  </div>
                  <span className="text-xs leading-relaxed text-[#27272a]">Zero monthly fees, zero minimums, and same-day liquidity in and out.</span>
                </div>
              </div>
              <Link href="/app?tab=mint" className="mt-auto inline-flex items-center gap-1.5 text-[14px] font-semibold text-[#09090b] transition-[gap] duration-200 group-hover:gap-2">Explore Cash<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-arrow-right h-4 w-4" aria-hidden="true">
                <path d="M5 12h14"></path>
                <path d="m12 5 7 7-7 7"></path>
              </svg>
              </Link>
            </div>
          </div>
          <div className="relative">
            <div aria-hidden="true" className="pointer-events-none absolute inset-x-10 -bottom-1 h-14 rounded-[100%] opacity-30 blur-2xl" style={{ backgroundColor: 'rgb(37, 99, 235)' }}>
            </div>
            <div role="link" tabIndex={0} className="group relative z-10 flex h-full cursor-pointer flex-col overflow-hidden rounded-2xl border border-border/70 bg-white p-6 shadow-sm transition-shadow hover:shadow-md focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-[#09090b]/40 md:p-7">
              <div className="absolute inset-x-0 top-0 h-1" style={{ backgroundColor: 'rgba(37, 99, 235, 0.4)' }}>
              </div>
              <div className="mb-5 flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="flex items-center justify-center rounded-full p-2.5 bg-[#E7F0FF]">
                    <span className="flex size-5 items-center justify-center text-[20px] font-semibold leading-none text-[#2563EB]">Ξ</span>
                  </div>
                  <h3 className="text-2xl font-bold tracking-tighter">Ethereum</h3>
                </div>
                <div className="text-right">
                  <span className="text-2xl font-bold tracking-tighter" style={{ color: 'rgb(37, 99, 235)' }}>11.5%</span>
                </div>
              </div>
              <p className="mb-5 text-sm font-normal text-[#27272a]">Maximize your treasury reserves with an institutional-grade yield strategy.</p>
              <div className="mb-6 flex flex-1 flex-col gap-2">
                <div className="flex items-start gap-3 rounded-xl border border-border/60 bg-white p-3">
                  <div className="mt-0.5 flex size-5 flex-shrink-0 items-center justify-center rounded-md bg-[#E7F0FF]">
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check size-2.5 text-[#2563EB]" aria-hidden="true">
                      <path d="M20 6 9 17l-5-5"></path>
                    </svg>
                  </div>
                  <span className="text-xs leading-relaxed text-[#27272a]">Earn up to 11.5% — roughly 2x the average HYSA, paid monthly in bitcoin.</span>
                </div>
                <div className="flex items-start gap-3 rounded-xl border border-border/60 bg-white p-3">
                  <div className="mt-0.5 flex size-5 flex-shrink-0 items-center justify-center rounded-md bg-[#E7F0FF]">
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check size-2.5 text-[#2563EB]" aria-hidden="true">
                      <path d="M20 6 9 17l-5-5"></path>
                    </svg>
                  </div>
                  <span className="text-xs leading-relaxed text-[#27272a]">Tax-deferred treatment via STRC from Strategy. No hold period, no lock-ups.</span>
                </div>
              </div>
              <Link href="/app?tab=deposit" className="mt-auto inline-flex items-center gap-1.5 text-[14px] font-semibold text-[#09090b] transition-[gap] duration-200 group-hover:gap-2">Explore Ethereum<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-arrow-right h-4 w-4" aria-hidden="true">
                <path d="M5 12h14"></path>
                <path d="m12 5 7 7-7 7"></path>
              </svg>
              </Link>
            </div>
          </div>
          <div className="relative">
            <div aria-hidden="true" className="pointer-events-none absolute inset-x-10 -bottom-1 h-14 rounded-[100%] opacity-30 blur-2xl" style={{ backgroundColor: 'rgb(247, 147, 26)' }}>
            </div>
            <div role="link" tabIndex={0} className="group relative z-10 flex h-full cursor-pointer flex-col overflow-hidden rounded-2xl border border-border/70 bg-white p-6 shadow-sm transition-shadow hover:shadow-md focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-[#09090b]/40 md:p-7">
              <div className="absolute inset-x-0 top-0 h-1" style={{ backgroundColor: 'rgba(247, 147, 26, 0.4)' }}>
              </div>
              <div className="mb-5 flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="flex items-center justify-center rounded-full p-2.5 bg-[#FFF6E6]">
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-bitcoin size-5 text-orange-600" aria-hidden="true">
                      <path d="M11.767 19.089c4.924.868 6.14-6.025 1.216-6.894m-1.216 6.894L5.86 18.047m5.908 1.042-.347 1.97m1.563-8.864c4.924.869 6.14-6.025 1.215-6.893m-1.215 6.893-3.94-.694m5.155-6.2L8.29 4.26m5.908 1.042.348-1.97M7.48 20.364l3.126-17.727"></path>
                    </svg>
                  </div>
                  <h3 className="text-2xl font-bold tracking-tighter">Bitcoin</h3>
                </div>
              </div>
              <p className="mb-5 text-sm font-normal text-[#27272a]">Join thousands of businesses using bitcoin as a long-term treasury reserve.</p>
              <div className="mb-6 flex flex-1 flex-col gap-2">
                <div className="flex items-start gap-3 rounded-xl border border-border/60 bg-white p-3">
                  <div className="mt-0.5 flex size-5 flex-shrink-0 items-center justify-center rounded-md bg-[#FFF6E6]">
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check size-2.5 text-orange-600" aria-hidden="true">
                      <path d="M20 6 9 17l-5-5"></path>
                    </svg>
                  </div>
                  <span className="text-xs leading-relaxed text-[#27272a]">Protect your purchasing power from inflation with the best performing asset.</span>
                </div>
                <div className="flex items-start gap-3 rounded-xl border border-border/60 bg-white p-3">
                  <div className="mt-0.5 flex size-5 flex-shrink-0 items-center justify-center rounded-md bg-[#FFF6E6]">
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check size-2.5 text-orange-600" aria-hidden="true">
                      <path d="M20 6 9 17l-5-5"></path>
                    </svg>
                  </div>
                  <span className="text-xs leading-relaxed text-[#27272a]">Automated DCA, revenue splits, and instant buys — set it once and let it run.</span>
                </div>
              </div>
              <Link href="/app?tab=channel" className="mt-auto inline-flex items-center gap-1.5 text-[14px] font-semibold text-[#09090b] transition-[gap] duration-200 group-hover:gap-2">Explore Bitcoin<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-arrow-right h-4 w-4" aria-hidden="true">
                <path d="M5 12h14"></path>
                <path d="m12 5 7 7-7 7"></path>
              </svg>
              </Link>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
