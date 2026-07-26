import SiteHeader from '@/components/castle/SiteHeader'
import SiteFooter from '@/components/castle/SiteFooter'

export const metadata = { title: 'Security | QuidMint' }

export default function Page() {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />
      <main className="flex-1">

        {/* Hero */}
        <div className="px-2 sm:px-3 pt-2 sm:pt-3 pb-4 sm:pb-6 bg-white">
          <section
            data-track-location="hero"
            className="relative overflow-hidden rounded-[20px] pt-[140px] pb-0"
            style={{
              border: '1px solid rgba(9, 9, 11, 0.12)',
              boxShadow:
                'rgba(2, 8, 20, 0.1) 0px 16px 32px -14px, rgba(2, 8, 20, 0.06) 0px 6px 14px -6px, rgba(2, 8, 20, 0.04) 0px 1px 2px',
            }}
          >
            <div
              className="absolute inset-0 pointer-events-none"
              style={{ background: 'linear-gradient(rgb(247, 247, 247) 0%, rgb(247, 247, 247) 100%)' }}
            />
            <div className="container relative mx-auto px-4 sm:px-8">
              <div className="mx-auto max-w-4xl text-center">
                <h1 className="mb-3 text-[36px] md:text-[56px] lg:text-[64px] font-normal tracking-[-0.05em] leading-[1] text-[#09090b] font-px-grotesk">
                  Institutional grade infrastructure powered by BitGo
                </h1>
                <p className="whitespace-pre-wrap mb-8 text-[18px] md:text-[20px] text-[#525866] leading-[1.4] max-w-2xl mx-auto font-normal">
                  QuidMint&apos;s first-of-its-kind Bitcoin treasury solution is built on regulated and secure infrastructure in partnership with BitGo.
                </p>
              </div>
            </div>
            <div className="relative">
              <div className="container mx-auto px-4 pb-12 md:pb-16">
                <div className="mx-auto flex max-w-4xl justify-center">
                  <div className="flex flex-col items-center gap-2 px-7 py-5 md:flex-row md:items-center md:gap-5">
                    <img alt="QuidMint" className="h-8 w-auto md:h-10" src="/castle/images/brand/castle-black.svg" />
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      width="24"
                      height="24"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="2"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      className="lucide lucide-x h-6 w-6"
                      aria-hidden="true"
                    >
                      <path d="M18 6 6 18" />
                      <path d="m6 6 12 12" />
                    </svg>
                    <img
                      alt="BitGo"
                      className="h-14 w-auto md:h-16 mx-[-12px] my-[-8px]"
                      src="/castle/images/investors/bitgo.png"
                    />
                  </div>
                </div>
              </div>
            </div>
          </section>
        </div>

        {/* Why BitGo */}
        <section className="py-16 md:py-20">
          <div className="absolute inset-0 dot-pattern-light opacity-40" />
          <div className="container mx-auto px-4 relative">
            <div className="mx-auto max-w-4xl text-center">
              <div>
                <div className="inline-flex items-center gap-2 rounded-full border border-gray-200 bg-white px-3 py-1 text-[14px] font-semibold leading-[20px] text-[#474952] shadow-sm">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    width="24"
                    height="24"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    className="lucide lucide-sparkles h-4 w-4"
                    aria-hidden="true"
                  >
                    <path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z" />
                    <path d="M20 2v4" />
                    <path d="M22 4h-4" />
                    <circle cx="4" cy="20" r="2" />
                  </svg>
                  Why BitGo
                </div>
              </div>
              <h2 className="mt-6 text-[34px] md:text-[44px] font-normal tracking-[-0.03em] leading-[1.1] text-[#09090b] font-px-grotesk max-w-[14ch] md:max-w-none mx-auto">
                A global operator with scale
              </h2>
              <p className="whitespace-pre-wrap mt-3 text-[17px] md:text-[19px] leading-[1.5] text-[#525866]">
                BitGo serves thousands of institutional clients, highlighting the scale and operating maturity behind the custody infrastructure supporting QuidMint.
              </p>
            </div>
            <div className="mx-auto mt-10 mb-10 max-w-4xl">
              <div className="border-t-2 border-dashed border-gray-300" />
            </div>
            <div className="flex flex-wrap justify-center gap-14 md:gap-20 lg:gap-24">
              <div className="text-center max-w-[220px]">
                <div
                  className="text-[42px] font-semibold leading-[1] text-[#37394a] font-clash-display"
                  style={{ letterSpacing: '-1.8px' }}
                >
                  $0T+
                </div>
                <div className="mt-2 text-[18px] font-medium text-[#525866]">Lifetime Transactions</div>
              </div>
              <div className="text-center max-w-[220px]">
                <div
                  className="text-[42px] font-semibold leading-[1] text-[#37394a] font-clash-display"
                  style={{ letterSpacing: '-1.8px' }}
                >
                  $0B+
                </div>
                <div className="mt-2 text-[18px] font-medium text-[#525866]">Assets Under Custody</div>
              </div>
              <div className="text-center max-w-[220px]">
                <div
                  className="text-[42px] font-semibold leading-[1] text-[#37394a] font-clash-display"
                  style={{ letterSpacing: '-1.8px' }}
                >
                  0
                </div>
                <div className="mt-2 text-[18px] font-medium text-[#525866]">Operating Since</div>
              </div>
            </div>
          </div>
        </section>

        {/* Security Architecture */}
        <section className="py-16 md:py-20">
          <div className="container mx-auto px-4">
            <div className="mx-auto mb-10 max-w-3xl text-center">
              <div>
                <div className="inline-flex items-center gap-2 rounded-full border border-gray-200 bg-white px-3 py-1 text-[14px] font-semibold leading-[20px] text-[#474952] shadow-sm">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    width="24"
                    height="24"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    className="lucide lucide-sparkles h-4 w-4"
                    aria-hidden="true"
                  >
                    <path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z" />
                    <path d="M20 2v4" />
                    <path d="M22 4h-4" />
                    <circle cx="4" cy="20" r="2" />
                  </svg>
                  Security Architecture
                </div>
              </div>
              <h2 className="mt-6 text-[34px] md:text-[50px] font-normal tracking-[-0.03em] leading-[1.1] text-[#09090b] font-px-grotesk">
                Bitcoin security and custody{' '}
                <span className="text-castle-blue">designed for businesses</span>
              </h2>
            </div>
            <div className="mx-auto grid max-w-6xl gap-6 md:grid-cols-2">
              {/* Card 1 */}
              <div className="flex">
                <div className="bg-card text-card-foreground flex flex-col gap-6 rounded-xl border relative h-full overflow-hidden border-border py-0 shadow-sm">
                  <div
                    aria-hidden="true"
                    className="pointer-events-none absolute inset-x-0 top-0 h-32 -translate-y-10 blur-2xl"
                    style={{ background: 'linear-gradient(90deg, transparent 0%, rgba(37, 99, 255, 0.08) 40%, rgba(37, 99, 255, 0.24) 100%)' }}
                  />
                  <div className="@container/card-header grid auto-rows-min grid-rows-[auto_auto] items-start gap-2 px-6 has-data-[slot=card-action]:grid-cols-[1fr_auto] [.border-b]:pb-6 relative z-10 pt-6">
                    <div className="text-[28px] font-normal tracking-[-0.03em] leading-[1.1] text-[#09090b] font-px-grotesk">
                      Security and custody foundation
                    </div>
                    <p className="mt-1 text-[16px] leading-[1.5] text-[#525866]">
                      BitGo provides institutional custody infrastructure with the highest security protections for business treasury operations.
                    </p>
                  </div>
                  <div className="px-6">
                    <div className="border-t border-gray-200" />
                  </div>
                  <div className="px-6 relative z-10 pt-4 pb-6">
                    <ul className="space-y-3">
                      {[
                        'Qualified custody model for business treasury operations',
                        '100% cold storage design for custody wallet assets',
                        'Up to $250M insurance coverage for qualified custody assets',
                        'Multi-party approvals and role-based controls enforce operational governance',
                        'Independent security audits, including SOC certifications',
                      ].map((item) => (
                        <li key={item} className="flex items-start gap-2 text-[16px] leading-[1.45] text-[#09090b]">
                          <div className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-castle-blue/10">
                            <svg
                              xmlns="http://www.w3.org/2000/svg"
                              width="24"
                              height="24"
                              viewBox="0 0 24 24"
                              fill="none"
                              stroke="currentColor"
                              strokeWidth="2"
                              strokeLinecap="round"
                              strokeLinejoin="round"
                              className="lucide lucide-check h-3 w-3 text-castle-blue"
                              aria-hidden="true"
                            >
                              <path d="M20 6 9 17l-5-5" />
                            </svg>
                          </div>
                          <span>{item}</span>
                        </li>
                      ))}
                    </ul>
                  </div>
                </div>
              </div>

              {/* Card 2 */}
              <div className="flex">
                <div className="bg-card text-card-foreground flex flex-col gap-6 rounded-xl border relative h-full overflow-hidden border-border py-0 shadow-sm">
                  <div
                    aria-hidden="true"
                    className="pointer-events-none absolute inset-x-0 top-0 h-32 -translate-y-10 blur-2xl"
                    style={{ background: 'linear-gradient(90deg, transparent 0%, rgba(37, 99, 255, 0.08) 40%, rgba(37, 99, 255, 0.24) 100%)' }}
                  />
                  <div className="@container/card-header grid auto-rows-min grid-rows-[auto_auto] items-start gap-2 px-6 has-data-[slot=card-action]:grid-cols-[1fr_auto] [.border-b]:pb-6 relative z-10 pt-6">
                    <div className="text-[28px] font-normal tracking-[-0.03em] leading-[1.1] text-[#09090b] font-px-grotesk">
                      US regulation and compliance
                    </div>
                    <p className="mt-1 text-[16px] leading-[1.5] text-[#525866]">
                      QuidMint serves US businesses through US-regulated BitGo entities, with additional transparency as a public company.
                    </p>
                  </div>
                  <div className="px-6">
                    <div className="border-t border-gray-200" />
                  </div>
                  <div className="px-6 relative z-10 pt-4 pb-6">
                    <ul className="space-y-3">
                      {[
                        'BitGo Bank & Trust, National Association is OCC-chartered in the United States',
                        'BitGo New York Trust Company, LLC is a qualified custodian regulated by NYDFS',
                        'BitGo is a public company traded on the NYSE',
                        'SEC S-1/A filings provide full operational transparency',
                      ].map((item) => (
                        <li key={item} className="flex items-start gap-2 text-[16px] leading-[1.45] text-[#09090b]">
                          <div className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-castle-blue/10">
                            <svg
                              xmlns="http://www.w3.org/2000/svg"
                              width="24"
                              height="24"
                              viewBox="0 0 24 24"
                              fill="none"
                              stroke="currentColor"
                              strokeWidth="2"
                              strokeLinecap="round"
                              strokeLinejoin="round"
                              className="lucide lucide-check h-3 w-3 text-castle-blue"
                              aria-hidden="true"
                            >
                              <path d="M20 6 9 17l-5-5" />
                            </svg>
                          </div>
                          <span>{item}</span>
                        </li>
                      ))}
                    </ul>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

      </main>
      <SiteFooter />
    </div>
  )
}
