import Link from 'next/link'
import SiteHeader from './SiteHeader'
import SiteFooter from './SiteFooter'

export type SalesProps = { merchant: string; icon: string; verb: string; verbCap: string }

export default function SalesLanding({ merchant, icon, verb, verbCap }: SalesProps) {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />
      <main className="flex-1">
        <div>
          <div className="px-2 sm:px-3 pt-2 sm:pt-3">
            <section
              className="relative overflow-hidden rounded-[20px] border pt-[160px] pb-[160px]"
              style={{ borderColor: 'rgba(9, 9, 11, 0.12)', boxShadow: 'rgba(2, 8, 20, 0.07) 0px 5px 14px, rgba(2, 8, 20, 0.05) 0px 1px 3px' }}
            >
              <div
                className="absolute inset-0 pointer-events-none"
                style={{ background: 'linear-gradient(rgb(251, 253, 248) 0%, rgba(149, 191, 71, 0.24) 50%, rgba(149, 191, 71, 0.1) 60%, rgb(255, 255, 255) 78%)' }}
              />
              <div
                className="absolute left-[10%] top-[40%] h-32 w-32 rounded-full blur-3xl"
                style={{ backgroundColor: 'rgba(149, 191, 71, 0.24)' }}
              />
              <div className="absolute right-[15%] top-[50%] h-24 w-24 rounded-full bg-gray-300/20 blur-2xl" />
              <div className="container relative mx-auto px-4 sm:px-8">
                <div className="mx-auto max-w-4xl text-center">
                  <h1 className="mb-6 text-[40px] md:text-[56px] lg:text-[64px] font-normal tracking-[-0.05em] leading-[1] text-[#09090b] font-px-grotesk max-w-[16ch] md:max-w-[20ch] mx-auto">
                    Automatically convert {merchant} {verb} to bitcoin
                  </h1>
                  <p className="whitespace-pre-wrap mb-8 text-[18px] md:text-[20px] text-[#525866] leading-[1.4] max-w-[28ch] md:max-w-[40ch] mx-auto font-normal">
                    Long-term treasury diversification. For forward-thinking business owners.
                  </p>
                  <div>
                    <div className="mb-12 flex flex-row items-center justify-center gap-3">
                      <Link
                        href="/app"
                        className="inline-flex items-center justify-center rounded-[10px] border border-white/15 bg-[#17181d] px-[14px] py-[10px] text-[14px] font-semibold text-white [text-shadow:0_1px_0_rgba(255,255,255,0.18),0_2px_4px_rgba(0,0,0,0.45)] shadow-[0_2px_0_rgba(10,10,12,0.95),0_8px_20px_rgba(9,9,11,0.28),inset_0_1px_0_rgba(255,255,255,0.14)] transition-[box-shadow,color] duration-200 hover:text-white/80 hover:shadow-[0_2px_0_rgba(10,10,12,0.95),0_12px_24px_rgba(9,9,11,0.34),inset_0_1px_0_rgba(255,255,255,0.2)] active:text-white active:shadow-[0_2px_0_rgba(10,10,12,0.95),0_8px_16px_rgba(9,9,11,0.26),inset_0_1px_0_rgba(255,255,255,0.12)]"
                      >
                        Get Started
                      </Link>
                    </div>
                  </div>
                  <div>
                    <div className="relative flex flex-col items-center">
                      <div className="relative z-10 mb-4">
                        <div
                          className="h-[88px] w-[88px] rounded-2xl flex items-center justify-center shadow-lg"
                          style={{ backgroundColor: 'rgb(255, 255, 255)' }}
                        >
                          <img alt={merchant} className="h-[56px] w-[56px] object-contain" src={icon} />
                        </div>
                      </div>
                      <div className="relative h-24 w-1 bg-gradient-to-b from-black/30 via-black/15 to-transparent" />
                      <div className="relative z-10 -mt-4 w-full max-w-[450px] overflow-hidden rounded-2xl border border-gray-100 bg-white shadow-xl">
                        <div className="px-5 py-3 text-left">
                          <span className="text-[20px] text-[#09090b]">Payment provider</span>
                        </div>
                        <div className="px-5 pb-3">
                          <div className="flex items-center gap-3 rounded-xl border border-[#09090b] bg-white p-3">
                            <div
                              className="h-11 w-11 shrink-0 rounded-lg flex items-center justify-center"
                              style={{ backgroundColor: 'transparent' }}
                            >
                              <img alt={merchant} className="h-11 w-11 block object-contain" src={icon} />
                            </div>
                            <div className="flex-1 text-left">
                              <p className="font-medium text-[#09090b]">{merchant}</p>
                              <p className="text-sm text-gray-500">Connect {merchant} {verbCap} to Bitcoin</p>
                            </div>
                            <div className="h-6 w-6 shrink-0 rounded-md bg-[#09090b] flex items-center justify-center">
                              <svg className="h-4 w-4 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                                <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                              </svg>
                            </div>
                          </div>
                        </div>
                        <div className="absolute left-1/2 bottom-[-130px] -translate-x-1/2 h-36 w-[280px] rounded-full bg-[#F8C44D]/35 blur-3xl" />
                        <div className="absolute left-1/2 bottom-[-62px] -translate-x-[112px] h-10 w-10 overflow-hidden rounded-full opacity-75 shadow-lg">
                          <img alt="Bitcoin" className="h-full w-full object-cover" src="/castle/images/brand/bitcoin.png" />
                        </div>
                        <div className="absolute left-1/2 bottom-[-88px] translate-x-[92px] h-9 w-9 overflow-hidden rounded-full opacity-60 shadow-lg">
                          <img alt="Bitcoin" className="h-full w-full object-cover" src="/castle/images/brand/bitcoin.png" />
                        </div>
                        <div className="absolute left-1/2 bottom-[-128px] -translate-x-[14px] h-14 w-14 overflow-hidden rounded-full shadow-xl">
                          <img alt="Bitcoin" className="h-full w-full object-cover" src="/castle/images/brand/bitcoin.png" />
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </section>
          </div>

          {/* Logos marquee strip */}
          <section className="pt-8 pb-6 overflow-hidden bg-white">
            <div className="relative overflow-hidden">
              <div className="pointer-events-none absolute inset-y-0 left-0 z-10 w-20 bg-gradient-to-r from-white to-transparent" />
              <div className="pointer-events-none absolute inset-y-0 right-0 z-10 w-20 bg-gradient-to-l from-white to-transparent" />
              <div className="animate-marquee flex w-max items-center gap-16 will-change-transform" style={{ ['--marquee-sections' as string]: '4' }}>
                {[false, true, true, true].map((hidden, dupeIdx) =>
                  [
                    { alt: 'QuickBooks', src: '/castle/images/integrations/logos/quickbooks-logo.svg', h: 'h-[24px] md:h-[30px]' },
                    { alt: 'Xero', src: '/castle/images/integrations/logos/xero-logo.svg', h: 'h-[28px] md:h-[34px]' },
                    { alt: 'Shopify', src: '/castle/images/integrations/logos/shopify-logo.svg', h: 'h-[24px] md:h-[30px]' },
                    { alt: 'Gumroad', src: '/castle/images/integrations/logos/gumroad-logo.svg', h: 'h-[24px] md:h-[30px]' },
                    { alt: 'eBay', src: '/castle/images/integrations/logos/ebay-logo.svg', h: 'h-[24px] md:h-[30px]' },
                    { alt: 'Stripe', src: '/castle/images/integrations/logos/stripe-logo.svg', h: 'h-[36px] md:h-[40px]' },
                    { alt: 'Square', src: '/castle/images/integrations/logos/square-logo.svg', h: 'h-[24px] md:h-[30px]' },
                    { alt: 'PayPal', src: '/castle/images/integrations/logos/paypal-logo.svg', h: 'h-[24px] md:h-[30px]' },
                    { alt: 'Mindbody', src: '/castle/images/integrations/logos/mindbody-logo.svg', h: 'h-[24px] md:h-[30px]' },
                  ].map((logo, i) => (
                    <div key={`${dupeIdx}-${i}`} aria-hidden={hidden} className="flex shrink-0 items-center">
                      <img alt={logo.alt} className={`w-auto grayscale transition-all duration-300 hover:grayscale-0 ${logo.h}`} src={logo.src} />
                    </div>
                  ))
                )}
              </div>
            </div>
          </section>

          {/* Three strategies section */}
          <div id="strategies">
            <section className="py-16 md:py-24 bg-white">
              <div className="container mx-auto px-4">
                <div className="mb-12">
                  <h2 className="mt-6 text-[32px] md:text-[44px] lg:text-[58px] font-light tracking-[-0.05em] leading-[1.03] text-[#09090b] font-px-grotesk max-w-[18ch] md:max-w-none">
                    Three accounts. One <span className="text-castle-blue">compounding treasury.</span>
                  </h2>
                  <div>
                    <p className="mt-3 text-[20px] text-[#4F4D55] leading-[30px]">Pair liquid operating cash with a high yield reserve and a long-term bitcoin position — all in one platform.</p>
                  </div>
                </div>
                <div className="grid gap-8 md:gap-4 lg:gap-5 md:grid-cols-3">
                  {/* Cash card */}
                  <div className="relative">
                    <div
                      aria-hidden="true"
                      className="pointer-events-none absolute inset-x-10 -bottom-1 h-14 rounded-[100%] opacity-30 blur-2xl"
                      style={{ backgroundColor: 'rgb(5, 150, 105)' }}
                    />
                    <div
                      role="link"
                      tabIndex={0}
                      className="group relative z-10 flex h-full cursor-pointer flex-col overflow-hidden rounded-2xl border border-border/70 bg-white p-6 shadow-sm transition-shadow hover:shadow-md focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-[#09090b]/40 md:p-7"
                    >
                      <div className="absolute inset-x-0 top-0 h-1" style={{ backgroundColor: 'rgba(5, 150, 105, 0.4)' }} />
                      <div className="mb-5 flex items-center justify-between">
                        <div className="flex items-center gap-3">
                          <div className="flex items-center justify-center rounded-full p-2.5 bg-[#DCF4EA]">
                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-dollar-sign size-5 text-[#059669]" aria-hidden="true">
                              <line x1="12" x2="12" y1="2" y2="22" />
                              <path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
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
                              <path d="M20 6 9 17l-5-5" />
                            </svg>
                          </div>
                          <span className="text-xs leading-relaxed text-[#27272a]">Reserves backed by short-term U.S. Treasuries — never fractional.</span>
                        </div>
                        <div className="flex items-start gap-3 rounded-xl border border-border/60 bg-white p-3">
                          <div className="mt-0.5 flex size-5 flex-shrink-0 items-center justify-center rounded-md bg-[#DCF4EA]">
                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check size-2.5 text-[#059669]" aria-hidden="true">
                              <path d="M20 6 9 17l-5-5" />
                            </svg>
                          </div>
                          <span className="text-xs leading-relaxed text-[#27272a]">Zero monthly fees, zero minimums, and same-day liquidity in and out.</span>
                        </div>
                      </div>
                      <div className="mt-auto inline-flex items-center gap-1.5 text-[14px] font-semibold text-[#09090b] transition-[gap] duration-200 group-hover:gap-2">
                        Explore Cash
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-arrow-right h-4 w-4" aria-hidden="true">
                          <path d="M5 12h14" />
                          <path d="m12 5 7 7-7 7" />
                        </svg>
                      </div>
                    </div>
                  </div>

                  {/* High Yield card */}
                  <div className="relative">
                    <div
                      aria-hidden="true"
                      className="pointer-events-none absolute inset-x-10 -bottom-1 h-14 rounded-[100%] opacity-30 blur-2xl"
                      style={{ backgroundColor: 'rgb(37, 99, 235)' }}
                    />
                    <div
                      role="link"
                      tabIndex={0}
                      className="group relative z-10 flex h-full cursor-pointer flex-col overflow-hidden rounded-2xl border border-border/70 bg-white p-6 shadow-sm transition-shadow hover:shadow-md focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-[#09090b]/40 md:p-7"
                    >
                      <div className="absolute inset-x-0 top-0 h-1" style={{ backgroundColor: 'rgba(37, 99, 235, 0.4)' }} />
                      <div className="mb-5 flex items-center justify-between">
                        <div className="flex items-center gap-3">
                          <div className="flex items-center justify-center rounded-full p-2.5 bg-[#E7F0FF]">
                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-percent size-5 text-[#2563EB]" aria-hidden="true">
                              <line x1="19" x2="5" y1="5" y2="19" />
                              <circle cx="6.5" cy="6.5" r="2.5" />
                              <circle cx="17.5" cy="17.5" r="2.5" />
                            </svg>
                          </div>
                          <h3 className="text-2xl font-bold tracking-tighter">High Yield</h3>
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
                              <path d="M20 6 9 17l-5-5" />
                            </svg>
                          </div>
                          <span className="text-xs leading-relaxed text-[#27272a]">Earn up to 11.5% — roughly 2x the average HYSA, paid monthly in bitcoin.</span>
                        </div>
                        <div className="flex items-start gap-3 rounded-xl border border-border/60 bg-white p-3">
                          <div className="mt-0.5 flex size-5 flex-shrink-0 items-center justify-center rounded-md bg-[#E7F0FF]">
                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check size-2.5 text-[#2563EB]" aria-hidden="true">
                              <path d="M20 6 9 17l-5-5" />
                            </svg>
                          </div>
                          <span className="text-xs leading-relaxed text-[#27272a]">Tax-deferred treatment via STRC from Strategy. No hold period, no lock-ups.</span>
                        </div>
                      </div>
                      <div className="mt-auto inline-flex items-center gap-1.5 text-[14px] font-semibold text-[#09090b] transition-[gap] duration-200 group-hover:gap-2">
                        Explore High Yield
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-arrow-right h-4 w-4" aria-hidden="true">
                          <path d="M5 12h14" />
                          <path d="m12 5 7 7-7 7" />
                        </svg>
                      </div>
                    </div>
                  </div>

                  {/* Bitcoin card */}
                  <div className="relative">
                    <div
                      aria-hidden="true"
                      className="pointer-events-none absolute inset-x-10 -bottom-1 h-14 rounded-[100%] opacity-30 blur-2xl"
                      style={{ backgroundColor: 'rgb(247, 147, 26)' }}
                    />
                    <div
                      role="link"
                      tabIndex={0}
                      className="group relative z-10 flex h-full cursor-pointer flex-col overflow-hidden rounded-2xl border border-border/70 bg-white p-6 shadow-sm transition-shadow hover:shadow-md focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-[#09090b]/40 md:p-7"
                    >
                      <div className="absolute inset-x-0 top-0 h-1" style={{ backgroundColor: 'rgba(247, 147, 26, 0.4)' }} />
                      <div className="mb-5 flex items-center justify-between">
                        <div className="flex items-center gap-3">
                          <div className="flex items-center justify-center rounded-full p-2.5 bg-[#FFF6E6]">
                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-bitcoin size-5 text-orange-600" aria-hidden="true">
                              <path d="M11.767 19.089c4.924.868 6.14-6.025 1.216-6.894m-1.216 6.894L5.86 18.047m5.908 1.042-.347 1.97m1.563-8.864c4.924.869 6.14-6.025 1.215-6.893m-1.215 6.893-3.94-.694m5.155-6.2L8.29 4.26m5.908 1.042.348-1.97M7.48 20.364l3.126-17.727" />
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
                              <path d="M20 6 9 17l-5-5" />
                            </svg>
                          </div>
                          <span className="text-xs leading-relaxed text-[#27272a]">Protect your purchasing power from inflation with the best performing asset.</span>
                        </div>
                        <div className="flex items-start gap-3 rounded-xl border border-border/60 bg-white p-3">
                          <div className="mt-0.5 flex size-5 flex-shrink-0 items-center justify-center rounded-md bg-[#FFF6E6]">
                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check size-2.5 text-orange-600" aria-hidden="true">
                              <path d="M20 6 9 17l-5-5" />
                            </svg>
                          </div>
                          <span className="text-xs leading-relaxed text-[#27272a]">Automated DCA, revenue splits, and instant buys — set it once and let it run.</span>
                        </div>
                      </div>
                      <div className="mt-auto inline-flex items-center gap-1.5 text-[14px] font-semibold text-[#09090b] transition-[gap] duration-200 group-hover:gap-2">
                        Explore Bitcoin
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-arrow-right h-4 w-4" aria-hidden="true">
                          <path d="M5 12h14" />
                          <path d="m12 5 7 7-7 7" />
                        </svg>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </section>
          </div>

          {/* Features section */}
          <section className="py-16 md:py-24 bg-white relative overflow-hidden">
            <div className="absolute inset-y-0 right-0 w-1/3 dot-pattern-light opacity-30" />
            <div className="container mx-auto px-4 relative">
              <div className="text-center mb-16">
                <div>
                  <div className="inline-flex items-center gap-2 rounded-full border border-gray-200 bg-white px-3 py-1 text-[14px] font-semibold leading-[20px] text-[#474952] shadow-sm">
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-sparkles h-4 w-4" aria-hidden="true">
                      <path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z" />
                      <path d="M20 2v4" />
                      <path d="M22 4h-4" />
                      <circle cx="4" cy="20" r="2" />
                    </svg>
                    Features
                  </div>
                </div>
                <h2 className="mt-6 text-[36px] md:text-[48px] font-light tracking-[-0.03em] leading-[1.1] text-[#09090b] font-px-grotesk">
                  Your Business Treasury, <span className="text-castle-blue">Automated</span>
                </h2>
                <p className="whitespace-pre-wrap mt-3 text-[18px] text-[#525866] leading-[1.5]">
                  Focus on your business, let QuidMint manage the treasury
                </p>
              </div>

              <div className="space-y-24 md:space-y-32">
                {/* Feature 1: Upgrade your balance sheet */}
                <div className="flex flex-col gap-12 lg:flex-row lg:items-center lg:gap-20">
                  <div className="order-1 flex-1 w-full lg:order-none lg:w-1/2">
                    <div className="relative isolate">
                      <div className="pointer-events-none absolute z-0 opacity-60 [mask-image:radial-gradient(ellipse_at_center,black_30%,rgba(0,0,0,0.78)_55%,rgba(0,0,0,0.46)_74%,rgba(0,0,0,0.16)_88%,transparent_100%)] -inset-14 bg-[radial-gradient(ellipse_60%_52%_at_22%_74%,rgba(37,99,235,0.13)_0%,rgba(37,99,235,0.07)_36%,rgba(37,99,235,0.03)_55%,rgba(37,99,235,0)_80%),radial-gradient(ellipse_60%_52%_at_80%_28%,rgba(37,99,235,0.13)_0%,rgba(37,99,235,0.07)_36%,rgba(37,99,235,0.03)_55%,rgba(37,99,235,0)_82%)]" />
                      <div className="relative z-10">
                        <div className="relative mx-auto aspect-square w-full max-w-[560px]">
                          <div
                            className="absolute inset-0 overflow-hidden rounded-3xl border border-[#e6e7eb] bg-white shadow-[0_18px_44px_rgba(15,23,42,0.08)]"
                            style={{ backgroundImage: 'radial-gradient(80% 60% at 25% 20%, rgba(37, 99, 235, 0.18) 0%, rgba(37, 99, 235, 0.04) 55%, rgba(255, 255, 255, 0) 100%), radial-gradient(70% 60% at 80% 80%, rgba(37, 99, 235, 0.14) 0%, rgba(37, 99, 235, 0.03) 55%, rgba(255, 255, 255, 0) 100%)' }}
                          >
                            <div
                              className="absolute inset-0 opacity-[0.35]"
                              style={{ backgroundImage: 'radial-gradient(circle, rgba(37, 99, 235, 0.28) 1px, transparent 1px)', backgroundSize: '22px 22px', maskImage: 'radial-gradient(black 35%, transparent 75%)' }}
                            />
                            <div className="absolute inset-0 flex items-center justify-center p-4 sm:p-10 md:p-14">
                              <div className="flex aspect-square w-full max-w-[460px] items-stretch justify-center sm:max-w-[420px]">
                                <div className="flex h-full w-full flex-col rounded-2xl border border-[#e6e7eb] bg-white/90 shadow-[0_12px_28px_rgba(15,23,42,0.10)] backdrop-blur-sm justify-between gap-3 p-3 sm:gap-6 sm:p-5">
                                  <div className="rounded-xl border border-[#e6e7eb] bg-gradient-to-br from-[#f9fafb] to-white p-3 sm:rounded-2xl sm:p-4">
                                    <div className="flex items-start justify-between gap-2">
                                      <div>
                                        <div className="text-[9px] font-medium uppercase tracking-wider text-[#6b7280] sm:text-[10px]">Total holdings</div>
                                        <div className="mt-0.5 text-[22px] font-bold leading-none tracking-tight text-[#09090b] sm:text-[34px]">$750,000</div>
                                      </div>
                                      <span className="inline-flex items-center gap-1 rounded-full border border-emerald-200 bg-emerald-50 px-1.5 py-0.5 text-[9px] font-semibold text-emerald-700 sm:px-2 sm:text-[10px]">
                                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-trending-up h-2.5 w-2.5 sm:h-3 sm:w-3" aria-hidden="true">
                                          <path d="M16 7h6v6" />
                                          <path d="m22 7-8.5 8.5-5-5L2 17" />
                                        </svg>
                                        +8.2% YTD
                                      </span>
                                    </div>
                                    <div className="mt-2 flex h-1 w-full overflow-hidden rounded-full bg-[#f1f2f5] sm:mt-3 sm:h-1.5">
                                      <div style={{ width: '40%', backgroundColor: 'rgb(5, 150, 105)' }} />
                                      <div style={{ width: '40%', backgroundColor: 'rgb(37, 99, 235)' }} />
                                      <div style={{ width: '20%', backgroundColor: 'rgb(247, 147, 26)' }} />
                                    </div>
                                  </div>
                                  <div className="divide-y divide-[#eef0f3] overflow-hidden rounded-xl border border-[#e6e7eb] bg-white">
                                    <div className="p-2.5 sm:p-3.5">
                                      <div className="flex items-center justify-between">
                                        <div className="flex items-center gap-2 sm:gap-2.5">
                                          <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md sm:h-9 sm:w-9 sm:rounded-lg" style={{ backgroundColor: 'rgb(236, 253, 245)' }}>
                                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-dollar-sign h-4 w-4" aria-hidden="true" style={{ color: 'rgb(5, 150, 105)' }}>
                                              <line x1="12" x2="12" y1="2" y2="22" />
                                              <path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                                            </svg>
                                          </div>
                                          <div>
                                            <div className="text-[11px] font-semibold leading-tight text-[#09090b] sm:text-[13px]">Cash</div>
                                            <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[10px]">Earns up to 3.5%</div>
                                          </div>
                                        </div>
                                        <div className="text-right">
                                          <div className="text-[11px] font-semibold leading-tight text-[#09090b] sm:text-[13px]">$300,000</div>
                                          <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[10px]">40%</div>
                                        </div>
                                      </div>
                                      <div className="mt-2 h-1 overflow-hidden rounded-full bg-[#f1f2f5] sm:mt-2.5 sm:h-1.5">
                                        <div className="h-full rounded-full" style={{ width: '40%', backgroundColor: 'rgb(5, 150, 105)' }} />
                                      </div>
                                    </div>
                                    <div className="p-2.5 sm:p-3.5">
                                      <div className="flex items-center justify-between">
                                        <div className="flex items-center gap-2 sm:gap-2.5">
                                          <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md sm:h-9 sm:w-9 sm:rounded-lg" style={{ backgroundColor: 'rgb(239, 246, 255)' }}>
                                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-percent h-4 w-4" aria-hidden="true" style={{ color: 'rgb(37, 99, 235)' }}>
                                              <line x1="19" x2="5" y1="5" y2="19" />
                                              <circle cx="6.5" cy="6.5" r="2.5" />
                                              <circle cx="17.5" cy="17.5" r="2.5" />
                                            </svg>
                                          </div>
                                          <div>
                                            <div className="text-[11px] font-semibold leading-tight text-[#09090b] sm:text-[13px]">High Yield</div>
                                            <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[10px]">Earns up to 11.5%</div>
                                          </div>
                                        </div>
                                        <div className="text-right">
                                          <div className="text-[11px] font-semibold leading-tight text-[#09090b] sm:text-[13px]">$300,000</div>
                                          <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[10px]">40%</div>
                                        </div>
                                      </div>
                                      <div className="mt-2 h-1 overflow-hidden rounded-full bg-[#f1f2f5] sm:mt-2.5 sm:h-1.5">
                                        <div className="h-full rounded-full" style={{ width: '40%', backgroundColor: 'rgb(37, 99, 235)' }} />
                                      </div>
                                    </div>
                                    <div className="p-2.5 sm:p-3.5">
                                      <div className="flex items-center justify-between">
                                        <div className="flex items-center gap-2 sm:gap-2.5">
                                          <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md sm:h-9 sm:w-9 sm:rounded-lg" style={{ backgroundColor: 'rgb(255, 246, 230)' }}>
                                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-bitcoin h-4 w-4" aria-hidden="true" style={{ color: 'rgb(247, 147, 26)' }}>
                                              <path d="M11.767 19.089c4.924.868 6.14-6.025 1.216-6.894m-1.216 6.894L5.86 18.047m5.908 1.042-.347 1.97m1.563-8.864c4.924.869 6.14-6.025 1.215-6.893m-1.215 6.893-3.94-.694m5.155-6.2L8.29 4.26m5.908 1.042.348-1.97M7.48 20.364l3.126-17.727" />
                                            </svg>
                                          </div>
                                          <div>
                                            <div className="text-[11px] font-semibold leading-tight text-[#09090b] sm:text-[13px]">Bitcoin</div>
                                            <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[10px]">38% 3yr growth</div>
                                          </div>
                                        </div>
                                        <div className="text-right">
                                          <div className="text-[11px] font-semibold leading-tight text-[#09090b] sm:text-[13px]">$150,000</div>
                                          <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[10px]">20%</div>
                                        </div>
                                      </div>
                                      <div className="mt-2 h-1 overflow-hidden rounded-full bg-[#f1f2f5] sm:mt-2.5 sm:h-1.5">
                                        <div className="h-full rounded-full" style={{ width: '20%', backgroundColor: 'rgb(247, 147, 26)' }} />
                                      </div>
                                    </div>
                                  </div>
                                </div>
                              </div>
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                  <div className="order-2 flex-1 w-full space-y-6 lg:order-none lg:w-1/2">
                    <div className="space-y-3">
                      <h3 className="whitespace-pre-wrap text-[32px] font-light tracking-[-0.02em] leading-[1.2] text-[#09090b] font-px-grotesk max-w-[16ch] md:max-w-none">
                        Upgrade your balance sheet
                      </h3>
                      <p className="whitespace-pre-wrap text-[20px] text-[#09090b] leading-[1.5]">
                        Three accounts, one treasury: operating cash at 3.5%, reserves up to 11.5%, and long term holdings in bitcoin — the best performing asset of the decade.
                      </p>
                    </div>
                    <div>
                      <div className="flex items-stretch gap-2">
                        <div className="w-3 bg-[#09090b] rounded-sm flex-shrink-0 self-stretch" />
                        <p className="text-[#09090b] bg-[#f5f5f3] py-3 px-4 rounded-r-lg flex-1 text-[16px]">Designed to grow your treasury without growing your workload. Set thresholds once and let your money go to work.</p>
                      </div>
                    </div>
                    <div className="border-t border-gray-200" />
                    <ul className="flex flex-col gap-3">
                      {[
                        'Earn up to 11.5% on every idle dollar',
                        'Automatically sweep excess cash into bitcoin',
                        'Set limits as a percentage of total holdings',
                      ].map((item) => (
                        <li key={item} className="flex w-fit items-center gap-2 rounded-full border border-zinc-200 bg-zinc-100 p-1.5 pr-2.5 shadow-sm">
                          <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-castle-blue">
                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check h-3 w-3 text-white" aria-hidden="true">
                              <path d="M20 6 9 17l-5-5" />
                            </svg>
                          </div>
                          <span className="font-medium text-[14px] md:text-[18px] text-[#09090b]">{item}</span>
                        </li>
                      ))}
                    </ul>
                  </div>
                </div>

                {/* Feature 2: The modern financial stack */}
                <div className="flex flex-col gap-12 lg:flex-row lg:items-center lg:gap-20 lg:flex-row-reverse">
                  <div className="order-1 flex-1 w-full lg:order-none lg:w-1/2">
                    <div className="relative isolate">
                      <div className="pointer-events-none absolute z-0 opacity-60 [mask-image:radial-gradient(ellipse_at_center,black_30%,rgba(0,0,0,0.78)_55%,rgba(0,0,0,0.46)_74%,rgba(0,0,0,0.16)_88%,transparent_100%)] -left-14 -top-14 -bottom-14 -right-28 bg-[radial-gradient(ellipse_60%_52%_at_24%_30%,rgba(37,99,235,0.14)_0%,rgba(37,99,235,0.08)_36%,rgba(37,99,235,0.03)_55%,rgba(37,99,235,0)_80%),radial-gradient(ellipse_60%_52%_at_78%_72%,rgba(37,99,235,0.13)_0%,rgba(37,99,235,0.07)_36%,rgba(37,99,235,0.03)_55%,rgba(37,99,235,0)_82%)]" />
                      <div className="relative z-10">
                        <div className="relative mx-auto aspect-square w-full max-w-[560px]">
                          <div
                            className="absolute inset-0 overflow-hidden rounded-3xl border border-[#e6e7eb] bg-white shadow-[0_18px_44px_rgba(15,23,42,0.08)]"
                            style={{ backgroundImage: 'radial-gradient(80% 60% at 25% 20%, rgba(37, 99, 235, 0.18) 0%, rgba(37, 99, 235, 0.04) 55%, rgba(255, 255, 255, 0) 100%), radial-gradient(70% 60% at 80% 80%, rgba(37, 99, 235, 0.14) 0%, rgba(37, 99, 235, 0.03) 55%, rgba(255, 255, 255, 0) 100%)' }}
                          >
                            <div
                              className="absolute inset-0 opacity-[0.35]"
                              style={{ backgroundImage: 'radial-gradient(circle, rgba(37, 99, 235, 0.28) 1px, transparent 1px)', backgroundSize: '22px 22px', maskImage: 'radial-gradient(black 35%, transparent 75%)' }}
                            />
                            <div className="absolute inset-0 flex items-center justify-center p-4 sm:p-10 md:p-14">
                              <div className="flex aspect-square w-full max-w-[460px] items-stretch justify-center sm:max-w-[420px]">
                                <div className="flex h-full w-full flex-col rounded-2xl border border-[#e6e7eb] bg-white/90 shadow-[0_12px_28px_rgba(15,23,42,0.10)] backdrop-blur-sm p-3 sm:p-5">
                                  <div className="grid h-full grid-cols-3 gap-2 sm:gap-2.5">
                                    {[
                                      { alt: 'Shopify', src: '/castle/images/integrations/icons/shopify-icon.svg', bg: 'bg-white' },
                                      { alt: 'Stripe', src: '/castle/images/integrations/icons/stripe-icon.svg', bg: '', style: { backgroundColor: 'rgb(99, 91, 255)' } },
                                      { alt: 'Square', src: '/castle/images/integrations/icons/square-icon.svg', bg: 'bg-white' },
                                      { alt: 'PayPal', src: '/castle/images/integrations/icons/paypal-icon.svg', bg: 'bg-white' },
                                      { alt: 'Mindbody', src: '/castle/images/integrations/icons/mindbody-icon.svg', bg: 'bg-white' },
                                      { alt: 'Clover', src: '/castle/images/integrations/icons/clover-icon.svg', bg: 'bg-white' },
                                      { alt: 'eBay', src: '/castle/images/integrations/icons/ebay-icon.svg', bg: 'bg-white' },
                                      { alt: 'Gumroad', src: '/castle/images/integrations/icons/gumroad-icon.svg', bg: '', style: { backgroundColor: 'rgb(255, 144, 232)' } },
                                      { alt: 'Zaprite', src: '/castle/images/integrations/icons/zaprite-icon.svg', bg: '', style: { backgroundColor: 'rgb(34, 201, 151)' } },
                                    ].map((int) => (
                                      <div key={int.alt} className="flex flex-col items-center justify-center gap-1.5 rounded-xl bg-[#f5f5f5] p-2.5 sm:gap-2 sm:p-3">
                                        <div
                                          className={`flex h-11 w-11 items-center justify-center rounded-[10px] shadow-[0_2px_6px_rgba(0,0,0,0.08)] sm:h-12 sm:w-12 ${int.bg}`}
                                          style={int.style}
                                        >
                                          <img alt={int.alt} className="h-7 w-7 object-contain sm:h-8 sm:w-8" src={int.src} />
                                        </div>
                                        <span className="text-[12px] font-semibold text-[#09090b] sm:text-[13px]">{int.alt}</span>
                                      </div>
                                    ))}
                                  </div>
                                </div>
                              </div>
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                  <div className="order-2 flex-1 w-full space-y-6 lg:order-none lg:w-1/2">
                    <div className="space-y-3">
                      <h3 className="whitespace-pre-wrap text-[32px] font-light tracking-[-0.02em] leading-[1.2] text-[#09090b] font-px-grotesk max-w-[15ch] md:max-w-none">
                        The modern financial stack
                      </h3>
                      <p className="whitespace-pre-wrap text-[20px] text-[#09090b] leading-[1.5]">
                        QuidMint plugs into Stripe, Square, PayPal, any of the tools your business already runs on — {verb} convert directly into your treasury assets.
                      </p>
                    </div>
                    <div>
                      <div className="flex items-stretch gap-2">
                        <div className="w-3 bg-[#09090b] rounded-sm flex-shrink-0 self-stretch" />
                        <p className="text-[#09090b] bg-[#f5f5f3] py-3 px-4 rounded-r-lg flex-1 text-[16px]">Utilize revenue splits, then layer recurring bitcoin buys and treasury sweeps on top — no manual intervention required.</p>
                      </div>
                    </div>
                    <div className="border-t border-gray-200" />
                    <ul className="flex flex-col gap-3">
                      {[
                        '10+ integrations: Stripe, Square, PayPal, and more',
                        'Connect in minutes — no complex API keys',
                        `${verbCap} convert directly into your asset allocation`,
                      ].map((item) => (
                        <li key={item} className="flex w-fit items-center gap-2 rounded-full border border-zinc-200 bg-zinc-100 p-1.5 pr-2.5 shadow-sm">
                          <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-castle-blue">
                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check h-3 w-3 text-white" aria-hidden="true">
                              <path d="M20 6 9 17l-5-5" />
                            </svg>
                          </div>
                          <span className="font-medium text-[14px] md:text-[18px] text-[#09090b]">{item}</span>
                        </li>
                      ))}
                    </ul>
                  </div>
                </div>

                {/* Feature 3: Purpose built for businesses */}
                <div className="flex flex-col gap-12 lg:flex-row lg:items-center lg:gap-20">
                  <div className="order-1 flex-1 w-full lg:order-none lg:w-1/2">
                    <div className="relative isolate">
                      <div className="pointer-events-none absolute z-0 opacity-60 [mask-image:radial-gradient(ellipse_at_center,black_30%,rgba(0,0,0,0.78)_55%,rgba(0,0,0,0.46)_74%,rgba(0,0,0,0.16)_88%,transparent_100%)] -inset-14 bg-[radial-gradient(ellipse_60%_52%_at_24%_30%,rgba(37,99,235,0.14)_0%,rgba(37,99,235,0.08)_36%,rgba(37,99,235,0.03)_55%,rgba(37,99,235,0)_80%),radial-gradient(ellipse_60%_52%_at_78%_72%,rgba(37,99,235,0.13)_0%,rgba(37,99,235,0.07)_36%,rgba(37,99,235,0.03)_55%,rgba(37,99,235,0)_82%)]" />
                      <div className="relative z-10">
                        <div className="relative mx-auto aspect-square w-full max-w-[560px]">
                          <div
                            className="absolute inset-0 overflow-hidden rounded-3xl border border-[#e6e7eb] bg-white shadow-[0_18px_44px_rgba(15,23,42,0.08)]"
                            style={{ backgroundImage: 'radial-gradient(80% 60% at 25% 20%, rgba(37, 99, 235, 0.18) 0%, rgba(37, 99, 235, 0.04) 55%, rgba(255, 255, 255, 0) 100%), radial-gradient(70% 60% at 80% 80%, rgba(37, 99, 235, 0.14) 0%, rgba(37, 99, 235, 0.03) 55%, rgba(255, 255, 255, 0) 100%)' }}
                          >
                            <div
                              className="absolute inset-0 opacity-[0.35]"
                              style={{ backgroundImage: 'radial-gradient(circle, rgba(37, 99, 235, 0.28) 1px, transparent 1px)', backgroundSize: '22px 22px', maskImage: 'radial-gradient(black 35%, transparent 75%)' }}
                            />
                            <div className="absolute inset-0 flex items-center justify-center p-4 sm:p-10 md:p-14">
                              <div className="flex aspect-square w-full max-w-[460px] items-stretch justify-center sm:max-w-[420px]">
                                <div className="flex h-full w-full flex-col rounded-2xl border border-[#e6e7eb] bg-white/90 shadow-[0_12px_28px_rgba(15,23,42,0.10)] backdrop-blur-sm justify-between gap-3 p-3 sm:gap-0 sm:p-5">
                                  <div className="flex items-center justify-between">
                                    <span className="text-[12px] font-semibold tracking-[-0.01em] text-[#09090b] sm:text-[14px]">Setup complete</span>
                                    <span className="inline-flex items-center gap-1 rounded-full border border-emerald-200 bg-emerald-50 px-1.5 py-0.5 text-[9px] font-semibold text-emerald-700 sm:gap-1.5 sm:px-2 sm:text-[10px]">
                                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-2.5 w-2.5 sm:h-3 sm:w-3" aria-hidden="true">
                                        <path d="M12 6v6l4 2" />
                                        <circle cx="12" cy="12" r="10" />
                                      </svg>
                                      6 min
                                    </span>
                                  </div>
                                  <div className="space-y-1.5 sm:space-y-2">
                                    <div className="flex items-center gap-2 rounded-lg border border-[#e6e7eb] bg-white p-2 sm:gap-3 sm:rounded-xl sm:p-3">
                                      <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-[#f1f2f5] text-[#09090b] sm:h-9 sm:w-9 sm:rounded-lg [&_svg]:h-3.5 [&_svg]:w-3.5 sm:[&_svg]:h-4 sm:[&_svg]:w-4">
                                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-credit-card h-4 w-4" aria-hidden="true">
                                          <rect width="20" height="14" x="2" y="5" rx="2" />
                                          <line x1="2" x2="22" y1="10" y2="10" />
                                        </svg>
                                      </div>
                                      <div className="min-w-0 flex-1">
                                        <div className="text-[11px] font-semibold leading-tight text-[#09090b] sm:text-[13px]">Revenue conversion</div>
                                        <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[11px]">10% of {verb} converted to bitcoin</div>
                                      </div>
                                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-circle-check h-5 w-5 shrink-0 text-emerald-500 sm:h-6 sm:w-6" aria-hidden="true">
                                        <circle cx="12" cy="12" r="10" />
                                        <path d="m9 12 2 2 4-4" />
                                      </svg>
                                    </div>
                                    <div className="flex items-center gap-2 rounded-lg border border-[#e6e7eb] bg-white p-2 sm:gap-3 sm:rounded-xl sm:p-3">
                                      <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-[#f1f2f5] text-[#09090b] sm:h-9 sm:w-9 sm:rounded-lg [&_svg]:h-3.5 [&_svg]:w-3.5 sm:[&_svg]:h-4 sm:[&_svg]:w-4">
                                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-landmark h-4 w-4" aria-hidden="true">
                                          <path d="M10 18v-7" />
                                          <path d="M11.12 2.198a2 2 0 0 1 1.76.006l7.866 3.847c.476.233.31.949-.22.949H3.474c-.53 0-.695-.716-.22-.949z" />
                                          <path d="M14 18v-7" />
                                          <path d="M18 18v-7" />
                                          <path d="M3 22h18" />
                                          <path d="M6 18v-7" />
                                        </svg>
                                      </div>
                                      <div className="min-w-0 flex-1">
                                        <div className="text-[11px] font-semibold leading-tight text-[#09090b] sm:text-[13px]">Treasury rules</div>
                                        <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[11px]">Hold $10k in cash and sweep excess</div>
                                      </div>
                                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-circle-check h-5 w-5 shrink-0 text-emerald-500 sm:h-6 sm:w-6" aria-hidden="true">
                                        <circle cx="12" cy="12" r="10" />
                                        <path d="m9 12 2 2 4-4" />
                                      </svg>
                                    </div>
                                    <div className="flex items-center gap-2 rounded-lg border border-[#e6e7eb] bg-white p-2 sm:gap-3 sm:rounded-xl sm:p-3">
                                      <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-[#f1f2f5] text-[#09090b] sm:h-9 sm:w-9 sm:rounded-lg [&_svg]:h-3.5 [&_svg]:w-3.5 sm:[&_svg]:h-4 sm:[&_svg]:w-4">
                                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-zap h-4 w-4" aria-hidden="true">
                                          <path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z" />
                                        </svg>
                                      </div>
                                      <div className="min-w-0 flex-1">
                                        <div className="text-[11px] font-semibold leading-tight text-[#09090b] sm:text-[13px]">Same-day transfers</div>
                                        <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[11px]">Enabled via connected bank account</div>
                                      </div>
                                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-circle-check h-5 w-5 shrink-0 text-emerald-500 sm:h-6 sm:w-6" aria-hidden="true">
                                        <circle cx="12" cy="12" r="10" />
                                        <path d="m9 12 2 2 4-4" />
                                      </svg>
                                    </div>
                                    <div className="flex items-center gap-2 rounded-lg border border-[#e6e7eb] bg-white p-2 sm:gap-3 sm:rounded-xl sm:p-3">
                                      <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-[#f1f2f5] text-[#09090b] sm:h-9 sm:w-9 sm:rounded-lg [&_svg]:h-3.5 [&_svg]:w-3.5 sm:[&_svg]:h-4 sm:[&_svg]:w-4">
                                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-file-text h-4 w-4" aria-hidden="true">
                                          <path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z" />
                                          <path d="M14 2v5a1 1 0 0 0 1 1h5" />
                                          <path d="M10 9H8" />
                                          <path d="M16 13H8" />
                                          <path d="M16 17H8" />
                                        </svg>
                                      </div>
                                      <div className="min-w-0 flex-1">
                                        <div className="text-[11px] font-semibold leading-tight text-[#09090b] sm:text-[13px]">QuickBooks connected</div>
                                        <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[11px]">Auto-sync reporting every night</div>
                                      </div>
                                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-circle-check h-5 w-5 shrink-0 text-emerald-500 sm:h-6 sm:w-6" aria-hidden="true">
                                        <circle cx="12" cy="12" r="10" />
                                        <path d="m9 12 2 2 4-4" />
                                      </svg>
                                    </div>
                                    <div className="flex items-center gap-2 rounded-lg border border-[#e6e7eb] bg-white p-2 sm:gap-3 sm:rounded-xl sm:p-3">
                                      <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-[#f1f2f5] text-[#09090b] sm:h-9 sm:w-9 sm:rounded-lg [&_svg]:h-3.5 [&_svg]:w-3.5 sm:[&_svg]:h-4 sm:[&_svg]:w-4">
                                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-eye-off h-4 w-4" aria-hidden="true">
                                          <path d="M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49" />
                                          <path d="M14.084 14.158a3 3 0 0 1-4.242-4.242" />
                                          <path d="M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143" />
                                          <path d="m2 2 20 20" />
                                        </svg>
                                      </div>
                                      <div className="min-w-0 flex-1">
                                        <div className="text-[11px] font-semibold leading-tight text-[#09090b] sm:text-[13px]">Team permissions</div>
                                        <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[11px]">Managers and viewers configured</div>
                                      </div>
                                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-circle-check h-5 w-5 shrink-0 text-emerald-500 sm:h-6 sm:w-6" aria-hidden="true">
                                        <circle cx="12" cy="12" r="10" />
                                        <path d="m9 12 2 2 4-4" />
                                      </svg>
                                    </div>
                                  </div>
                                </div>
                              </div>
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                  <div className="order-2 flex-1 w-full space-y-6 lg:order-none lg:w-1/2">
                    <div className="space-y-3">
                      <h3 className="whitespace-pre-wrap text-[32px] font-light tracking-[-0.02em] leading-[1.2] text-[#09090b] font-px-grotesk max-w-[12ch] md:max-w-none">
                        Purpose built for businesses
                      </h3>
                      <p className="whitespace-pre-wrap text-[20px] text-[#09090b] leading-[1.5]">
                        Institutional treasury tooling, packaged for how everyday businesses actually run — optimize your cash flows while accessing same-day liquidity.
                      </p>
                    </div>
                    <div>
                      <div className="flex items-stretch gap-2">
                        <div className="w-3 bg-[#09090b] rounded-sm flex-shrink-0 self-stretch" />
                        <p className="text-[#09090b] bg-[#f5f5f3] py-3 px-4 rounded-r-lg flex-1 text-[16px]">Great for restaurants, e-commerce, real estate, and more - join businesses of all sizes already using QuidMint.</p>
                      </div>
                    </div>
                    <div className="border-t border-gray-200" />
                    <ul className="flex flex-col gap-3">
                      {[
                        'Sign up in minutes, zero training required',
                        'Operational liquidity the moment you need it',
                        'Native QuickBooks reporting and exports',
                      ].map((item) => (
                        <li key={item} className="flex w-fit items-center gap-2 rounded-full border border-zinc-200 bg-zinc-100 p-1.5 pr-2.5 shadow-sm">
                          <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-castle-blue">
                            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check h-3 w-3 text-white" aria-hidden="true">
                              <path d="M20 6 9 17l-5-5" />
                            </svg>
                          </div>
                          <span className="font-medium text-[14px] md:text-[18px] text-[#09090b]">{item}</span>
                        </li>
                      ))}
                    </ul>
                  </div>
                </div>
              </div>
            </div>
          </section>

          {/* Open account CTA */}
          <div className="px-2 pt-16 sm:px-3 md:pt-24 pb-4 sm:pb-6 bg-white">
            <section
              data-track-location="open_account_cta"
              className="relative overflow-hidden rounded-[20px] px-6 py-16 md:py-20 lg:py-24"
              style={{ border: '1px solid rgba(9, 9, 11, 0.12)', boxShadow: 'rgba(2, 8, 20, 0.1) 0px 16px 32px -14px, rgba(2, 8, 20, 0.06) 0px 6px 14px -6px, rgba(2, 8, 20, 0.04) 0px 1px 2px' }}
            >
              <div
                aria-hidden="true"
                className="pointer-events-none absolute inset-0"
                style={{ background: 'radial-gradient(55% 110% at 0% 50%, rgba(37, 99, 235, 0.34) 0%, rgba(37, 99, 235, 0) 60%), radial-gradient(55% 110% at 100% 50%, rgba(37, 99, 235, 0.34) 0%, rgba(37, 99, 235, 0) 60%), rgb(255, 255, 255)' }}
              />
              <div
                aria-hidden="true"
                className="pointer-events-none absolute inset-0"
                style={{ maskImage: 'radial-gradient(70% 90%, rgba(0, 0, 0, 0.35) 0%, rgba(0, 0, 0, 0.1) 55%, transparent 80%)' }}
              >
                <div className="pointer-events-none absolute inset-0 h-full w-full overflow-hidden opacity-60" aria-hidden="true">
                  <div
                    className="absolute inset-0 transform-gpu"
                    style={{
                      backgroundImage: `url("data:image/svg+xml;utf8,%0A%20%20%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20width%3D%2240%22%20height%3D%2240%22%20viewBox%3D%220%200%2040%2040%22%20fill%3D%22none%22%3E%0A%20%20%20%20%3Cpath%20d%3D%22M20%2014V26M14%2020H26%22%20stroke%3D%22%23E5E7EB%22%20stroke-width%3D%222%22%20stroke-linecap%3D%22round%22%20%2F%3E%0A%20%20%3C%2Fsvg%3E%0A")`,
                      backgroundSize: '40px 40px',
                      opacity: 1,
                    }}
                  />
                </div>
              </div>
              <div className="container relative mx-auto px-2 sm:px-6">
                <div className="mx-auto max-w-3xl text-center">
                  <div>
                    <span className="inline-flex items-center gap-2 rounded-full border border-gray-200 bg-white px-3 py-1 text-[12px] font-semibold uppercase tracking-[0.18em] text-[#474952] shadow-sm">
                      <span className="h-1.5 w-1.5 rounded-full" style={{ backgroundColor: 'rgb(37, 99, 235)' }} />
                      Get Started
                    </span>
                  </div>
                  <h2 className="mt-6 text-[36px] md:text-[52px] lg:text-[60px] font-normal tracking-[-0.05em] leading-[1.02] text-[#09090b] font-px-grotesk">
                    Fortify your treasury in under{' '}
                    <span className="text-[#2563EB]">10 minutes</span>{' '}
                    today.
                  </h2>
                  <div>
                    <p className="mt-5 text-[16px] md:text-[18px] text-[#525866] leading-[1.55] max-w-[48ch] mx-auto">
                      Join the businesses earning yield today and stacking bitcoin for tomorrow — all from one platform built for modern treasuries.
                    </p>
                  </div>
                  <div>
                    <form className="mx-auto mt-10 flex max-w-[480px] flex-col gap-2 sm:flex-row sm:items-center sm:rounded-full sm:border sm:border-[#e6e7eb] sm:bg-white sm:p-1.5 sm:pl-5 sm:shadow-[0_4px_14px_-4px_rgba(9,9,11,0.08),0_1px_2px_rgba(9,9,11,0.04)] sm:transition-[border-color,box-shadow] sm:focus-within:border-[#09090b]/40 sm:focus-within:shadow-[0_6px_20px_-6px_rgba(9,9,11,0.14),0_1px_2px_rgba(9,9,11,0.04)]">
                      <input
                        required
                        placeholder="What's your email?"
                        aria-label="Email address"
                        className="min-w-0 flex-1 rounded-full border border-[#e6e7eb] bg-white px-5 py-3 text-[15px] text-[#09090b] placeholder:text-[#8f8f95] shadow-[0_4px_14px_-4px_rgba(9,9,11,0.08),0_1px_2px_rgba(9,9,11,0.04)] focus:border-[#09090b]/40 focus:outline-none sm:rounded-none sm:border-0 sm:bg-transparent sm:px-0 sm:py-2 sm:shadow-none sm:focus:border-0"
                        type="email"
                      />
                      <button
                        type="submit"
                        data-track-button="true"
                        data-track-label="open_account_cta_start_for_free"
                        className="cursor-pointer inline-flex w-full shrink-0 items-center justify-center gap-1.5 rounded-full border border-white/15 bg-[#17181d] px-5 py-3 text-[14px] font-semibold text-white [text-shadow:0_1px_0_rgba(255,255,255,0.18),0_2px_4px_rgba(0,0,0,0.45)] shadow-[0_2px_0_rgba(10,10,12,0.95),0_8px_20px_rgba(9,9,11,0.28),inset_0_1px_0_rgba(255,255,255,0.14)] transition-[box-shadow,color,gap] duration-200 hover:text-white/85 hover:gap-2 hover:shadow-[0_2px_0_rgba(10,10,12,0.95),0_12px_24px_rgba(9,9,11,0.34),inset_0_1px_0_rgba(255,255,255,0.2)] active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-80 sm:w-auto sm:justify-start sm:py-2.5"
                      >
                        Start for free
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-arrow-right h-4 w-4" aria-hidden="true">
                          <path d="M5 12h14" />
                          <path d="m12 5 7 7-7 7" />
                        </svg>
                      </button>
                    </form>
                  </div>
                  <div>
                    <div className="mt-6 flex flex-col items-center gap-2 text-[12px] text-[#525866] md:flex-row md:justify-center md:gap-6">
                      {['Cash operations', 'High Yield reserves', 'Bitcoin growth'].map((label) => (
                        <span key={label} className="inline-flex items-center gap-1.5">
                          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#2563EB" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                            <path d="M5 13l4 4L19 7" />
                          </svg>
                          {label}
                        </span>
                      ))}
                    </div>
                  </div>
                </div>
              </div>
            </section>
          </div>
        </div>
      </main>
      <SiteFooter />
    </div>
  )
}
