import SiteHeader from '@/components/castle/SiteHeader'
import SiteFooter from '@/components/castle/SiteFooter'

export const metadata = { title: 'FAQs | QuidMint' }

export default function Page() {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />
      <main className="flex-1">

        {/* ── Hero section ── */}
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
            {/* gradient bg */}
            <div
              className="absolute inset-0 pointer-events-none"
              style={{ background: 'linear-gradient(rgb(255, 255, 255) 0%, rgb(245, 247, 250) 100%)' }}
            />

            {/* dot-grid overlay */}
            <div
              className="absolute inset-0 pointer-events-none"
              style={{
                maskImage:
                  'linear-gradient(transparent 0%, rgba(0, 0, 0, 0.15) 35%, rgb(0, 0, 0) 100%)',
              }}
            >
              <div
                className="pointer-events-none absolute inset-0 h-full w-full overflow-hidden opacity-60"
                aria-hidden="true"
              >
                <div
                  className="absolute inset-0 transform-gpu"
                  style={{
                    backgroundImage:
                      "url(\"data:image/svg+xml;utf8,%0A%20%20%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20width%3D%2240%22%20height%3D%2240%22%20viewBox%3D%220%200%2040%2040%22%20fill%3D%22none%22%3E%0A%20%20%20%20%3Cpath%20d%3D%22M20%2014V26M14%2020H26%22%20stroke%3D%22%23E5E7EB%22%20stroke-width%3D%222%22%20stroke-linecap%3D%22round%22%20%2F%3E%0A%20%20%3C%2Fsvg%3E%0A\")",
                    backgroundSize: '40px 40px',
                    opacity: 1,
                  }}
                />
              </div>
            </div>

            {/* hero copy */}
            <div className="container relative mx-auto px-4 sm:px-8">
              <div className="mx-auto max-w-4xl text-center">
                <div className="mb-3 inline-flex items-center gap-2 rounded-full px-4 py-1.5 text-sm font-medium bg-castle-blue/10 text-castle-blue">
                  Help Center
                </div>
                <h1 className="mb-3 text-[36px] md:text-[56px] lg:text-[64px] font-normal tracking-[-0.05em] leading-[1] text-[#09090b] font-px-grotesk">
                  How can we help?
                </h1>
                <p className="mb-8 text-[18px] md:text-[20px] text-[#525866] leading-[1.4] max-w-2xl mx-auto font-normal">
                  Find answers to common questions about QuidMint, bitcoin treasury management, and getting started with our platform.
                </p>
              </div>
            </div>

            {/* search + categories */}
            <div className="relative">
              <div className="mt-8 space-y-10">

                {/* search input */}
                <div className="px-4 md:px-0">
                  <div className="relative w-full max-w-2xl mx-auto">
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
                      className="lucide lucide-search absolute left-5 top-1/2 h-5 w-5 -translate-y-1/2 text-[#525866]"
                      aria-hidden="true"
                    >
                      <path d="m21 21-4.34-4.34" />
                      <circle cx="11" cy="11" r="8" />
                    </svg>
                    <input
                      className="file:text-foreground placeholder:text-muted-foreground selection:bg-primary selection:text-primary-foreground dark:bg-input/30 flex w-full min-w-0 border px-3 py-1 transition-[color,box-shadow] outline-none file:inline-flex file:h-7 file:border-0 file:bg-transparent file:text-sm file:font-medium disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50 md:text-sm focus-visible:ring-[3px] aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 aria-invalid:border-destructive h-16 pl-14 pr-4 text-lg placeholder:text-lg rounded-xl border-gray-200 bg-white shadow-sm focus-visible:ring-castle-blue/50 focus-visible:border-castle-blue"
                      placeholder="Search for articles..."
                      type="search"
                      defaultValue=""
                    />
                  </div>
                </div>

                {/* browse by category */}
                <div className="px-4 md:px-16 pb-8 md:pb-10">
                  <h2 className="whitespace-pre-wrap text-2xl font-bold tracking-tight text-center mb-8 font-px-grotesk">
                    Browse by category
                  </h2>
                  <div className="grid grid-cols-2 gap-3 sm:flex sm:flex-wrap sm:justify-center">

                    {/* General */}
                    <div className="w-full sm:w-auto">
                      <div className="w-full sm:w-[230px]">
                        <a
                          href="/faqs?category=general"
                          className="group flex h-full min-h-[170px] w-full flex-col rounded-xl border border-gray-200 bg-white p-4 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md sm:min-h-[220px] sm:p-6"
                        >
                          <div className="mb-4 flex h-12 w-12 items-center justify-center rounded-lg bg-castle-blue/10">
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
                              className="lucide lucide-folder h-6 w-6 text-castle-blue"
                              aria-hidden="true"
                            >
                              <path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z" />
                            </svg>
                          </div>
                          <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">General</h3>
                          <p className="mb-4 hidden flex-grow text-sm leading-relaxed text-[#525866] sm:block">Common questions about QuidMint and our mission</p>
                          <p className="text-sm font-medium text-castle-blue">3 articles</p>
                        </a>
                      </div>
                    </div>

                    {/* Product */}
                    <div className="w-full sm:w-auto">
                      <div className="w-full sm:w-[230px]">
                        <a
                          href="/faqs?category=product"
                          className="group flex h-full min-h-[170px] w-full flex-col rounded-xl border border-gray-200 bg-white p-4 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md sm:min-h-[220px] sm:p-6"
                        >
                          <div className="mb-4 flex h-12 w-12 items-center justify-center rounded-lg bg-castle-blue/10">
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
                              className="lucide lucide-box h-6 w-6 text-castle-blue"
                              aria-hidden="true"
                            >
                              <path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z" />
                              <path d="m3.3 7 8.7 5 8.7-5" />
                              <path d="M12 22V12" />
                            </svg>
                          </div>
                          <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Product</h3>
                          <p className="mb-4 hidden flex-grow text-sm leading-relaxed text-[#525866] sm:block">Features, functionality, and how to use QuidMint</p>
                          <p className="text-sm font-medium text-castle-blue">5 articles</p>
                        </a>
                      </div>
                    </div>

                    {/* Security */}
                    <div className="w-full sm:w-auto">
                      <div className="w-full sm:w-[230px]">
                        <a
                          href="/faqs?category=security"
                          className="group flex h-full min-h-[170px] w-full flex-col rounded-xl border border-gray-200 bg-white p-4 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md sm:min-h-[220px] sm:p-6"
                        >
                          <div className="mb-4 flex h-12 w-12 items-center justify-center rounded-lg bg-castle-blue/10">
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
                              className="lucide lucide-shield h-6 w-6 text-castle-blue"
                              aria-hidden="true"
                            >
                              <path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z" />
                            </svg>
                          </div>
                          <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Security</h3>
                          <p className="mb-4 hidden flex-grow text-sm leading-relaxed text-[#525866] sm:block">Account protection and data security</p>
                          <p className="text-sm font-medium text-castle-blue">3 articles</p>
                        </a>
                      </div>
                    </div>

                    {/* Integrations */}
                    <div className="w-full sm:w-auto">
                      <div className="w-full sm:w-[230px]">
                        <a
                          href="/faqs?category=integrations"
                          className="group flex h-full min-h-[170px] w-full flex-col rounded-xl border border-gray-200 bg-white p-4 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md sm:min-h-[220px] sm:p-6"
                        >
                          <div className="mb-4 flex h-12 w-12 items-center justify-center rounded-lg bg-castle-blue/10">
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
                              className="lucide lucide-plug h-6 w-6 text-castle-blue"
                              aria-hidden="true"
                            >
                              <path d="M12 22v-5" />
                              <path d="M15 8V2" />
                              <path d="M17 8a1 1 0 0 1 1 1v4a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V9a1 1 0 0 1 1-1z" />
                              <path d="M9 8V2" />
                            </svg>
                          </div>
                          <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Integrations</h3>
                          <p className="mb-4 hidden flex-grow text-sm leading-relaxed text-[#525866] sm:block">Connecting your revenue platforms</p>
                          <p className="text-sm font-medium text-castle-blue">1 article</p>
                        </a>
                      </div>
                    </div>

                    {/* Billing */}
                    <div className="w-full sm:w-auto">
                      <div className="w-full sm:w-[230px]">
                        <a
                          href="/faqs?category=billing"
                          className="group flex h-full min-h-[170px] w-full flex-col rounded-xl border border-gray-200 bg-white p-4 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md sm:min-h-[220px] sm:p-6"
                        >
                          <div className="mb-4 flex h-12 w-12 items-center justify-center rounded-lg bg-castle-blue/10">
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
                              className="lucide lucide-credit-card h-6 w-6 text-castle-blue"
                              aria-hidden="true"
                            >
                              <rect width="20" height="14" x="2" y="5" rx="2" />
                              <line x1="2" x2="22" y1="10" y2="10" />
                            </svg>
                          </div>
                          <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Billing</h3>
                          <p className="mb-4 hidden flex-grow text-sm leading-relaxed text-[#525866] sm:block">Pricing, fees, and payment methods</p>
                          <p className="text-sm font-medium text-castle-blue">1 article</p>
                        </a>
                      </div>
                    </div>

                  </div>
                </div>
              </div>
            </div>
          </section>
        </div>

        {/* ── Articles listing section ── */}
        <section className="py-12">
          <div className="container mx-auto px-4">

            {/* filter pills */}
            <div className="flex flex-wrap items-center gap-2 mb-8">
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-castle-blue text-white">All articles</button>
              </div>
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-gray-100 text-[#525866] hover:bg-gray-200">General</button>
              </div>
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-gray-100 text-[#525866] hover:bg-gray-200">Product</button>
              </div>
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-gray-100 text-[#525866] hover:bg-gray-200">Security</button>
              </div>
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-gray-100 text-[#525866] hover:bg-gray-200">Integrations</button>
              </div>
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-gray-100 text-[#525866] hover:bg-gray-200">Billing</button>
              </div>
            </div>

            {/* section heading */}
            <div className="mb-6">
              <h2 className="whitespace-pre-wrap text-2xl font-bold tracking-tight font-px-grotesk">
                Latest articles
              </h2>
            </div>

            {/* article cards grid */}
            <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">

              {/* Family Plan – Security */}
              <div>
                <a href="/faqs/family-plan" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">Security</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>5 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">What is the Family Plan?</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">How several people co-own ONE self-custodied liquidity position under an n-of-m multisig — so no single member, the host, or the operator can move the funds, and the group shares one secure (SGX) node instead of running one each.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 1 – Billing */}
              <div>
                <a href="/faqs/linking-bank-account" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">Billing</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>5 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Linking your bank account</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">How to securely connect your bank account to QuidMint using Plaid.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 2 – General */}
              <div>
                <a href="/faqs/supported-countries" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">General</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>4 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">What countries do we support?</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">Information about QuidMint's availability and supported regions.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 3 – General */}
              <div>
                <a href="/faqs/what-is-castle" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">General</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>6 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">What is QuidMint?</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">Learn about QuidMint, the bitcoin treasury platform designed for businesses.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 4 – General */}
              <div>
                <a href="/faqs/why-bitcoin" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">General</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>7 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Why does QuidMint focus on Bitcoin?</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">Understanding why QuidMint is bitcoin-only and doesn't support other cryptocurrencies.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 5 – Integrations */}
              <div>
                <a href="/faqs/revenue-automation" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">Integrations</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>8 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">How revenue automation works</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">Understand how QuidMint automatically converts your sales revenue to bitcoin.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 6 – Product */}
              <div>
                <a href="/faqs/how-to-buy-bitcoin" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">Product</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>6 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">How to buy Bitcoin with QuidMint</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">A step-by-step guide to making your first bitcoin purchase on QuidMint.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 7 – Product */}
              <div>
                <a href="/faqs/recurring-buys" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">Product</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>7 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Setting up dollar-cost averaging</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">Learn how to automate your bitcoin purchases with scheduled recurring buys.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 8 – Product */}
              <div>
                <a href="/faqs/transaction-statuses" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">Product</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>5 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Understanding statuses</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">Learn what each transaction status means on QuidMint.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 9 – Product */}
              <div>
                <a href="/faqs/treasury-rules-sweep" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">Product</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>7 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Treasury rules and sweeps</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">Configure automatic rules to convert your cash balance to bitcoin.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 10 – Product */}
              <div>
                <a href="/faqs/withdrawing-bitcoin" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">Product</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>6 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Withdrawing Bitcoin to your wallet</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">How to withdraw your bitcoin to an external wallet for self-custody.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 11 – Security */}
              <div>
                <a href="/faqs/identity-verification" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">Security</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>6 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Identity verification process</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">What to expect during QuidMint's KYC verification process.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

              {/* 12 – Security */}
              <div>
                <a href="/faqs/organization-roles" className="group flex flex-col rounded-xl border border-gray-200 bg-white p-6 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md">
                  <div className="flex items-start justify-between gap-4 mb-3">
                    <span className="inline-flex items-center rounded-full bg-castle-blue/10 px-3 py-1 text-xs font-medium text-castle-blue">Security</span>
                    <div className="flex items-center gap-1 text-xs text-[#525866] ml-auto">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                        <path d="M12 6v6l4 2" />
                        <circle cx="12" cy="12" r="10" />
                      </svg>
                      <span>5 min read</span>
                    </div>
                  </div>
                  <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors">Organization roles and permissions</h3>
                  <p className="text-sm text-[#525866] leading-relaxed flex-grow">Understand the different user roles and permissions in QuidMint.</p>
                  <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                    <span>Read article</span>
                    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                      <path d="m9 18 6-6-6-6" />
                    </svg>
                  </div>
                </a>
              </div>

            </div>
          </div>
        </section>

      </main>
      <SiteFooter />
    </div>
  )
}
