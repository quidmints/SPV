'use client'

// Shared scroll/entry animations for the QuidMint landing, matching the original
// site's feel: per-letter heading reveals (blur + rise + fade), count-up stats,
// and fade-up section reveals. Built on framer-motion. Client-only.

import { motion, useInView, animate } from 'framer-motion'
import { useEffect, useRef, useState } from 'react'

const EASE = [0.22, 1, 0.36, 1] as const

// Fade + rise when scrolled into view (once).
export function Reveal({
  children,
  className,
  y = 24,
  delay = 0,
  duration = 0.6,
}: {
  children: React.ReactNode
  className?: string
  y?: number
  delay?: number
  duration?: number
}) {
  return (
    <motion.div
      className={className}
      initial={{ opacity: 0, y }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: '-80px' }}
      transition={{ duration, delay, ease: EASE }}
    >
      {children}
    </motion.div>
  )
}

// Per-letter heading reveal (blur → sharp, rise, fade in) with staggered delay.
// `text` is a plain string; `highlight` is an optional substring rendered in
// castle-blue (matches the original's colored words). Splits into words so they
// never break mid-letter, then animates each letter.
export function SplitText({
  text,
  highlight,
  className,
  as = 'span',
  stagger = 0.018,
  delay = 0,
}: {
  text: string
  highlight?: string
  className?: string
  as?: 'span' | 'h1' | 'h2' | 'h3'
  stagger?: number
  delay?: number
}) {
  const ref = useRef<HTMLElement>(null)
  const inView = useInView(ref, { once: true, margin: '-60px' })
  const Comp = (motion as any)[as] ?? motion.span

  const hiStart = highlight ? text.indexOf(highlight) : -1
  const hiEnd = hiStart >= 0 ? hiStart + (highlight as string).length : -1

  const words = text.split(' ')
  let letterIdx = 0
  let charPos = 0

  return (
    <Comp ref={ref} className={className} aria-label={text}>
      <span aria-hidden="true">
        {words.map((word, wi) => {
          const letters = word.split('')
          const wordNode = (
            <span key={`w${wi}`} className="inline-block whitespace-nowrap">
              {letters.map((ch, ci) => {
                const isBlue = hiStart >= 0 && charPos >= hiStart && charPos < hiEnd
                charPos++
                const i = letterIdx++
                return (
                  <motion.span
                    key={ci}
                    className={'inline-block' + (isBlue ? ' text-castle-blue' : '')}
                    initial={{ opacity: 0, filter: 'blur(8px)', y: '0.35em' }}
                    animate={inView ? { opacity: 1, filter: 'blur(0px)', y: 0 } : undefined}
                    transition={{ duration: 0.5, delay: delay + i * stagger, ease: EASE }}
                  >
                    {ch}
                  </motion.span>
                )
              })}
            </span>
          )
          charPos++ // account for the space between words
          if (wi === words.length - 1) return wordNode
          return [wordNode, <span key={`s${wi}`} className="whitespace-pre"> </span>]
        })}
      </span>
    </Comp>
  )
}

// Animate a number from 0 → `to` when scrolled into view (once).
export function CountUp({
  to,
  decimals = 0,
  prefix = '',
  suffix = '',
  duration = 1.4,
  className,
}: {
  to: number
  decimals?: number
  prefix?: string
  suffix?: string
  duration?: number
  className?: string
}) {
  const ref = useRef<HTMLSpanElement>(null)
  const inView = useInView(ref, { once: true, margin: '-40px' })
  const [val, setVal] = useState(0)
  useEffect(() => {
    if (!inView) return
    const controls = animate(0, to, {
      duration,
      ease: EASE,
      onUpdate: (v) => setVal(v),
    })
    return () => controls.stop()
  }, [inView, to, duration])
  return (
    <span ref={ref} className={className}>
      {prefix}
      {val.toFixed(decimals)}
      {suffix}
    </span>
  )
}
