// Auto-scrolling monochrome logo ticker. The QU!D ecosystem: PayPal (retained)
// + investors, protocols, and stablecoins. CSS `grayscale` renders every logo
// monochrome; hover restores color. Marquee = the set rendered twice so the
// translateX(-50%) keyframe loops seamlessly.
//
// Real marks: paypal, usdt, usdc, dai, rlusd, aave, uniswap. The rest are clean
// monochrome WORDMARK placeholders (swap in real brand SVGs when available):
// morpho, sky, ethena, usdg, ausd, bold, portal-ventures, wintermute,
// rockaway, galaxy, etherfi, triton.
const LOGOS: { src: string; alt: string }[] = [
  { src: '/castle/images/ticker/paypal.svg', alt: 'PayPal' },
  { src: '/castle/images/ticker/portal-ventures.svg', alt: 'Portal Ventures' },
  { src: '/castle/images/ticker/wintermute.svg', alt: 'Wintermute' },
  { src: '/castle/images/ticker/galaxy.svg', alt: 'Galaxy' },
  { src: '/castle/images/ticker/rockaway.svg', alt: 'Rockaway' },
  { src: '/castle/images/ticker/etherfi.webp', alt: 'ether.fi' },
  { src: '/castle/images/ticker/triton.svg', alt: 'Triton Capital' },
  { src: '/castle/images/ticker/morpho.webp', alt: 'Morpho' },
  { src: '/castle/images/ticker/aave.svg', alt: 'Aave' },
  { src: '/castle/images/ticker/uniswap.svg', alt: 'Uniswap' },
  { src: '/castle/images/ticker/sky.svg', alt: 'Sky' },
  { src: '/castle/images/ticker/ethena.webp', alt: 'Ethena' },
  { src: '/castle/images/ticker/usdc.png', alt: 'USDC' },
  { src: '/castle/images/ticker/usdt.svg', alt: 'USDT' },
  { src: '/castle/images/ticker/dai.png', alt: 'DAI' },
  { src: '/castle/images/ticker/rlusd.svg', alt: 'RLUSD' },
  { src: '/castle/images/ticker/usdg.webp', alt: 'USDG' },
  { src: '/castle/images/ticker/ausd.webp', alt: 'AUSD' },
  { src: '/castle/images/ticker/bold.webp', alt: 'BOLD' },
]

export default function LogosStrip() {
  return (
    <section className="pt-8 pb-6 overflow-hidden bg-white">
      <style>{`@keyframes castle-marquee{from{transform:translateX(0)}to{transform:translateX(-50%)}}`}</style>
      <div className="relative overflow-hidden">
        <div className="pointer-events-none absolute inset-y-0 left-0 z-10 w-20 bg-gradient-to-r from-white to-transparent"></div>
        <div className="pointer-events-none absolute inset-y-0 right-0 z-10 w-20 bg-gradient-to-l from-white to-transparent"></div>
        <div
          className="flex w-max items-center gap-16 will-change-transform"
          style={{ animation: 'castle-marquee 48s linear infinite' }}
        >
          {[...LOGOS, ...LOGOS].map((l, i) => (
            <div key={i} aria-hidden={i >= LOGOS.length} className="flex shrink-0 items-center">
              <img
                alt={l.alt}
                src={l.src}
                className="h-[26px] w-auto grayscale opacity-70 transition-all duration-300 hover:opacity-100 hover:grayscale-0 md:h-[32px]"
              />
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
