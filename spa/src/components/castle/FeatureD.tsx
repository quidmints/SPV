import Link from 'next/link';
import { SplitText } from '@/components/castle/anim'

export default function FeatureD() {
  return (
    <section className="py-16 md:py-24 bg-white relative overflow-hidden">
      <div className="absolute inset-y-0 right-0 w-1/3 dot-pattern-light opacity-30">
      </div>
      <div className="container mx-auto px-4 relative">
        <div className="text-center mb-16">
          <div>
            <div className="inline-flex items-center gap-2 rounded-full border border-gray-200 bg-white px-3 py-1 text-[14px] font-semibold leading-[20px] text-[#474952] shadow-sm">
              <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-sparkles h-4 w-4" aria-hidden="true">
                <path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z" />
                <path d="M20 2v4" />
                <path d="M22 4h-4" />
                <circle cx="4" cy="20" r="2" />
              </svg>Features
            </div>
          </div>
          <SplitText as="h2" text="Your Business Treasury, Automated" highlight="Automated" className="mt-6 text-[36px] md:text-[48px] font-light tracking-[-0.03em] leading-[1.1] text-[#09090b] font-px-grotesk" />
          <p className="whitespace-pre-wrap mt-3 text-[18px] text-[#525866] leading-[1.5]" aria-label="Focus on your business, let QuidMint manage the treasury">
            <span className="sr-only">Focus on your business, let QuidMint manage the treasury</span>
            <span className="inline-block whitespace-pre" aria-hidden="true">Focus</span>
            <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
            <span className="inline-block whitespace-pre" aria-hidden="true">on</span>
            <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
            <span className="inline-block whitespace-pre" aria-hidden="true">your</span>
            <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
            <span className="inline-block whitespace-pre" aria-hidden="true">business,</span>
            <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
            <span className="inline-block whitespace-pre" aria-hidden="true">let</span>
            <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
            <span className="inline-block whitespace-pre" aria-hidden="true">QuidMint</span>
            <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
            <span className="inline-block whitespace-pre" aria-hidden="true">manage</span>
            <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
            <span className="inline-block whitespace-pre" aria-hidden="true">the</span>
            <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
            <span className="inline-block whitespace-pre" aria-hidden="true">treasury</span>
          </p>
        </div>
        <div className="space-y-24 md:space-y-32">
          {/* Panel 1: Upgrade your balance sheet */}
          <div className="flex flex-col gap-12 lg:flex-row lg:items-center lg:gap-20 ">
            <div className="order-1 flex-1 w-full lg:order-none lg:w-1/2">
              <div className="relative isolate">
                <div className="pointer-events-none absolute z-0 opacity-60 [mask-image:radial-gradient(ellipse_at_center,black_30%,rgba(0,0,0,0.78)_55%,rgba(0,0,0,0.46)_74%,rgba(0,0,0,0.16)_88%,transparent_100%)] -inset-14 bg-[radial-gradient(ellipse_60%_52%_at_22%_74%,rgba(37,99,235,0.13)_0%,rgba(37,99,235,0.07)_36%,rgba(37,99,235,0.03)_55%,rgba(37,99,235,0)_80%),radial-gradient(ellipse_60%_52%_at_80%_28%,rgba(37,99,235,0.13)_0%,rgba(37,99,235,0.07)_36%,rgba(37,99,235,0.03)_55%,rgba(37,99,235,0)_82%)]">
                </div>
                <div className="relative z-10">
                  <div className="relative mx-auto aspect-square w-full max-w-[560px]">
                    <div className="absolute inset-0 overflow-hidden rounded-3xl border border-[#e6e7eb] bg-white shadow-[0_18px_44px_rgba(15,23,42,0.08)]" style={{ backgroundImage: 'radial-gradient(80% 60% at 25% 20%, rgba(37, 99, 235, 0.18) 0%, rgba(37, 99, 235, 0.04) 55%, rgba(255, 255, 255, 0) 100%), radial-gradient(70% 60% at 80% 80%, rgba(37, 99, 235, 0.14) 0%, rgba(37, 99, 235, 0.03) 55%, rgba(255, 255, 255, 0) 100%)' }}>
                      <div className="absolute inset-0 opacity-[0.35]" style={{ backgroundImage: 'radial-gradient(circle, rgba(37, 99, 235, 0.28) 1px, transparent 1px)', backgroundSize: '22px 22px', maskImage: 'radial-gradient(black 35%, transparent 75%)' }}>
                      </div>
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
                                  </svg>+8.2% YTD
                                </span>
                              </div>
                              <div className="mt-2 flex h-1 w-full overflow-hidden rounded-full bg-[#f1f2f5] sm:mt-3 sm:h-1.5">
                                <div style={{ width: '40%', backgroundColor: 'rgb(5, 150, 105)' }}>
                                </div>
                                <div style={{ width: '40%', backgroundColor: 'rgb(37, 99, 235)' }}>
                                </div>
                                <div style={{ width: '20%', backgroundColor: 'rgb(247, 147, 26)' }}>
                                </div>
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
                                  <div className="h-full rounded-full" style={{ width: '40%', backgroundColor: 'rgb(5, 150, 105)' }}>
                                  </div>
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
                                  <div className="h-full rounded-full" style={{ width: '40%', backgroundColor: 'rgb(37, 99, 235)' }}>
                                  </div>
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
                                  <div className="h-full rounded-full" style={{ width: '20%', backgroundColor: 'rgb(247, 147, 26)' }}>
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
            </div>
            <div className="order-2 flex-1 w-full space-y-6 lg:order-none lg:w-1/2">
              <div className="space-y-3">
                <SplitText as="h3" text="Upgrade your balance sheet" className="whitespace-pre-wrap text-[32px] font-light tracking-[-0.02em] leading-[1.2] text-[#09090b] font-px-grotesk max-w-[16ch] md:max-w-none" />
                <p className="whitespace-pre-wrap text-[20px] text-[#09090b] leading-[1.5]" aria-label="Three accounts, one treasury: operating cash at 3.5%, reserves up to 11.5%, and long term holdings in bitcoin — the best performing asset of the decade.">
                  <span className="sr-only">Three accounts, one treasury: operating cash at 3.5%, reserves up to 11.5%, and long term holdings in bitcoin — the best performing asset of the decade.</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">Three</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">accounts,</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">one</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">treasury:</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">operating</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">cash</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">at</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">3.5%,</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">reserves</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">up</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">to</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">11.5%,</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">and</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">long</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">term</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">holdings</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">in</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">bitcoin</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">—</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">the</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">best</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">performing</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">asset</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">of</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">the</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">decade.</span>
                </p>
              </div>
              <div>
                <div className="flex items-stretch gap-2">
                  <div className="w-3 bg-[#09090b] rounded-sm flex-shrink-0 self-stretch">
                  </div>
                  <p className="text-[#09090b] bg-[#f5f5f3] py-3 px-4 rounded-r-lg flex-1 text-[16px]">Designed to grow your treasury without growing your workload. Set thresholds once and let your money go to work.</p>
                </div>
              </div>
              <div className="border-t border-gray-200">
              </div>
              <ul className="flex flex-col gap-3">
                <div>
                  <li className="flex w-fit items-center gap-2 rounded-full border border-zinc-200 bg-zinc-100 p-1.5 pr-2.5 shadow-sm">
                    <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-castle-blue">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check h-3 w-3 text-white" aria-hidden="true">
                        <path d="M20 6 9 17l-5-5" />
                      </svg>
                    </div>
                    <span className="font-medium text-[14px] md:text-[18px] text-[#09090b]">Earn up to 11.5% on every idle dollar</span>
                  </li>
                </div>
                <div>
                  <li className="flex w-fit items-center gap-2 rounded-full border border-zinc-200 bg-zinc-100 p-1.5 pr-2.5 shadow-sm">
                    <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-castle-blue">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check h-3 w-3 text-white" aria-hidden="true">
                        <path d="M20 6 9 17l-5-5" />
                      </svg>
                    </div>
                    <span className="font-medium text-[14px] md:text-[18px] text-[#09090b]">Automatically sweep excess cash into bitcoin</span>
                  </li>
                </div>
                <div>
                  <li className="flex w-fit items-center gap-2 rounded-full border border-zinc-200 bg-zinc-100 p-1.5 pr-2.5 shadow-sm">
                    <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-castle-blue">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check h-3 w-3 text-white" aria-hidden="true">
                        <path d="M20 6 9 17l-5-5" />
                      </svg>
                    </div>
                    <span className="font-medium text-[14px] md:text-[18px] text-[#09090b]">Set limits as a percentage of total holdings</span>
                  </li>
                </div>
              </ul>
            </div>
          </div>
          {/* Panel 3: Purpose built for businesses */}
          <div className="flex flex-col gap-12 lg:flex-row lg:items-center lg:gap-20 ">
            <div className="order-1 flex-1 w-full lg:order-none lg:w-1/2">
              <div className="relative isolate">
                <div className="pointer-events-none absolute z-0 opacity-60 [mask-image:radial-gradient(ellipse_at_center,black_30%,rgba(0,0,0,0.78)_55%,rgba(0,0,0,0.46)_74%,rgba(0,0,0,0.16)_88%,transparent_100%)] -inset-14 bg-[radial-gradient(ellipse_60%_52%_at_24%_30%,rgba(37,99,235,0.14)_0%,rgba(37,99,235,0.08)_36%,rgba(37,99,235,0.03)_55%,rgba(37,99,235,0)_80%),radial-gradient(ellipse_60%_52%_at_78%_72%,rgba(37,99,235,0.13)_0%,rgba(37,99,235,0.07)_36%,rgba(37,99,235,0.03)_55%,rgba(37,99,235,0)_82%)]">
                </div>
                <div className="relative z-10">
                  <div className="relative mx-auto aspect-square w-full max-w-[560px]">
                    <div className="absolute inset-0 overflow-hidden rounded-3xl border border-[#e6e7eb] bg-white shadow-[0_18px_44px_rgba(15,23,42,0.08)]" style={{ backgroundImage: 'radial-gradient(80% 60% at 25% 20%, rgba(37, 99, 235, 0.18) 0%, rgba(37, 99, 235, 0.04) 55%, rgba(255, 255, 255, 0) 100%), radial-gradient(70% 60% at 80% 80%, rgba(37, 99, 235, 0.14) 0%, rgba(37, 99, 235, 0.03) 55%, rgba(255, 255, 255, 0) 100%)' }}>
                      <div className="absolute inset-0 opacity-[0.35]" style={{ backgroundImage: 'radial-gradient(circle, rgba(37, 99, 235, 0.28) 1px, transparent 1px)', backgroundSize: '22px 22px', maskImage: 'radial-gradient(black 35%, transparent 75%)' }}>
                      </div>
                      <div className="absolute inset-0 flex items-center justify-center p-4 sm:p-10 md:p-14">
                        <div className="flex aspect-square w-full max-w-[460px] items-stretch justify-center sm:max-w-[420px]">
                          <div className="flex h-full w-full flex-col rounded-2xl border border-[#e6e7eb] bg-white/90 shadow-[0_12px_28px_rgba(15,23,42,0.10)] backdrop-blur-sm justify-between gap-3 p-3 sm:gap-0 sm:p-5">
                            <div className="flex items-center justify-between">
                              <span className="text-[12px] font-semibold tracking-[-0.01em] text-[#09090b] sm:text-[14px]">Setup complete</span>
                              <span className="inline-flex items-center gap-1 rounded-full border border-emerald-200 bg-emerald-50 px-1.5 py-0.5 text-[9px] font-semibold text-emerald-700 sm:gap-1.5 sm:px-2 sm:text-[10px]">
                                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-clock h-2.5 w-2.5 sm:h-3 sm:w-3" aria-hidden="true">
                                  <path d="M12 6v6l4 2" />
                                  <circle cx="12" cy="12" r="10" />
                                </svg>6 min
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
                                  <div className="text-[9px] leading-tight text-[#6b7280] sm:text-[11px]">10% of sales converted to bitcoin</div>
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
                <SplitText as="h3" text="Purpose built for businesses" className="whitespace-pre-wrap text-[32px] font-light tracking-[-0.02em] leading-[1.2] text-[#09090b] font-px-grotesk max-w-[12ch] md:max-w-none" />
                <p className="whitespace-pre-wrap text-[20px] text-[#09090b] leading-[1.5]" aria-label="Institutional treasury tooling, packaged for how everyday businesses actually run — optimize your cash flows while accessing same-day liquidity.">
                  <span className="sr-only">Institutional treasury tooling, packaged for how everyday businesses actually run — optimize your cash flows while accessing same-day liquidity.</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">Institutional</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">treasury</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">tooling,</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">packaged</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">for</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">how</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">everyday</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">businesses</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">actually</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">run</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">—</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">optimize</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">your</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">cash</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">flows</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">while</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">accessing</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">same-day</span>
                  <span className="inline-block whitespace-pre" aria-hidden="true"> </span>
                  <span className="inline-block whitespace-pre" aria-hidden="true">liquidity.</span>
                </p>
              </div>
              <div>
                <div className="flex items-stretch gap-2">
                  <div className="w-3 bg-[#09090b] rounded-sm flex-shrink-0 self-stretch">
                  </div>
                  <p className="text-[#09090b] bg-[#f5f5f3] py-3 px-4 rounded-r-lg flex-1 text-[16px]">Great for restaurants, e-commerce, real estate, and more - join businesses of all sizes already using QuidMint.</p>
                </div>
              </div>
              <div className="border-t border-gray-200">
              </div>
              <ul className="flex flex-col gap-3">
                <div>
                  <li className="flex w-fit items-center gap-2 rounded-full border border-zinc-200 bg-zinc-100 p-1.5 pr-2.5 shadow-sm">
                    <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-castle-blue">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check h-3 w-3 text-white" aria-hidden="true">
                        <path d="M20 6 9 17l-5-5" />
                      </svg>
                    </div>
                    <span className="font-medium text-[14px] md:text-[18px] text-[#09090b]">Sign up in minutes, zero training required</span>
                  </li>
                </div>
                <div>
                  <li className="flex w-fit items-center gap-2 rounded-full border border-zinc-200 bg-zinc-100 p-1.5 pr-2.5 shadow-sm">
                    <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-castle-blue">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check h-3 w-3 text-white" aria-hidden="true">
                        <path d="M20 6 9 17l-5-5" />
                      </svg>
                    </div>
                    <span className="font-medium text-[14px] md:text-[18px] text-[#09090b]">Operational liquidity the moment you need it</span>
                  </li>
                </div>
                <div>
                  <li className="flex w-fit items-center gap-2 rounded-full border border-zinc-200 bg-zinc-100 p-1.5 pr-2.5 shadow-sm">
                    <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-castle-blue">
                      <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-check h-3 w-3 text-white" aria-hidden="true">
                        <path d="M20 6 9 17l-5-5" />
                      </svg>
                    </div>
                    <span className="font-medium text-[14px] md:text-[18px] text-[#09090b]">Native QuickBooks reporting and exports</span>
                  </li>
                </div>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
