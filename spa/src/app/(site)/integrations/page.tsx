import Link from 'next/link'
import SiteHeader from '@/components/castle/SiteHeader'
import SiteFooter from '@/components/castle/SiteFooter'

export const metadata = { title: 'Integrations | QuidMint' }

export default function Page() {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />
      <main className="flex-1">
        {/* Hero */}
        <div className="px-2 sm:px-3 pt-2 sm:pt-3 pb-4 sm:pb-6 bg-white">
          <section
            data-track-location="hero"
            className="relative overflow-hidden rounded-[20px] pt-[140px]"
            style={{
              border: '1px solid rgba(9, 9, 11, 0.12)',
              boxShadow:
                'rgba(2, 8, 20, 0.1) 0px 16px 32px -14px, rgba(2, 8, 20, 0.06) 0px 6px 14px -6px, rgba(2, 8, 20, 0.04) 0px 1px 2px',
              paddingBottom: '180px',
            }}
          >
            {/* Background gradient */}
            <div
              className="absolute inset-0 pointer-events-none"
              style={{
                background:
                  'linear-gradient(rgb(255, 255, 255) 0%, rgb(244, 247, 252) 22%, rgba(37, 99, 235, 0.28) 50%, rgb(244, 247, 252) 78%, rgb(255, 255, 255) 100%)',
              }}
            />
            {/* Grid pattern */}
            <div
              className="absolute inset-0 pointer-events-none"
              style={{
                maskImage:
                  'linear-gradient(rgb(0, 0, 0) 0%, rgba(0, 0, 0, 0.92) 18%, rgba(0, 0, 0, 0.4) 42%, rgba(0, 0, 0, 0.06) 56%, transparent 66%, transparent 100%)',
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
                      'url("data:image/svg+xml;utf8,%0A%20%20%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20width%3D%2240%22%20height%3D%2240%22%20viewBox%3D%220%200%2040%2040%22%20fill%3D%22none%22%3E%0A%20%20%20%20%3Cpath%20d%3D%22M20%2014V26M14%2020H26%22%20stroke%3D%22%23E5E7EB%22%20stroke-width%3D%222%22%20stroke-linecap%3D%22round%22%20%2F%3E%0A%20%20%3C%2Fsvg%3E%0A")',
                    backgroundSize: '40px 40px',
                    opacity: 1,
                  }}
                />
              </div>
            </div>

            {/* Heading */}
            <div className="container relative mx-auto px-4 sm:px-8">
              <div className="mx-auto max-w-4xl text-center">
                <h1 className="mb-3 text-[36px] md:text-[56px] lg:text-[64px] font-normal tracking-[-0.05em] leading-[1] text-[#09090b] font-px-grotesk mx-auto md:max-w-[22ch]">
                  Keep everything in sync with our integrations
                </h1>
                <p className="whitespace-pre-wrap mb-8 text-[18px] md:text-[20px] text-[#525866] leading-[1.4] max-w-2xl mx-auto font-normal">
                  Connect your payment processors and automatically convert a percentage of every transaction into bitcoin.
                </p>
                <div className="flex flex-row items-center justify-center gap-3">
                  <Link
                    href="/app"
                    className="inline-flex items-center justify-center rounded-[10px] border border-white/15 bg-[#17181d] px-[14px] py-[10px] text-[14px] font-semibold text-white [text-shadow:0_1px_0_rgba(255,255,255,0.18),0_2px_4px_rgba(0,0,0,0.45)] shadow-[0_2px_0_rgba(10,10,12,0.95),0_8px_20px_rgba(9,9,11,0.28),inset_0_1px_0_rgba(255,255,255,0.14)] transition-[box-shadow,color] duration-200 hover:text-white/80 hover:shadow-[0_2px_0_rgba(10,10,12,0.95),0_12px_24px_rgba(9,9,11,0.34),inset_0_1px_0_rgba(255,255,255,0.2)] active:text-white active:shadow-[0_2px_0_rgba(10,10,12,0.95),0_8px_16px_rgba(9,9,11,0.26),inset_0_1px_0_rgba(255,255,255,0.12)]"
                  >
                    Get Started
                  </Link>
                </div>
              </div>
            </div>

            {/* Hero integration icons — mobile */}
            <div className="absolute inset-0 pointer-events-none overflow-hidden">
              <div
                className="absolute left-1/2 bottom-12 block md:hidden"
                style={{ width: '940px', height: '248px', transform: 'translateX(-50%) scale(0.62)', transformOrigin: 'center bottom' }}
              >
                <div className="absolute" style={{ left: '216px', top: '76px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="Gumroad" className="object-contain" src="/castle/images/integrations/icons/gumroad-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '324px', top: '128px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="eBay" className="object-contain" src="/castle/images/integrations/icons/ebay-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '432px', top: '172px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(99, 91, 255)' }}>
                    <img alt="Stripe" className="object-contain" src="/castle/images/integrations/icons/stripe-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '540px', top: '128px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="PayPal" className="object-contain" src="/castle/images/integrations/icons/paypal-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '648px', top: '76px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="Shopify" className="object-contain" src="/castle/images/integrations/icons/shopify-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
              </div>

              {/* Hero integration icons — desktop */}
              <div
                className="absolute left-1/2 bottom-4 hidden md:block"
                style={{ width: '940px', height: '248px', transform: 'translateX(-50%)' }}
              >
                <div className="absolute" style={{ left: '0px', top: '0px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="QuickBooks" className="object-contain" src="/castle/images/integrations/icons/quickbooks-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '108px', top: '60px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="Xero" className="object-contain" src="/castle/images/integrations/icons/xero-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '216px', top: '108px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="Gumroad" className="object-contain" src="/castle/images/integrations/icons/gumroad-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '324px', top: '144px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="eBay" className="object-contain" src="/castle/images/integrations/icons/ebay-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '432px', top: '172px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(99, 91, 255)' }}>
                    <img alt="Stripe" className="object-contain" src="/castle/images/integrations/icons/stripe-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '540px', top: '144px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="PayPal" className="object-contain" src="/castle/images/integrations/icons/paypal-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '648px', top: '108px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="Shopify" className="object-contain" src="/castle/images/integrations/icons/shopify-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '756px', top: '60px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="Mindbody" className="object-contain" src="/castle/images/integrations/icons/mindbody-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
                <div className="absolute" style={{ left: '864px', top: '0px', width: '76px', height: '76px' }}>
                  <div className="w-full h-full rounded-xl shadow-md flex items-center justify-center" style={{ backgroundColor: 'rgb(255, 255, 255)' }}>
                    <img alt="Clover" className="object-contain" src="/castle/images/integrations/icons/clover-icon.svg" style={{ width: '48px', height: '48px' }} />
                  </div>
                </div>
              </div>
            </div>
          </section>
        </div>

        {/* Search section */}
        <section className="pt-32 pb-8">
          <div className="container mx-auto px-4">
            <div className="mx-auto mb-6 max-w-4xl text-center">
              <h2 className="whitespace-pre-wrap mb-2 text-[36px] md:text-[44px] leading-[1.1] font-normal tracking-[-0.03em] font-px-grotesk">
                Find the Integration You Need
              </h2>
              <p className="whitespace-pre-wrap text-[20px] text-[#09090b] lg:whitespace-nowrap">
                Search by name or category to discover tools that work seamlessly with our platform.
              </p>
            </div>
            <div className="mx-auto max-w-[600px]">
              <div className="relative w-full mx-auto max-w-none">
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
                  className="lucide lucide-search absolute left-5 top-1/2 h-5 w-5 -translate-y-1/2 text-black/45"
                  aria-hidden="true"
                >
                  <path d="m21 21-4.34-4.34" />
                  <circle cx="11" cy="11" r="8" />
                </svg>
                <input
                  className="file:text-foreground placeholder:text-muted-foreground selection:bg-primary selection:text-primary-foreground flex w-full min-w-0 border px-3 py-1 transition-[color,box-shadow] outline-none file:inline-flex file:h-7 file:border-0 file:bg-transparent file:text-sm file:font-medium disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50 md:text-sm focus-visible:ring-[3px] h-16 pl-14 pr-4 text-lg placeholder:text-lg rounded-xl border-gray-200 bg-white shadow-sm focus-visible:ring-castle-blue/50 focus-visible:border-castle-blue"
                  placeholder="Search integrations..."
                  type="search"
                  defaultValue=""
                />
              </div>
            </div>
          </div>
        </section>

        {/* Payment Providers */}
        <section className="py-12">
          <div className="container mx-auto px-4">
            <div className="mb-8">
              <h2 className="whitespace-pre-wrap text-2xl font-normal tracking-tight font-px-grotesk">
                Payment Providers
              </h2>
            </div>
            <div className="grid grid-cols-2 gap-2 md:flex md:flex-wrap md:gap-1">
              {/* Shopify */}
              <div className="w-full md:w-[260px]">
                <div className="group relative h-[172px] w-full overflow-hidden rounded-[16px] bg-[#f5f5f5] shadow-[0_1px_2px_rgba(0,0,0,0.04)] md:w-[260px]">
                  <div className="px-4 pt-5 pb-2 text-center">
                    <span className="text-[#09090b] text-[18px] font-bold font-px-grotesk">Shopify</span>
                  </div>
                  <div className="px-4 pb-5 flex items-center justify-center">
                    <div className="relative inline-flex">
                      <div className="pointer-events-none absolute left-1/2 top-[88px] h-[12px] w-[62px] -translate-x-1/2 rounded-full bg-black/45 blur-[8px] opacity-60" />
                      <div className="relative z-10 w-[80px] h-[80px] rounded-[14px] bg-white flex items-center justify-center shadow-[0_2px_6px_rgba(0,0,0,0.08)]">
                        <img alt="Shopify" className="h-[52px] w-[52px] object-contain" src="/castle/images/integrations/icons/shopify-icon.svg" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
              {/* Stripe */}
              <div className="w-full md:w-[260px]">
                <div className="group relative h-[172px] w-full overflow-hidden rounded-[16px] bg-[#f5f5f5] shadow-[0_1px_2px_rgba(0,0,0,0.04)] md:w-[260px]">
                  <div className="px-4 pt-5 pb-2 text-center">
                    <span className="text-[#09090b] text-[18px] font-bold font-px-grotesk">Stripe</span>
                  </div>
                  <div className="px-4 pb-5 flex items-center justify-center">
                    <div className="relative inline-flex">
                      <div className="pointer-events-none absolute left-1/2 top-[88px] h-[12px] w-[62px] -translate-x-1/2 rounded-full bg-black/45 blur-[8px] opacity-60" />
                      <div
                        className="relative z-10 w-[80px] h-[80px] p-1 rounded-[14px] flex items-center justify-center shadow-[0_2px_6px_rgba(0,0,0,0.08)]"
                        style={{ backgroundColor: 'rgb(99, 91, 255)' }}
                      >
                        <img alt="Stripe" className="h-[50px] w-[50px] object-contain" src="/castle/images/integrations/icons/stripe-icon.svg" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
              {/* Square */}
              <div className="w-full md:w-[260px]">
                <div className="group relative h-[172px] w-full overflow-hidden rounded-[16px] bg-[#f5f5f5] shadow-[0_1px_2px_rgba(0,0,0,0.04)] md:w-[260px]">
                  <div className="px-4 pt-5 pb-2 text-center">
                    <span className="text-[#09090b] text-[18px] font-bold font-px-grotesk">Square</span>
                  </div>
                  <div className="px-4 pb-5 flex items-center justify-center">
                    <div className="relative inline-flex">
                      <div className="pointer-events-none absolute left-1/2 top-[88px] h-[12px] w-[62px] -translate-x-1/2 rounded-full bg-black/45 blur-[8px] opacity-60" />
                      <div className="relative z-10 w-[80px] h-[80px] rounded-[14px] bg-white flex items-center justify-center shadow-[0_2px_6px_rgba(0,0,0,0.08)]">
                        <img alt="Square" className="h-[52px] w-[52px] object-contain" src="/castle/images/integrations/icons/square-icon.svg" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
              {/* PayPal */}
              <div className="w-full md:w-[260px]">
                <div className="group relative h-[172px] w-full overflow-hidden rounded-[16px] bg-[#f5f5f5] shadow-[0_1px_2px_rgba(0,0,0,0.04)] md:w-[260px]">
                  <div className="px-4 pt-5 pb-2 text-center">
                    <span className="text-[#09090b] text-[18px] font-bold font-px-grotesk">PayPal</span>
                  </div>
                  <div className="px-4 pb-5 flex items-center justify-center">
                    <div className="relative inline-flex">
                      <div className="pointer-events-none absolute left-1/2 top-[88px] h-[12px] w-[62px] -translate-x-1/2 rounded-full bg-black/45 blur-[8px] opacity-60" />
                      <div className="relative z-10 w-[80px] h-[80px] rounded-[14px] bg-white flex items-center justify-center shadow-[0_2px_6px_rgba(0,0,0,0.08)]">
                        <img alt="PayPal" className="h-[52px] w-[52px] object-contain" src="/castle/images/integrations/icons/paypal-icon.svg" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
              {/* Mindbody */}
              <div className="w-full md:w-[260px]">
                <div className="group relative h-[172px] w-full overflow-hidden rounded-[16px] bg-[#f5f5f5] shadow-[0_1px_2px_rgba(0,0,0,0.04)] md:w-[260px]">
                  <div className="px-4 pt-5 pb-2 text-center">
                    <span className="text-[#09090b] text-[18px] font-bold font-px-grotesk">Mindbody</span>
                  </div>
                  <div className="px-4 pb-5 flex items-center justify-center">
                    <div className="relative inline-flex">
                      <div className="pointer-events-none absolute left-1/2 top-[88px] h-[12px] w-[62px] -translate-x-1/2 rounded-full bg-black/45 blur-[8px] opacity-60" />
                      <div className="relative z-10 w-[80px] h-[80px] rounded-[14px] bg-white flex items-center justify-center shadow-[0_2px_6px_rgba(0,0,0,0.08)]">
                        <img alt="Mindbody" className="h-[52px] w-[52px] object-contain" src="/castle/images/integrations/icons/mindbody-icon.svg" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
              {/* Clover */}
              <div className="w-full md:w-[260px]">
                <div className="group relative h-[172px] w-full overflow-hidden rounded-[16px] bg-[#f5f5f5] shadow-[0_1px_2px_rgba(0,0,0,0.04)] md:w-[260px]">
                  <div className="px-4 pt-5 pb-2 text-center">
                    <span className="text-[#09090b] text-[18px] font-bold font-px-grotesk">Clover</span>
                  </div>
                  <div className="px-4 pb-5 flex items-center justify-center">
                    <div className="relative inline-flex">
                      <div className="pointer-events-none absolute left-1/2 top-[88px] h-[12px] w-[62px] -translate-x-1/2 rounded-full bg-black/45 blur-[8px] opacity-60" />
                      <div className="relative z-10 w-[80px] h-[80px] rounded-[14px] bg-white flex items-center justify-center shadow-[0_2px_6px_rgba(0,0,0,0.08)]">
                        <img alt="Clover" className="h-[52px] w-[52px] object-contain" src="/castle/images/integrations/icons/clover-icon.svg" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
              {/* eBay */}
              <div className="w-full md:w-[260px]">
                <div className="group relative h-[172px] w-full overflow-hidden rounded-[16px] bg-[#f5f5f5] shadow-[0_1px_2px_rgba(0,0,0,0.04)] md:w-[260px]">
                  <div className="px-4 pt-5 pb-2 text-center">
                    <span className="text-[#09090b] text-[18px] font-bold font-px-grotesk">eBay</span>
                  </div>
                  <div className="px-4 pb-5 flex items-center justify-center">
                    <div className="relative inline-flex">
                      <div className="pointer-events-none absolute left-1/2 top-[88px] h-[12px] w-[62px] -translate-x-1/2 rounded-full bg-black/45 blur-[8px] opacity-60" />
                      <div className="relative z-10 w-[80px] h-[80px] rounded-[14px] bg-white flex items-center justify-center shadow-[0_2px_6px_rgba(0,0,0,0.08)]">
                        <img alt="eBay" className="h-[52px] w-[52px] object-contain" src="/castle/images/integrations/icons/ebay-icon.svg" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
              {/* Gumroad */}
              <div className="w-full md:w-[260px]">
                <div className="group relative h-[172px] w-full overflow-hidden rounded-[16px] bg-[#f5f5f5] shadow-[0_1px_2px_rgba(0,0,0,0.04)] md:w-[260px]">
                  <div className="px-4 pt-5 pb-2 text-center">
                    <span className="text-[#09090b] text-[18px] font-bold font-px-grotesk">Gumroad</span>
                  </div>
                  <div className="px-4 pb-5 flex items-center justify-center">
                    <div className="relative inline-flex">
                      <div className="pointer-events-none absolute left-1/2 top-[88px] h-[12px] w-[62px] -translate-x-1/2 rounded-full bg-black/45 blur-[8px] opacity-60" />
                      <div
                        className="relative z-10 w-[80px] h-[80px] p-1 rounded-[14px] flex items-center justify-center shadow-[0_2px_6px_rgba(0,0,0,0.08)]"
                        style={{ backgroundColor: 'rgb(255, 144, 232)' }}
                      >
                        <img alt="Gumroad" className="h-[44px] w-[44px] object-contain" src="/castle/images/integrations/icons/gumroad-icon.svg" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
              {/* Zaprite */}
              <div className="w-full md:w-[260px]">
                <div className="group relative h-[172px] w-full overflow-hidden rounded-[16px] bg-[#f5f5f5] shadow-[0_1px_2px_rgba(0,0,0,0.04)] md:w-[260px]">
                  <div className="px-4 pt-5 pb-2 text-center">
                    <span className="text-[#09090b] text-[18px] font-bold font-px-grotesk">Zaprite</span>
                  </div>
                  <div className="px-4 pb-5 flex items-center justify-center">
                    <div className="relative inline-flex">
                      <div className="pointer-events-none absolute left-1/2 top-[88px] h-[12px] w-[62px] -translate-x-1/2 rounded-full bg-black/45 blur-[8px] opacity-60" />
                      <div
                        className="relative z-10 w-[80px] h-[80px] p-1 rounded-[14px] flex items-center justify-center shadow-[0_2px_6px_rgba(0,0,0,0.08)]"
                        style={{ backgroundColor: 'rgb(34, 201, 151)' }}
                      >
                        <img alt="Zaprite" className="h-[50px] w-[50px] object-contain" src="/castle/images/integrations/icons/zaprite-icon.svg" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        {/* Bookkeeping Software */}
        <section className="py-12">
          <div className="container mx-auto px-4">
            <div className="mb-8">
              <h2 className="whitespace-pre-wrap text-2xl font-normal tracking-tight font-px-grotesk">
                Bookkeeping Software
              </h2>
            </div>
            <div className="grid grid-cols-2 gap-2 md:flex md:flex-wrap md:gap-1">
              {/* QuickBooks */}
              <div className="w-full md:w-[260px]">
                <div className="group relative h-[172px] w-full overflow-hidden rounded-[16px] bg-[#f5f5f5] shadow-[0_1px_2px_rgba(0,0,0,0.04)] md:w-[260px]">
                  <div className="px-4 pt-5 pb-2 text-center">
                    <span className="text-[#09090b] text-[18px] font-bold font-px-grotesk">QuickBooks</span>
                  </div>
                  <div className="px-4 pb-5 flex items-center justify-center">
                    <div className="relative inline-flex">
                      <div className="pointer-events-none absolute left-1/2 top-[88px] h-[12px] w-[62px] -translate-x-1/2 rounded-full bg-black/45 blur-[8px] opacity-60" />
                      <div className="relative z-10 w-[80px] h-[80px] rounded-[14px] bg-white flex items-center justify-center shadow-[0_2px_6px_rgba(0,0,0,0.08)]">
                        <img alt="QuickBooks" className="h-[52px] w-[52px] object-contain" src="/castle/images/integrations/icons/quickbooks-icon.svg" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
              {/* Xero */}
              <div className="w-full md:w-[260px]">
                <div className="group relative h-[172px] w-full overflow-hidden rounded-[16px] bg-[#f5f5f5] shadow-[0_1px_2px_rgba(0,0,0,0.04)] md:w-[260px]">
                  <div className="px-4 pt-5 pb-2 text-center">
                    <span className="text-[#09090b] text-[18px] font-bold font-px-grotesk">Xero</span>
                  </div>
                  <div className="px-4 pb-5 flex items-center justify-center">
                    <div className="relative inline-flex">
                      <div className="pointer-events-none absolute left-1/2 top-[88px] h-[12px] w-[62px] -translate-x-1/2 rounded-full bg-black/45 blur-[8px] opacity-60" />
                      <div className="relative z-10 w-[80px] h-[80px] rounded-[14px] bg-white flex items-center justify-center shadow-[0_2px_6px_rgba(0,0,0,0.08)]">
                        <img alt="Xero" className="h-[52px] w-[52px] object-contain" src="/castle/images/integrations/icons/xero-icon.svg" />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        {/* FAQ */}
        <section className="py-16 md:py-24 bg-white">
          <div className="container mx-auto px-4">
            <div>
              <div className="mb-6">
                <h2 className="text-[36px] md:text-[56px] font-normal tracking-[-0.03em] leading-[1.1] text-[#09090b] font-px-grotesk">
                  Frequently Asked Questions
                </h2>
              </div>
              <div className="w-full">
                {/* FAQ item — Why bitcoin? */}
                <div className="border-b border-gray-300">
                  <div className="border-b last:border-b-0 border-none py-2 cursor-pointer">
                    <h3 className="flex">
                      <button
                        type="button"
                        className="flex flex-1 items-start justify-between gap-4 rounded-md transition-all outline-none cursor-pointer text-left text-[20px] md:text-[24px] font-semibold text-[#09090b] hover:no-underline py-4 tracking-[-0.03em]"
                      >
                        Why bitcoin?
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
                          className="lucide lucide-plus text-muted-foreground pointer-events-none size-5 shrink-0 translate-y-0.5 transition-transform duration-200"
                          aria-hidden="true"
                        >
                          <path d="M5 12h14" />
                          <path d="M12 5v14" />
                        </svg>
                      </button>
                    </h3>
                  </div>
                </div>
                {/* FAQ item — Other cryptocurrencies? */}
                <div className="border-b border-gray-300">
                  <div className="border-b last:border-b-0 border-none py-2 cursor-pointer">
                    <h3 className="flex">
                      <button
                        type="button"
                        className="flex flex-1 items-start justify-between gap-4 rounded-md transition-all outline-none cursor-pointer text-left text-[20px] md:text-[24px] font-semibold text-[#09090b] hover:no-underline py-4 tracking-[-0.03em]"
                      >
                        Will you add support for other cryptocurrencies?
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
                          className="lucide lucide-plus text-muted-foreground pointer-events-none size-5 shrink-0 translate-y-0.5 transition-transform duration-200"
                          aria-hidden="true"
                        >
                          <path d="M5 12h14" />
                          <path d="M12 5v14" />
                        </svg>
                      </button>
                    </h3>
                  </div>
                </div>
                {/* FAQ item — Countries */}
                <div className="border-b border-gray-300">
                  <div className="border-b last:border-b-0 border-none py-2 cursor-pointer">
                    <h3 className="flex">
                      <button
                        type="button"
                        className="flex flex-1 items-start justify-between gap-4 rounded-md transition-all outline-none cursor-pointer text-left text-[20px] md:text-[24px] font-semibold text-[#09090b] hover:no-underline py-4 tracking-[-0.03em]"
                      >
                        What countries are you in?
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
                          className="lucide lucide-plus text-muted-foreground pointer-events-none size-5 shrink-0 translate-y-0.5 transition-transform duration-200"
                          aria-hidden="true"
                        >
                          <path d="M5 12h14" />
                          <path d="M12 5v14" />
                        </svg>
                      </button>
                    </h3>
                  </div>
                </div>
                {/* FAQ item — Fees */}
                <div className="border-b border-gray-300">
                  <div className="border-b last:border-b-0 border-none py-2 cursor-pointer">
                    <h3 className="flex">
                      <button
                        type="button"
                        className="flex flex-1 items-start justify-between gap-4 rounded-md transition-all outline-none cursor-pointer text-left text-[20px] md:text-[24px] font-semibold text-[#09090b] hover:no-underline py-4 tracking-[-0.03em]"
                      >
                        What are the fees like?
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
                          className="lucide lucide-plus text-muted-foreground pointer-events-none size-5 shrink-0 translate-y-0.5 transition-transform duration-200"
                          aria-hidden="true"
                        >
                          <path d="M5 12h14" />
                          <path d="M12 5v14" />
                        </svg>
                      </button>
                    </h3>
                  </div>
                </div>
                {/* FAQ item — More integrations */}
                <div>
                  <div className="border-b last:border-b-0 border-none py-2 cursor-pointer">
                    <h3 className="flex">
                      <button
                        type="button"
                        className="flex flex-1 items-start justify-between gap-4 rounded-md transition-all outline-none cursor-pointer text-left text-[20px] md:text-[24px] font-semibold text-[#09090b] hover:no-underline py-4 tracking-[-0.03em]"
                      >
                        Will you add more integrations over time?
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
                          className="lucide lucide-plus text-muted-foreground pointer-events-none size-5 shrink-0 translate-y-0.5 transition-transform duration-200"
                          aria-hidden="true"
                        >
                          <path d="M5 12h14" />
                          <path d="M12 5v14" />
                        </svg>
                      </button>
                    </h3>
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
