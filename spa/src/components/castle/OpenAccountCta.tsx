import Link from 'next/link';
import { SplitText } from '@/components/castle/anim'

export default function OpenAccountCta() {
  return (
    <section data-track-location="open_account_cta" className="relative overflow-hidden rounded-[20px] px-6 py-16 md:py-20 lg:py-24" style={{ border: '1px solid rgba(9, 9, 11, 0.12)', boxShadow: 'rgba(2, 8, 20, 0.1) 0px 16px 32px -14px, rgba(2, 8, 20, 0.06) 0px 6px 14px -6px, rgba(2, 8, 20, 0.04) 0px 1px 2px' }}>
      <div aria-hidden="true" className="pointer-events-none absolute inset-0" style={{ background: 'radial-gradient(55% 110% at 0% 50%, rgba(37, 99, 235, 0.34) 0%, rgba(37, 99, 235, 0) 60%), radial-gradient(55% 110% at 100% 50%, rgba(37, 99, 235, 0.34) 0%, rgba(37, 99, 235, 0) 60%), rgb(255, 255, 255)' }}>
      </div>
      <div aria-hidden="true" className="pointer-events-none absolute inset-0" style={{ maskImage: 'radial-gradient(70% 90%, rgba(0, 0, 0, 0.35) 0%, rgba(0, 0, 0, 0.1) 55%, transparent 80%)' }}>
        <div className="pointer-events-none absolute inset-0 h-full w-full overflow-hidden opacity-60" aria-hidden="true">
          <div className="absolute inset-0 transform-gpu" style={{ backgroundImage: 'url("data:image/svg+xml;utf8,%0A%20%20%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20width%3D%2240%22%20height%3D%2240%22%20viewBox%3D%220%200%2040%2040%22%20fill%3D%22none%22%3E%0A%20%20%20%20%3Cpath%20d%3D%22M20%2014V26M14%2020H26%22%20stroke%3D%22%23E5E7EB%22%20stroke-width%3D%222%22%20stroke-linecap%3D%22round%22%20%2F%3E%0A%20%20%3C%2Fsvg%3E%0A")', backgroundSize: '40px 40px', opacity: 1 }}>
          </div>
        </div>
      </div>
      <div className="container relative mx-auto px-2 sm:px-6">
        <div className="mx-auto max-w-3xl text-center">
          <div>
            <span className="inline-flex items-center gap-2 rounded-full border border-gray-200 bg-white px-3 py-1 text-[12px] font-semibold uppercase tracking-[0.18em] text-[#474952] shadow-sm">
              <span className="h-1.5 w-1.5 rounded-full" style={{ backgroundColor: 'rgb(37, 99, 235)' }}>
              </span>Get Started</span>
          </div>
          <SplitText as="h2" text="Fortify your treasury in under 10 minutes today." highlight="10 minutes" className="mt-6 text-[36px] md:text-[52px] lg:text-[60px] font-normal tracking-[-0.05em] leading-[1.02] text-[#09090b] font-px-grotesk" />
          <div>
            <p className="mt-5 text-[16px] md:text-[18px] text-[#525866] leading-[1.55] max-w-[48ch] mx-auto">Join the businesses earning yield today and stacking bitcoin for tomorrow — all from one platform built for modern treasuries.</p>
          </div>
          <div>
            <form className="mx-auto mt-10 flex max-w-[480px] flex-col gap-2 sm:flex-row sm:items-center sm:rounded-full sm:border sm:border-[#e6e7eb] sm:bg-white sm:p-1.5 sm:pl-5 sm:shadow-[0_4px_14px_-4px_rgba(9,9,11,0.08),0_1px_2px_rgba(9,9,11,0.04)] sm:transition-[border-color,box-shadow] sm:focus-within:border-[#09090b]/40 sm:focus-within:shadow-[0_6px_20px_-6px_rgba(9,9,11,0.14),0_1px_2px_rgba(9,9,11,0.04)]">
              <input required placeholder="What's your email?" aria-label="Email address" className="min-w-0 flex-1 rounded-full border border-[#e6e7eb] bg-white px-5 py-3 text-[15px] text-[#09090b] placeholder:text-[#8f8f95] shadow-[0_4px_14px_-4px_rgba(9,9,11,0.08),0_1px_2px_rgba(9,9,11,0.04)] focus:border-[#09090b]/40 focus:outline-none sm:rounded-none sm:border-0 sm:bg-transparent sm:px-0 sm:py-2 sm:shadow-none sm:focus:border-0" type="email" defaultValue="" />
              <Link href="/app" data-track-button="true" data-track-label="open_account_cta_start_for_free" className="cursor-pointer inline-flex w-full shrink-0 items-center justify-center gap-1.5 rounded-full border border-white/15 bg-[#17181d] px-5 py-3 text-[14px] font-semibold text-white [text-shadow:0_1px_0_rgba(255,255,255,0.18),0_2px_4px_rgba(0,0,0,0.45)] shadow-[0_2px_0_rgba(10,10,12,0.95),0_8px_20px_rgba(9,9,11,0.28),inset_0_1px_0_rgba(255,255,255,0.14)] transition-[box-shadow,color,gap] duration-200 hover:text-white/85 hover:gap-2 hover:shadow-[0_2px_0_rgba(10,10,12,0.95),0_12px_24px_rgba(9,9,11,0.34),inset_0_1px_0_rgba(255,255,255,0.2)] active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-80 sm:w-auto sm:justify-start sm:py-2.5">Start for free<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-arrow-right h-4 w-4" aria-hidden="true">
                <path d="M5 12h14"></path>
                <path d="m12 5 7 7-7 7"></path>
              </svg>
              </Link>
            </form>
          </div>
          <div>
            <div className="mt-6 flex flex-col items-center gap-2 text-[12px] text-[#525866] md:flex-row md:justify-center md:gap-6">
              <span className="inline-flex items-center gap-1.5">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#2563EB" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                  <path d="M5 13l4 4L19 7"></path>
                </svg>Cash operations</span>
              <span className="inline-flex items-center gap-1.5">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#2563EB" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                  <path d="M5 13l4 4L19 7"></path>
                </svg>High Yield reserves</span>
              <span className="inline-flex items-center gap-1.5">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#2563EB" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                  <path d="M5 13l4 4L19 7"></path>
                </svg>Bitcoin growth</span>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
