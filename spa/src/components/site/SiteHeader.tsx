import Link from 'next/link'
import Wordmark from './Wordmark'

export default function SiteHeader() {
  return (
    <header className="sticky top-0 z-50 border-b border-black/5 bg-white/80 backdrop-blur">
      <div className="mx-auto flex h-16 max-w-5xl items-center justify-between px-5">
        <Link href="/" aria-label="QU!D home" className="text-[#09090b]">
          <Wordmark className="text-[19px]" />
        </Link>
        <nav className="flex items-center gap-6 text-[14px]">
          <a
            href="https://github.com/quidmints/SPV/blob/main/spec.md"
            className="hidden text-[#525866] transition-colors hover:text-[#09090b] sm:inline"
          >
            Specification
          </a>
          <Link
            href="/app"
            className="rounded-[10px] bg-[#09090b] px-[14px] py-[9px] font-medium text-white transition-opacity hover:opacity-85"
          >
            Open app
          </Link>
        </nav>
      </div>
    </header>
  )
}
