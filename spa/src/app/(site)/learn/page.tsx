import SiteHeader from '@/components/castle/SiteHeader'
import SiteFooter from '@/components/castle/SiteFooter'

export const metadata = { title: 'Learn | QuidMint' }

export default function Page() {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />
      <main className="flex-1">
        {/* Hero section */}
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
            {/* Background gradient */}
            <div
              className="absolute inset-0 pointer-events-none"
              style={{ background: 'linear-gradient(rgb(255, 255, 255) 0%, rgb(245, 247, 250) 100%)' }}
            />
            {/* Grid pattern overlay */}
            <div
              className="absolute inset-0 pointer-events-none"
              style={{ maskImage: 'linear-gradient(transparent 0%, rgba(0, 0, 0, 0.15) 35%, rgb(0, 0, 0) 100%)' }}
            >
              <div className="pointer-events-none absolute inset-0 h-full w-full overflow-hidden opacity-60" aria-hidden="true">
                <div
                  className="absolute inset-0 transform-gpu"
                  style={{
                    backgroundImage:
                      'url("data:image/svg+xml;utf8,%0A%20%20%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20width%3D%2240%22%20height%3D%2240%22%20viewBox%3D%220%200%2040%2040%22%20fill%3D%22none%22%3E%0A%20%20%20%20%3Cpath%20d%3D%22M20%2014V26M14%2020H26%22%20stroke%3D%22%23E5E7EB%22%20stroke-width%3D%222%22%20stroke-linecap%3D%22round%22%20%2F%3E%0A%20%20%3C%2Fsvg%3E%0A")',
                    backgroundSize: '40px 40px',
                    opacity: 1,
                  }}
                />
              </div>
            </div>

            {/* Hero content */}
            <div className="container relative mx-auto px-4 sm:px-8">
              <div className="mx-auto max-w-4xl text-center">
                <div className="mb-3 inline-flex items-center gap-2 rounded-full px-4 py-1.5 text-sm font-medium bg-castle-blue/10 text-castle-blue">
                  Education Center
                </div>
                <h1 className="mb-3 text-[36px] md:text-[56px] lg:text-[64px] font-normal tracking-[-0.05em] leading-[1] text-[#09090b] font-px-grotesk">
                  Learn About Bitcoin
                </h1>
                <p className="mb-8 text-[18px] md:text-[20px] text-[#525866] leading-[1.4] max-w-2xl mx-auto font-normal">
                  Master Bitcoin treasury management with guides, tutorials, and insights for business owners. From basics to advanced strategies.
                </p>
              </div>
            </div>

            {/* Search + categories */}
            <div className="relative">
              <div className="mt-8 space-y-10">
                {/* Search bar */}
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
                      placeholder="Search articles..."
                      type="search"
                      defaultValue=""
                    />
                  </div>
                </div>

                {/* Category grid */}
                <div className="px-4 md:px-16 pb-8 md:pb-10">
                  <h2 className="text-2xl font-bold tracking-tight text-center mb-8 font-px-grotesk">
                    Browse by category
                  </h2>
                  <div className="mx-auto grid max-w-4xl grid-cols-2 gap-3 sm:grid-cols-3 sm:gap-4">
                    {/* Announcements */}
                    <div className="h-full">
                      <a
                        href="/learn?category=announcements"
                        className="group flex h-full w-full flex-col rounded-xl border border-gray-200 bg-white p-4 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md sm:p-5"
                      >
                        <div className="mb-2 flex items-center gap-2.5">
                          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-castle-blue/10">
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
                              className="lucide lucide-megaphone h-4 w-4 text-castle-blue"
                              aria-hidden="true"
                            >
                              <path d="M11 6a13 13 0 0 0 8.4-2.8A1 1 0 0 1 21 4v12a1 1 0 0 1-1.6.8A13 13 0 0 0 11 14H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2z" />
                              <path d="M6 14a12 12 0 0 0 2.4 7.2 2 2 0 0 0 3.2-2.4A8 8 0 0 1 10 14" />
                              <path d="M8 6v8" />
                            </svg>
                          </div>
                          <h3 className="text-base font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors sm:text-lg">
                            Announcements
                          </h3>
                        </div>
                        <p className="mb-3 hidden flex-grow text-sm leading-relaxed text-[#525866] sm:block">
                          Product launches, updates, and news from QuidMint
                        </p>
                        <p className="text-sm font-medium text-castle-blue">1 article</p>
                      </a>
                    </div>

                    {/* Bitcoin Basics */}
                    <div className="h-full">
                      <a
                        href="/learn?category=bitcoin-basics"
                        className="group flex h-full w-full flex-col rounded-xl border border-gray-200 bg-white p-4 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md sm:p-5"
                      >
                        <div className="mb-2 flex items-center gap-2.5">
                          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-castle-blue/10">
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
                              className="lucide lucide-coins h-4 w-4 text-castle-blue"
                              aria-hidden="true"
                            >
                              <circle cx="8" cy="8" r="6" />
                              <path d="M18.09 10.37A6 6 0 1 1 10.34 18" />
                              <path d="M7 6h1v4" />
                              <path d="m16.71 13.88.7.71-2.82 2.82" />
                            </svg>
                          </div>
                          <h3 className="text-base font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors sm:text-lg">
                            Bitcoin Basics
                          </h3>
                        </div>
                        <p className="mb-3 hidden flex-grow text-sm leading-relaxed text-[#525866] sm:block">
                          Foundations of Bitcoin for business owners
                        </p>
                        <p className="text-sm font-medium text-castle-blue">3 articles</p>
                      </a>
                    </div>

                    {/* Treasury Mgmt */}
                    <div className="h-full">
                      <a
                        href="/learn?category=treasury-management"
                        className="group flex h-full w-full flex-col rounded-xl border border-gray-200 bg-white p-4 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md sm:p-5"
                      >
                        <div className="mb-2 flex items-center gap-2.5">
                          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-castle-blue/10">
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
                              className="lucide lucide-landmark h-4 w-4 text-castle-blue"
                              aria-hidden="true"
                            >
                              <path d="M10 18v-7" />
                              <path d="M11.12 2.198a2 2 0 0 1 1.76.006l7.866 3.847c.476.233.31.949-.22.949H3.474c-.53 0-.695-.716-.22-.949z" />
                              <path d="M14 18v-7" />
                              <path d="M18 18v-7" />
                              <path d="M3 22h18" />
                              <path d="M6 18v-7" />
                            </svg>
                          </div>
                          <h3 className="text-base font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors sm:text-lg">
                            Treasury Mgmt
                          </h3>
                        </div>
                        <p className="mb-3 hidden flex-grow text-sm leading-relaxed text-[#525866] sm:block">
                          Strategies for building your Bitcoin reserve
                        </p>
                        <p className="text-sm font-medium text-castle-blue">3 articles</p>
                      </a>
                    </div>

                    {/* Getting Started */}
                    <div className="h-full">
                      <a
                        href="/learn?category=getting-started"
                        className="group flex h-full w-full flex-col rounded-xl border border-gray-200 bg-white p-4 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md sm:p-5"
                      >
                        <div className="mb-2 flex items-center gap-2.5">
                          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-castle-blue/10">
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
                              className="lucide lucide-rocket h-4 w-4 text-castle-blue"
                              aria-hidden="true"
                            >
                              <path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z" />
                              <path d="m12 15-3-3a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.35 22.35 0 0 1-4 2z" />
                              <path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0" />
                              <path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5" />
                            </svg>
                          </div>
                          <h3 className="text-base font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors sm:text-lg">
                            Getting Started
                          </h3>
                        </div>
                        <p className="mb-3 hidden flex-grow text-sm leading-relaxed text-[#525866] sm:block">
                          Step-by-step guides for setting up and using QuidMint
                        </p>
                        <p className="text-sm font-medium text-castle-blue">3 articles</p>
                      </a>
                    </div>

                    {/* Business Finance */}
                    <div className="h-full">
                      <a
                        href="/learn?category=business-finance"
                        className="group flex h-full w-full flex-col rounded-xl border border-gray-200 bg-white p-4 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md sm:p-5"
                      >
                        <div className="mb-2 flex items-center gap-2.5">
                          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-castle-blue/10">
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
                              className="lucide lucide-calculator h-4 w-4 text-castle-blue"
                              aria-hidden="true"
                            >
                              <rect width="16" height="20" x="4" y="2" rx="2" />
                              <line x1="8" x2="16" y1="6" y2="6" />
                              <line x1="16" x2="16" y1="14" y2="18" />
                              <path d="M16 10h.01" />
                              <path d="M12 10h.01" />
                              <path d="M8 10h.01" />
                              <path d="M12 14h.01" />
                              <path d="M8 14h.01" />
                              <path d="M12 18h.01" />
                              <path d="M8 18h.01" />
                            </svg>
                          </div>
                          <h3 className="text-base font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors sm:text-lg">
                            Business Finance
                          </h3>
                        </div>
                        <p className="mb-3 hidden flex-grow text-sm leading-relaxed text-[#525866] sm:block">
                          Accounting, taxes, and financial integration
                        </p>
                        <p className="text-sm font-medium text-castle-blue">3 articles</p>
                      </a>
                    </div>

                    {/* Market Insights */}
                    <div className="h-full">
                      <a
                        href="/learn?category=market-insights"
                        className="group flex h-full w-full flex-col rounded-xl border border-gray-200 bg-white p-4 shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md sm:p-5"
                      >
                        <div className="mb-2 flex items-center gap-2.5">
                          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-castle-blue/10">
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
                              className="lucide lucide-trending-up h-4 w-4 text-castle-blue"
                              aria-hidden="true"
                            >
                              <path d="M16 7h6v6" />
                              <path d="m22 7-8.5 8.5-5-5L2 17" />
                            </svg>
                          </div>
                          <h3 className="text-base font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors sm:text-lg">
                            Market Insights
                          </h3>
                        </div>
                        <p className="mb-3 hidden flex-grow text-sm leading-relaxed text-[#525866] sm:block">
                          Trends, analysis, and macro perspectives
                        </p>
                        <p className="text-sm font-medium text-castle-blue">3 articles</p>
                      </a>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </section>
        </div>

        {/* Articles section */}
        <section className="py-12">
          <div className="container mx-auto px-4">
            {/* Filter pills */}
            <div className="flex flex-wrap items-center gap-2 mb-6">
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-castle-blue text-white">
                  All articles
                </button>
              </div>
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-gray-100 text-[#525866] hover:bg-gray-200">
                  Announcements
                </button>
              </div>
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-gray-100 text-[#525866] hover:bg-gray-200">
                  Bitcoin Basics
                </button>
              </div>
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-gray-100 text-[#525866] hover:bg-gray-200">
                  Treasury Mgmt
                </button>
              </div>
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-gray-100 text-[#525866] hover:bg-gray-200">
                  Getting Started
                </button>
              </div>
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-gray-100 text-[#525866] hover:bg-gray-200">
                  Business Finance
                </button>
              </div>
              <div>
                <button className="cursor-pointer px-4 py-2 rounded-full text-sm font-medium transition-colors bg-gray-100 text-[#525866] hover:bg-gray-200">
                  Market Insights
                </button>
              </div>
            </div>

            {/* Popular topics */}
            <div className="mb-8">
              <div className="flex items-center gap-2 mb-3">
                <span className="text-sm font-medium text-[#525866]">Popular topics:</span>
              </div>
              <div className="flex flex-wrap gap-2">
                <div>
                  <a href="/learn?tag=accounting" className="rounded-full font-medium transition-colors px-2 py-0.5 text-xs bg-gray-100 text-[#525866] hover:bg-castle-blue/10 hover:text-castle-blue">
                    accounting
                  </a>
                </div>
                <div>
                  <a href="/learn?tag=adoption" className="rounded-full font-medium transition-colors px-2 py-0.5 text-xs bg-gray-100 text-[#525866] hover:bg-castle-blue/10 hover:text-castle-blue">
                    adoption
                  </a>
                </div>
                <div>
                  <a href="/learn?tag=altcoins" className="rounded-full font-medium transition-colors px-2 py-0.5 text-xs bg-gray-100 text-[#525866] hover:bg-castle-blue/10 hover:text-castle-blue">
                    altcoins
                  </a>
                </div>
                <div>
                  <a href="/learn?tag=announcement" className="rounded-full font-medium transition-colors px-2 py-0.5 text-xs bg-gray-100 text-[#525866] hover:bg-castle-blue/10 hover:text-castle-blue">
                    announcement
                  </a>
                </div>
                <div>
                  <a href="/learn?tag=automation" className="rounded-full font-medium transition-colors px-2 py-0.5 text-xs bg-gray-100 text-[#525866] hover:bg-castle-blue/10 hover:text-castle-blue">
                    automation
                  </a>
                </div>
                <div>
                  <a href="/learn?tag=beginners" className="rounded-full font-medium transition-colors px-2 py-0.5 text-xs bg-gray-100 text-[#525866] hover:bg-castle-blue/10 hover:text-castle-blue">
                    beginners
                  </a>
                </div>
                <div>
                  <a href="/learn?tag=bitcoin" className="rounded-full font-medium transition-colors px-2 py-0.5 text-xs bg-gray-100 text-[#525866] hover:bg-castle-blue/10 hover:text-castle-blue">
                    bitcoin
                  </a>
                </div>
                <div>
                  <a href="/learn?tag=capital-gains" className="rounded-full font-medium transition-colors px-2 py-0.5 text-xs bg-gray-100 text-[#525866] hover:bg-castle-blue/10 hover:text-castle-blue">
                    capital-gains
                  </a>
                </div>
                <div>
                  <a href="/learn?tag=cash+account" className="rounded-full font-medium transition-colors px-2 py-0.5 text-xs bg-gray-100 text-[#525866] hover:bg-castle-blue/10 hover:text-castle-blue">
                    cash account
                  </a>
                </div>
                <div>
                  <a href="/learn?tag=cash-management" className="rounded-full font-medium transition-colors px-2 py-0.5 text-xs bg-gray-100 text-[#525866] hover:bg-castle-blue/10 hover:text-castle-blue">
                    cash-management
                  </a>
                </div>
              </div>
            </div>

            {/* Latest articles heading */}
            <div className="mb-6">
              <h2 className="text-2xl font-bold tracking-tight font-px-grotesk">Latest articles</h2>
            </div>

            {/* Article cards grid */}
            <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">

              {/* Card 1: Announcing New QuidMint Accounts */}
              <div>
                <a
                  href="/learn/announcing-new-castle-accounts-cash-and-high-yield"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="QuidMint Cash and High Yield Accounts"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=New+Accounts"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Announcements
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>April 22, 2026</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>6 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Announcing New QuidMint Accounts: Cash + High Yield
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Introducing Cash and High Yield — two new ways for businesses to put capital to work and earn institutional-grade yields paid in bitcoin.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 2: Bitcoin vs. Other Cryptocurrencies */}
              <div>
                <a
                  href="/learn/bitcoin-vs-other-cryptos"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Bitcoin compared to other cryptocurrencies"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Bitcoin+vs+Crypto"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Bitcoin Basics
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>October 29, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>7 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Bitcoin vs. Other Cryptocurrencies: Why Bitcoin Is Unique
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Understand what sets Bitcoin apart from thousands of other cryptocurrencies and why it&#39;s the preferred choice for corporate treasuries.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 3: Understanding Bitcoin Volatility */}
              <div>
                <a
                  href="/learn/understanding-bitcoin-volatility"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Chart showing Bitcoin price movements"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Bitcoin+Volatility"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Bitcoin Basics
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>October 22, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>6 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Understanding Bitcoin Volatility: A Guide for Business Owners
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Learn how to think about and manage Bitcoin&#39;s price volatility in the context of corporate treasury management.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 4: What Is Bitcoin */}
              <div>
                <a
                  href="/learn/what-is-bitcoin"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Digital representation of Bitcoin with business charts"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Bitcoin+Basics"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Bitcoin Basics
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>October 15, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>8 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      What Is Bitcoin? A Business Owner&#39;s Guide
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Learn the fundamentals of Bitcoin and why it&#39;s becoming the preferred treasury asset for forward-thinking businesses.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 5: Bitcoin Accounting 101 */}
              <div>
                <a
                  href="/learn/bitcoin-accounting-101"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Business accounting for Bitcoin holdings"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Bitcoin+Accounting"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Business Finance
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>October 8, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>8 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Bitcoin Accounting 101: Cost Basis and Reporting
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Understand how to track cost basis, manage your books, and prepare for accurate Bitcoin reporting.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 6: Integrating Bitcoin with QuickBooks */}
              <div>
                <a
                  href="/learn/integrating-bitcoin-with-quickbooks"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Bitcoin integration with accounting software"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=QuickBooks+Integration"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Business Finance
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>October 1, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>6 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Integrating Bitcoin with QuickBooks and Xero
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Learn how to sync your Bitcoin transactions with popular accounting software for seamless bookkeeping.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 7: Tax Considerations */}
              <div>
                <a
                  href="/learn/tax-considerations-for-bitcoin"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Tax considerations for Bitcoin holdings"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Bitcoin+Taxes"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Business Finance
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>September 24, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>9 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Tax Considerations for Bitcoin-Holding Businesses
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Navigate capital gains, reporting requirements, and tax strategies for businesses with Bitcoin on their balance sheet.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 8: Connecting Your First Integration */}
              <div>
                <a
                  href="/learn/connecting-your-first-integration"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Payment integration connections"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Integrations"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Getting Started
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>September 17, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>6 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Connecting Your First Payment Integration
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Learn how to connect Shopify, Stripe, Square, or PayPal to automatically convert revenue into Bitcoin.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 9: Creating Your First Treasury Automation */}
              <div>
                <a
                  href="/learn/creating-your-first-treasury-rule"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Treasury automation rules configuration"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Treasury+Rules"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Getting Started
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>September 10, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>5 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Creating Your First Treasury Automation
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Set up automated treasury rules to maintain your ideal cash-to-Bitcoin ratio without manual intervention.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 10: Setting Up Your QuidMint Account */}
              <div>
                <a
                  href="/learn/setting-up-your-castle-account"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="QuidMint account setup process"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Account+Setup"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Getting Started
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>September 3, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>5 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Setting Up Your QuidMint Account: A Complete Walkthrough
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Step-by-step instructions for creating your QuidMint account, completing verification, and getting ready to buy Bitcoin.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 11: Bitcoin Adoption Trends */}
              <div>
                <a
                  href="/learn/bitcoin-adoption-trends"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Bitcoin adoption trends chart"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Adoption+Trends"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Market Insights
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>August 27, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>7 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Bitcoin Adoption Trends: Why More SMBs Are Holding Bitcoin
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Explore the growing trend of small and medium businesses adding Bitcoin to their treasuries and what&#39;s driving this shift.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 12: Inflation Hedging */}
              <div>
                <a
                  href="/learn/inflation-hedging-with-bitcoin"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Bitcoin as inflation protection"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Inflation+Hedge"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Market Insights
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>August 20, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>8 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Inflation Hedging: How Bitcoin Protects Your Business Savings
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Understand the macroeconomic case for Bitcoin as an inflation hedge and how it can protect your business&#39;s purchasing power.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 13: The Institutional Bitcoin Playbook */}
              <div>
                <a
                  href="/learn/institutional-bitcoin-playbook"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Institutional Bitcoin strategy"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Institutional+Playbook"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Market Insights
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>August 13, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>8 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      The Institutional Bitcoin Playbook: Lessons from Strategy and Tesla
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Learn from the strategies of major corporate Bitcoin adopters and how to apply their lessons to your business.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 14: Building a Bitcoin Reserve */}
              <div>
                <a
                  href="/learn/building-a-bitcoin-reserve"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Business building Bitcoin reserves"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Bitcoin+Reserve"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Treasury Mgmt
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>August 6, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>9 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Building a Bitcoin Reserve: A Step-by-Step Strategy
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      A comprehensive guide to position sizing, timing, and building your business&#39;s Bitcoin treasury from the ground up.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 15: Dollar-Cost Averaging */}
              <div>
                <a
                  href="/learn/dollar-cost-averaging-explained"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Dollar cost averaging chart illustration"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=DCA+Strategy"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Treasury Mgmt
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>July 30, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>6 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      Dollar-Cost Averaging Explained: The Smart Way to Buy Bitcoin
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Learn how dollar-cost averaging helps reduce timing risk and build your Bitcoin position methodically over time.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
                  </div>
                </a>
              </div>

              {/* Card 16: When to Hold vs. Spend */}
              <div>
                <a
                  href="/learn/when-to-hold-vs-spend-bitcoin"
                  className="group flex flex-col rounded-xl border border-gray-200 bg-white overflow-hidden shadow-sm transition-all hover:border-castle-blue/30 hover:shadow-md"
                >
                  <div className="relative aspect-[16/9] w-full overflow-hidden bg-gray-100">
                    <img
                      alt="Decision framework for Bitcoin treasury"
                      className="h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
                      src="https://placehold.co/800x450/1e60d0/ffffff?text=Hold+vs+Spend"
                    />
                    <span className="absolute top-3 left-3 inline-flex items-center rounded-full bg-white/90 backdrop-blur-sm px-3 py-1 text-xs font-medium text-castle-blue shadow-sm">
                      Treasury Mgmt
                    </span>
                  </div>
                  <div className="flex flex-col flex-grow p-5">
                    <div className="flex items-center gap-3 mb-3 text-xs text-[#525866]">
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-calendar h-3 w-3" aria-hidden="true">
                          <path d="M8 2v4" />
                          <path d="M16 2v4" />
                          <rect width="18" height="18" x="3" y="4" rx="2" />
                          <path d="M3 10h18" />
                        </svg>
                        <span>July 23, 2025</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-3 w-3" aria-hidden="true">
                          <path d="M12 6v6l4 2" />
                          <circle cx="12" cy="12" r="10" />
                        </svg>
                        <span>7 min read</span>
                      </div>
                    </div>
                    <h3 className="mb-2 text-lg font-semibold text-[#09090b] group-hover:text-castle-blue transition-colors line-clamp-2">
                      When to Hold vs. Spend Your Bitcoin: A Strategic Framework
                    </h3>
                    <p className="text-sm text-[#525866] leading-relaxed flex-grow line-clamp-3">
                      Develop a clear framework for deciding when to hold Bitcoin as a reserve and when to convert it back to cash for business needs.
                    </p>
                    <div className="mt-4 flex items-center text-sm font-medium text-castle-blue">
                      <span>Read article</span>
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-right h-4 w-4 ml-1 transition-transform group-hover:translate-x-1" aria-hidden="true">
                        <path d="m9 18 6-6-6-6" />
                      </svg>
                    </div>
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
