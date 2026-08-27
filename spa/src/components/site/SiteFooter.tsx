import Wordmark from './Wordmark'

export default function SiteFooter() {
  return (
    <footer className="border-t border-black/5 bg-white">
      <div className="mx-auto max-w-5xl px-5 py-12">
        <Wordmark className="text-[17px] text-[#09090b]" />
        <p className="mt-5 max-w-[62ch] text-[13px] leading-[1.7] text-[#8a8f98]">
          QU!D is a protocol, not a bank, and holding it is not a deposit. Nothing here is insured by
          any government. Redemption is capped at face value and can settle below it: a constituent
          stablecoin may break its peg, a lending venue may lose money, and funds that are solvent
          may still be temporarily unavailable to withdraw. Read the specification before you decide
          anything.
        </p>
        <div className="mt-8 flex flex-wrap items-center gap-x-6 gap-y-2 text-[13px]">
          <a
            href="https://github.com/quidmints/SPV/blob/main/spec.md"
            className="text-[#525866] transition-colors hover:text-[#09090b]"
          >
            Specification
          </a>
          <a
            href="https://github.com/quidmints/SPV"
            className="text-[#525866] transition-colors hover:text-[#09090b]"
          >
            Source
          </a>
        </div>
      </div>
    </footer>
  )
}
