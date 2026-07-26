import Link from 'next/link';
import { SplitText } from '@/components/castle/anim'

export default function Hero() {
  return (
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
        style={{
          background: 'linear-gradient(rgb(255, 255, 255) 29.5%, rgb(30, 96, 208) 100%)',
        }}
      />
      <div
        className="absolute inset-0 pointer-events-none"
        style={{
          maskImage:
            'linear-gradient(transparent 0%, rgba(0, 0, 0, 0.15) 35%, rgb(0, 0, 0) 100%)',
        }}
      >
        <div
          className="pointer-events-none absolute inset-0 h-full w-full overflow-hidden opacity-80"
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
      <div className="container relative mx-auto px-4 sm:px-8">
        <div className="mx-auto max-w-4xl text-center pt-4 md:pt-6">
          <SplitText as="h1" text="Banking that stacks bitcoin, not fees" className="mb-3 text-[36px] md:text-[56px] lg:text-[64px] font-normal tracking-[-0.05em] leading-[1] text-[#09090b] font-px-grotesk mx-auto md:max-w-[20ch]" />
          <p
            className="whitespace-pre-wrap mb-8 text-[18px] md:text-[20px] text-[#525866] leading-[1.4] max-w-2xl mx-auto font-normal md:max-w-[45ch]"
            aria-label="Earn yield today and accumulate bitcoin for tomorrow — the modern way businesses compound their treasury."
          >
            <span className="sr-only">
              Earn yield today and accumulate bitcoin for tomorrow — the modern way businesses
              compound their treasury.
            </span>
            <span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">E</span>
                <span className="inline-block" aria-hidden="true">a</span>
                <span className="inline-block" aria-hidden="true">r</span>
                <span className="inline-block" aria-hidden="true">n</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">y</span>
                <span className="inline-block" aria-hidden="true">i</span>
                <span className="inline-block" aria-hidden="true">e</span>
                <span className="inline-block" aria-hidden="true">l</span>
                <span className="inline-block" aria-hidden="true">d</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">t</span>
                <span className="inline-block" aria-hidden="true">o</span>
                <span className="inline-block" aria-hidden="true">d</span>
                <span className="inline-block" aria-hidden="true">a</span>
                <span className="inline-block" aria-hidden="true">y</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">a</span>
                <span className="inline-block" aria-hidden="true">n</span>
                <span className="inline-block" aria-hidden="true">d</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">a</span>
                <span className="inline-block" aria-hidden="true">c</span>
                <span className="inline-block" aria-hidden="true">c</span>
                <span className="inline-block" aria-hidden="true">u</span>
                <span className="inline-block" aria-hidden="true">m</span>
                <span className="inline-block" aria-hidden="true">u</span>
                <span className="inline-block" aria-hidden="true">l</span>
                <span className="inline-block" aria-hidden="true">a</span>
                <span className="inline-block" aria-hidden="true">t</span>
                <span className="inline-block" aria-hidden="true">e</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">b</span>
                <span className="inline-block" aria-hidden="true">i</span>
                <span className="inline-block" aria-hidden="true">t</span>
                <span className="inline-block" aria-hidden="true">c</span>
                <span className="inline-block" aria-hidden="true">o</span>
                <span className="inline-block" aria-hidden="true">i</span>
                <span className="inline-block" aria-hidden="true">n</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">f</span>
                <span className="inline-block" aria-hidden="true">o</span>
                <span className="inline-block" aria-hidden="true">r</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">t</span>
                <span className="inline-block" aria-hidden="true">o</span>
                <span className="inline-block" aria-hidden="true">m</span>
                <span className="inline-block" aria-hidden="true">o</span>
                <span className="inline-block" aria-hidden="true">r</span>
                <span className="inline-block" aria-hidden="true">r</span>
                <span className="inline-block" aria-hidden="true">o</span>
                <span className="inline-block" aria-hidden="true">w</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">—</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">t</span>
                <span className="inline-block" aria-hidden="true">h</span>
                <span className="inline-block" aria-hidden="true">e</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">m</span>
                <span className="inline-block" aria-hidden="true">o</span>
                <span className="inline-block" aria-hidden="true">d</span>
                <span className="inline-block" aria-hidden="true">e</span>
                <span className="inline-block" aria-hidden="true">r</span>
                <span className="inline-block" aria-hidden="true">n</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">w</span>
                <span className="inline-block" aria-hidden="true">a</span>
                <span className="inline-block" aria-hidden="true">y</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">b</span>
                <span className="inline-block" aria-hidden="true">u</span>
                <span className="inline-block" aria-hidden="true">s</span>
                <span className="inline-block" aria-hidden="true">i</span>
                <span className="inline-block" aria-hidden="true">n</span>
                <span className="inline-block" aria-hidden="true">e</span>
                <span className="inline-block" aria-hidden="true">s</span>
                <span className="inline-block" aria-hidden="true">s</span>
                <span className="inline-block" aria-hidden="true">e</span>
                <span className="inline-block" aria-hidden="true">s</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">c</span>
                <span className="inline-block" aria-hidden="true">o</span>
                <span className="inline-block" aria-hidden="true">m</span>
                <span className="inline-block" aria-hidden="true">p</span>
                <span className="inline-block" aria-hidden="true">o</span>
                <span className="inline-block" aria-hidden="true">u</span>
                <span className="inline-block" aria-hidden="true">n</span>
                <span className="inline-block" aria-hidden="true">d</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">t</span>
                <span className="inline-block" aria-hidden="true">h</span>
                <span className="inline-block" aria-hidden="true">e</span>
                <span className="inline-block" aria-hidden="true">i</span>
                <span className="inline-block" aria-hidden="true">r</span>
                <span className="whitespace-pre" aria-hidden="true"> </span>
              </span>
              <span className="inline-block whitespace-nowrap">
                <span className="inline-block" aria-hidden="true">t</span>
                <span className="inline-block" aria-hidden="true">r</span>
                <span className="inline-block" aria-hidden="true">e</span>
                <span className="inline-block" aria-hidden="true">a</span>
                <span className="inline-block" aria-hidden="true">s</span>
                <span className="inline-block" aria-hidden="true">u</span>
                <span className="inline-block" aria-hidden="true">r</span>
                <span className="inline-block" aria-hidden="true">y</span>
                <span className="inline-block" aria-hidden="true">.</span>
              </span>
            </span>
          </p>
          <div>
            <div className="flex flex-row items-center justify-center gap-3">
              <Link
                href="/app"
                className="inline-flex items-center justify-center rounded-[10px] border border-white/15 bg-[#17181d] px-[14px] py-[10px] text-[14px] font-semibold text-white [text-shadow:0_1px_0_rgba(255,255,255,0.18),0_2px_4px_rgba(0,0,0,0.45)] shadow-[0_2px_0_rgba(10,10,12,0.95),0_8px_20px_rgba(9,9,11,0.28),inset_0_1px_0_rgba(255,255,255,0.14)] transition-[box-shadow,color] duration-200 hover:text-white/80 hover:shadow-[0_2px_0_rgba(10,10,12,0.95),0_12px_24px_rgba(9,9,11,0.34),inset_0_1px_0_rgba(255,255,255,0.2)] active:text-white active:shadow-[0_2px_0_rgba(10,10,12,0.95),0_8px_16px_rgba(9,9,11,0.26),inset_0_1px_0_rgba(255,255,255,0.12)]"
              >
                Get Started
              </Link>
              <a
                href="#strategies"
                data-track-button="true"
                data-track-label="hero_secondary_explore_accounts_"
                className="inline-flex items-center justify-center rounded-[10px] border border-gray-200 bg-white text-[#09090b] hover:bg-gray-50 text-[14px] font-semibold px-[14px] py-[10px] transition-colors"
              >
                Explore Accounts{' '}
              </a>
            </div>
          </div>
        </div>
      </div>
      <div className="relative">
        <div
          className="relative mx-auto mt-16 w-full px-4 md:min-h-[360px]"
          style={{ maxWidth: '1200px' }}
        >
          <Link
            href="/app"
            aria-label="Launch QuidMint demo"
            data-track-button="true"
            data-track-label="hero_launch_demo"
            className="group block rounded-t-[12px] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-4 focus-visible:ring-[#09090b]/40 md:rounded-t-[20px]"
          >
            <div className="relative overflow-hidden rounded-t-[12px] md:rounded-t-[20px] border-solid border-[#09090b] border-t-[7px] border-l-[7px] border-r-[7px] md:border-t-[14px] md:border-l-[14px] md:border-r-[14px] shadow-2xl">
              <img
                alt="QuidMint Dashboard"
                width={1859}
                height={1332}
                draggable={false}
                className="mx-auto block h-auto w-[calc(100%-2px)] select-none md:w-full"
                src="/castle/images/brand/dashboard.png"
              />
              <div className="pointer-events-none absolute inset-0 bg-[#09090b]/0 transition-colors duration-300 group-hover:bg-[#09090b]/15 group-focus-visible:bg-[#09090b]/15" />
              <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
                <div className="relative flex h-16 w-16 items-center justify-center rounded-full border border-white/15 bg-[#09090b]/70 shadow-[0_10px_30px_rgba(0,0,0,0.4)] backdrop-blur-md transition-transform duration-300 group-hover:scale-110 group-focus-visible:scale-110 md:h-20 md:w-20">
                  <span
                    aria-hidden="true"
                    className="absolute inset-0 rounded-full bg-white/0 transition-colors duration-300 group-hover:bg-white/5"
                  />
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    width={24}
                    height={24}
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth={0}
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    className="lucide lucide-play ml-1 h-6 w-6 fill-white text-white md:h-8 md:w-8"
                    aria-hidden="true"
                  >
                    <path d="M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z" />
                  </svg>
                </div>
              </div>
            </div>
          </Link>
          <div className="absolute -inset-4 -z-10 bg-gradient-to-r from-castle-blue/10 via-transparent to-castle-blue/10 blur-3xl opacity-50" />
        </div>
      </div>
    </section>
  );
}
