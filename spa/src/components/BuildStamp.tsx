import { CONTRACTS } from '@/lib/chains'

// The verifiability seam: NEXT_PUBLIC_COMMIT is inlined at build (next.config.js
// resolves it from `git rev-parse HEAD`), and that same commit carries
// evm/deployments/l1.json — the address record CONTRACTS is built from. A
// visitor reads the SHA here, checks out that commit, and can confirm both the
// JavaScript they're running and every contract address it talks to.
const COMMIT = process.env.NEXT_PUBLIC_COMMIT || 'unknown'

export default function BuildStamp({ className = '' }: { className?: string }) {
  return (
    <span
      className={`font-mono text-[11px] text-white/40 ${className}`}
      title={`build ${COMMIT} — contract addresses are pinned by evm/deployments/l1.json at this commit (basket ${CONTRACTS.basket})`}
      data-commit={COMMIT}
      data-basket={CONTRACTS.basket}
    >
      build {COMMIT === 'unknown' ? COMMIT : COMMIT.slice(0, 12)}
    </span>
  )
}
