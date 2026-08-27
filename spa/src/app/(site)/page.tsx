import Link from 'next/link'
import SiteHeader from '@/components/site/SiteHeader'
import SiteFooter from '@/components/site/SiteFooter'

/**
 * The QU!D landing page.
 *
 * This is the whole of the web product. Everything a depositor actually does lives in the mobile
 * app, and the `/app` route is the transitional browser build of it.
 *
 * ⚠️ WHAT THIS REPLACED, so nobody restores it: the previous landing was a clone of another
 * company's marketing site, down to their wordmark, their investors' logos, photographs of two of
 * their named employees, a licensed typeface, and a claim that banking services were provided
 * through partner banks. The sub-pages were the same site with the name find-replaced, which is how
 * a FAQ about connecting a bank account through Plaid ended up describing a protocol that has no
 * bank accounts. All of it is deleted rather than edited.
 */

const PANELS = [
  {
    title: 'It has a maturity date',
    body: `Every unit carries the month it comes due, so the protocol knows its entire forward
      liability at any moment: what it owes in March, what it owes in April, out to the end of the
      year. Reserves are matched against that schedule. Most dollar tokens instead promise to pay
      everyone at once and hope not everyone asks.`,
  },
  {
    title: 'It is backed by breadth',
    body: `Fourteen stablecoins sit across separate lending venues, alongside ether at a staking
      venue and bitcoin in Lightning channels whose owners hold their own keys. A single peg is not
      something anyone can price honestly, so the reserve never takes a concentrated bet on one. If
      a venue stops being able to pay, the protocol values it at what it can actually deliver and
      moves what it can recover into the healthy ones.`,
  },
  {
    title: 'You bring one asset and keep it',
    body: `Providing liquidity normally means selling half of what you hold to fund the other side
      of a trading position. Here the maturity schedule is already a predictable stream of forward
      dollars, and that stream funds the dollar side, so ether comes in on its own and bitcoin comes
      in on its own. You leave in the asset you arrived with, plus what it earned.`,
  },
]

const STEPS = [
  {
    n: '01',
    title: 'Buy at a discount',
    body: `You pay less than face and pick the month you want it back. The forward yield is priced
      into the amount you receive at the moment you mint, so there is nothing to claim later and
      nothing to compound by hand.`,
  },
  {
    n: '02',
    title: 'The reserve works',
    body: `Your dollars earn across the lending venues. The ether earns staking yield. Bitcoin that
      would otherwise sit idle in a Lightning channel keeps routing payments while it backs a
      position, which is the one thing that has always made providing channel liquidity a losing
      proposition.`,
  },
  {
    n: '03',
    title: 'Redeem on the month',
    body: `Matured units redeem against the reserve at net asset value, capped at face. Redemption
      draws from the basket in the proportions it is actually held, so no exit can quietly leave
      everyone else holding a more concentrated reserve than they started with.`,
  },
]

export default function Landing() {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />

      <main className="flex-1">
        {/* ── Hero ───────────────────────────────────────────────────────── */}
        <section className="mx-auto max-w-5xl px-5 pb-20 pt-24 md:pb-28 md:pt-32">
          <h1 className="max-w-[18ch] text-[42px] font-normal leading-[1.03] tracking-[-0.04em] text-[#09090b] md:text-[68px]">
            Money that matures on a date you choose
          </h1>
          <p className="mt-7 max-w-[54ch] text-[18px] leading-[1.55] text-[#525866] md:text-[21px]">
            QU!D is a dollar claim bought at a discount and redeemed at face value in a month you
            pick when you buy it. The reserve behind it earns the whole time you are waiting, and
            what it earns is what makes the discount good.
          </p>
          <div className="mt-10 flex flex-wrap items-center gap-3">
            <Link
              href="/app"
              className="rounded-[10px] bg-[#09090b] px-5 py-3 text-[15px] font-medium text-white transition-opacity hover:opacity-85"
            >
              Open app
            </Link>
            <a
              href="https://github.com/quidmints/SPV/blob/main/spec.md"
              className="rounded-[10px] border border-black/10 px-5 py-3 text-[15px] font-medium text-[#09090b] transition-colors hover:bg-black/[0.03]"
            >
              Read the specification
            </a>
          </div>
        </section>

        {/* ── What it is ─────────────────────────────────────────────────── */}
        <section className="border-t border-black/5 bg-[#fafafa]">
          <div className="mx-auto max-w-5xl px-5 py-20 md:py-24">
            <h2 className="text-[30px] font-normal leading-[1.15] tracking-[-0.03em] text-[#09090b] md:text-[40px]">
              Three things that make it different
            </h2>
            <div className="mt-12 grid gap-10 md:grid-cols-3 md:gap-8">
              {PANELS.map((p) => (
                <div key={p.title}>
                  <h3 className="text-[19px] font-medium leading-[1.3] tracking-[-0.01em] text-[#09090b]">
                    {p.title}
                  </h3>
                  <p className="mt-3 text-[15px] leading-[1.65] text-[#525866]">{p.body}</p>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* ── How it works ───────────────────────────────────────────────── */}
        <section className="border-t border-black/5">
          <div className="mx-auto max-w-5xl px-5 py-20 md:py-24">
            <h2 className="text-[30px] font-normal leading-[1.15] tracking-[-0.03em] text-[#09090b] md:text-[40px]">
              How it works
            </h2>
            <ol className="mt-12 space-y-10">
              {STEPS.map((s) => (
                <li key={s.n} className="flex flex-col gap-3 md:flex-row md:gap-10">
                  <span className="shrink-0 pt-1 font-mono text-[13px] tracking-widest text-[#b4b8bf] md:w-16">
                    {s.n}
                  </span>
                  <div className="max-w-[68ch]">
                    <h3 className="text-[19px] font-medium leading-[1.3] tracking-[-0.01em] text-[#09090b]">
                      {s.title}
                    </h3>
                    <p className="mt-2 text-[15px] leading-[1.65] text-[#525866]">{s.body}</p>
                  </div>
                </li>
              ))}
            </ol>
          </div>
        </section>

        {/* ── What can go wrong. This section is not optional. ────────────── */}
        <section className="border-t border-black/5 bg-[#fafafa]">
          <div className="mx-auto max-w-5xl px-5 py-20 md:py-24">
            <h2 className="text-[30px] font-normal leading-[1.15] tracking-[-0.03em] text-[#09090b] md:text-[40px]">
              What can go wrong
            </h2>
            <p className="mt-7 max-w-[68ch] text-[16px] leading-[1.65] text-[#525866]">
              Redemption is capped at face value and can settle below it, for three reasons the
              protocol names rather than hides. A stablecoin in the basket can break its peg, and
              the shortfall is shared proportionally by everyone holding rather than absorbed by
              whoever exits first. A lending venue can lose money, which the reserve books as soon
              as the venue does. And money can be entirely solvent while being temporarily
              impossible to withdraw, in which case the unserved balance stays a live claim and is
              paid once the venue is liquid again.
            </p>
            <p className="mt-5 max-w-[68ch] text-[16px] leading-[1.65] text-[#525866]">
              That floating downside is deliberate. A claim that promised a fixed sum whatever
              happened would be promising something no reserve can guarantee, and the honest version
              of this instrument is one that returns what the reserve is worth on the day it comes
              due.
            </p>
            <p className="mt-5 max-w-[68ch] text-[16px] leading-[1.65] text-[#525866]">
              Providing liquidity carries its own risk, separate from holding. An in-range position
              sells what is rising and buys what is falling, and the fees it collects roughly cover
              that on average and no more. The optional hedge against it is a view on where price is
              going, so there are regimes where taking it is the wrong call. The specification is
              specific about which ones.
            </p>
          </div>
        </section>

        {/* ── CTA ────────────────────────────────────────────────────────── */}
        <section className="border-t border-black/5">
          <div className="mx-auto max-w-5xl px-5 py-20 text-center md:py-28">
            <h2 className="mx-auto max-w-[20ch] text-[32px] font-normal leading-[1.1] tracking-[-0.035em] text-[#09090b] md:text-[46px]">
              Everything about it is on-chain and readable
            </h2>
            <p className="mx-auto mt-6 max-w-[52ch] text-[17px] leading-[1.55] text-[#525866]">
              There is no committee that can re-weight the reserve, no owner key that can pause a
              withdrawal, and no number in the specification that was not read out of the contracts.
            </p>
            <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
              <Link
                href="/app"
                className="rounded-[10px] bg-[#09090b] px-5 py-3 text-[15px] font-medium text-white transition-opacity hover:opacity-85"
              >
                Open app
              </Link>
              <a
                href="https://github.com/quidmints/SPV"
                className="rounded-[10px] border border-black/10 px-5 py-3 text-[15px] font-medium text-[#09090b] transition-colors hover:bg-black/[0.03]"
              >
                Read the source
              </a>
            </div>
          </div>
        </section>
      </main>

      <SiteFooter />
    </div>
  )
}
