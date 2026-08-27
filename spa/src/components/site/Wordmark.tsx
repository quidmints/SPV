/**
 * The QU!D wordmark.
 *
 * Set in type rather than shipped as an asset, so there is nothing to license and nothing to keep
 * in sync. The mobile app renders the same string with the same letter-spacing, which is what makes
 * the two surfaces read as one product.
 */
export default function Wordmark({ className = '' }: { className?: string }) {
  return (
    <span
      aria-label="QU!D"
      className={`select-none font-semibold tracking-[0.18em] ${className}`}
    >
      QU!D
    </span>
  )
}
