import Link from 'next/link'
import SiteHeader from '@/components/castle/SiteHeader'
import SiteFooter from '@/components/castle/SiteFooter'

export const metadata = { title: 'About | QuidMint' }

export default function Page() {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />
      <main className="flex-1">
        {/* Hero */}
        <div className="px-2 sm:px-3 pt-2 sm:pt-3 pb-4 sm:pb-6 bg-white">
          <section
            data-track-location="hero"
            className="relative overflow-hidden rounded-[20px] pt-[140px] pb-[64px]"
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
                <h1 className="mb-3 text-[36px] md:text-[56px] lg:text-[64px] font-normal tracking-[-0.05em] leading-[1] text-[#09090b] font-px-grotesk mx-auto md:max-w-[17ch]">
                  On a mission to help businesses{' '}
                  <span className="text-castle-blue">save</span>
                </h1>
                <p className="whitespace-pre-wrap mb-8 text-[18px] md:text-[20px] text-[#525866] leading-[1.4] max-w-2xl mx-auto font-normal">
                  {`We believe fixing the money is of critical importance.\n\nWith sound money like bitcoin we can finally enable hard-working businesses to save again. We're grateful to help build that future.`}
                </p>
              </div>
            </div>
          </section>
        </div>

        {/* Founders */}
        <section className="py-16 md:py-24">
          <div className="container mx-auto px-4">
            <div className="mx-auto max-w-3xl text-center mb-12">
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
                The Founders
              </div>
              <h2 className="mt-6 text-[44px] font-normal tracking-[-0.03em] font-px-grotesk">
                Who We <span className="text-castle-blue">Are</span>
              </h2>
              <p className="whitespace-pre-wrap mt-3 text-[20px] text-[#09090b]">
                Dedicated team, big mission.
              </p>
            </div>

            <div className="mx-auto max-w-3xl grid gap-8 md:grid-cols-2">
              {/* Stephen Cole */}
              <div className="overflow-hidden flex flex-col items-center">
                <div className="h-[300px] w-full max-w-[353px] bg-gradient-to-br from-castle-blue/20 to-castle-blue/5 flex items-center justify-center rounded-2xl overflow-hidden">
                  <img
                    alt="Stephen Cole"
                    className="w-full h-full object-cover rounded-2xl"
                    src="/castle/images/team/stephen-cole.png"
                  />
                </div>
                <div className="w-full max-w-[353px] pt-4 text-left">
                  <h3 className="text-[20px] font-semibold">Stephen Cole</h3>
                  <p className="text-[18px] text-[#525866] font-normal">Co-founder &amp; CEO</p>
                  <div className="mt-4 flex gap-3">
                    <a
                      href="https://x.com/sthenc"
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-gray-400 hover:text-gray-600 transition-colors"
                      aria-label="Stephen Cole on X"
                    >
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
                        className="tabler-icon tabler-icon-brand-x h-7 w-7"
                      >
                        <path d="M4 4l11.733 16h4.267l-11.733 -16l-4.267 0" />
                        <path d="M4 20l6.768 -6.768m2.46 -2.46l6.772 -6.772" />
                      </svg>
                    </a>
                    <a
                      href="https://www.linkedin.com/in/sthenc/"
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-gray-400 hover:text-gray-600 transition-colors"
                      aria-label="Stephen Cole on LinkedIn"
                    >
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
                        className="tabler-icon tabler-icon-brand-linkedin h-7 w-7"
                      >
                        <path d="M8 11v5" />
                        <path d="M8 8v.01" />
                        <path d="M12 16v-5" />
                        <path d="M16 16v-3a2 2 0 1 0 -4 0" />
                        <path d="M3 7a4 4 0 0 1 4 -4h10a4 4 0 0 1 4 4v10a4 4 0 0 1 -4 4h-10a4 4 0 0 1 -4 -4l0 -10" />
                      </svg>
                    </a>
                  </div>
                </div>
              </div>

              {/* João Almeida */}
              <div className="overflow-hidden flex flex-col items-center">
                <div className="h-[300px] w-full max-w-[353px] bg-gradient-to-br from-castle-blue/20 to-castle-blue/5 flex items-center justify-center rounded-2xl overflow-hidden">
                  <img
                    alt="João Almeida"
                    className="w-full h-full object-cover rounded-2xl"
                    src="/castle/images/team/joao-almeida.png"
                  />
                </div>
                <div className="w-full max-w-[353px] pt-4 text-left">
                  <h3 className="text-[20px] font-semibold">João Almeida</h3>
                  <p className="text-[18px] text-[#525866] font-normal">Co-founder &amp; CTO</p>
                  <div className="mt-4 flex gap-3">
                    <a
                      href="https://x.com/joaodealmeida_"
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-gray-400 hover:text-gray-600 transition-colors"
                      aria-label="João Almeida on X"
                    >
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
                        className="tabler-icon tabler-icon-brand-x h-7 w-7"
                      >
                        <path d="M4 4l11.733 16h4.267l-11.733 -16l-4.267 0" />
                        <path d="M4 20l6.768 -6.768m2.46 -2.46l6.772 -6.772" />
                      </svg>
                    </a>
                    <a
                      href="https://www.linkedin.com/in/jo%C3%A3o-almeida-451714a8/"
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-gray-400 hover:text-gray-600 transition-colors"
                      aria-label="João Almeida on LinkedIn"
                    >
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
                        className="tabler-icon tabler-icon-brand-linkedin h-7 w-7"
                      >
                        <path d="M8 11v5" />
                        <path d="M8 8v.01" />
                        <path d="M12 16v-5" />
                        <path d="M16 16v-3a2 2 0 1 0 -4 0" />
                        <path d="M3 7a4 4 0 0 1 4 -4h10a4 4 0 0 1 4 4v10a4 4 0 0 1 -4 4h-10a4 4 0 0 1 -4 -4l0 -10" />
                      </svg>
                    </a>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        {/* Investors */}
        <section className="py-16 md:py-24 bg-[#F7F7F7]">
          <div className="container mx-auto px-4">
            <div className="mx-auto max-w-3xl text-center mb-12">
              <h2 className="text-[32px] md:text-[44px] font-normal tracking-[-0.03em] leading-[1.1] text-[#09090b] font-px-grotesk">
                Our <span className="text-castle-blue">Investors</span>
              </h2>
            </div>
            <div className="mx-auto grid max-w-4xl grid-cols-2 place-items-center gap-6 md:flex md:flex-wrap md:justify-center md:items-center md:gap-10">
              <a
                href="https://www.boost.vc/"
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center justify-center transition-opacity hover:opacity-70"
              >
                <img
                  alt="Boost VC"
                  className="object-contain h-7 w-[132px]"
                  src="/castle/images/investors/boost.png"
                />
              </a>
              <a
                href="https://www.winklevosscapital.com/"
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center justify-center transition-opacity hover:opacity-70"
              >
                <img
                  alt="Winklevoss Capital"
                  className="object-contain h-[110px] w-[150px]"
                  src="/castle/images/investors/winklevoss.png"
                />
              </a>
              <a
                href="https://www.parkrangerscap.com/"
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center justify-center transition-opacity hover:opacity-70"
              >
                <img
                  alt="Park Rangers Capital"
                  className="object-contain h-[110px] w-[100px]"
                  src="/castle/images/investors/park-rangers.png"
                />
              </a>
              <a
                href="https://epochvc.io/"
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center justify-center transition-opacity hover:opacity-70"
              >
                <img
                  alt="Epoch"
                  className="object-contain h-8 w-[137px]"
                  src="/castle/images/investors/epoch.png"
                />
              </a>
            </div>
          </div>
        </section>
      </main>
      <SiteFooter />
    </div>
  )
}
