'use client'

// ════════════════════════════════════════════════════════════════════════
//   ALLOCATION SLIDER — one reusable "allocate along an axis" control.
//   Used two ways (all the same widget):
//     • risk knob:  safe (QUI) ←→ at work       (how much of my dollars ride)
//     • split knob: ETH ←→ BTC                 (how my at-work dollars divide)
//   Value is 0–100. Plain captions on each end; optional centered value label.
// ════════════════════════════════════════════════════════════════════════

export function AllocationSlider({
  leftLabel, rightLabel, value, onChange,
  valueLabel, accent = 'accent-cyan-400', disabled = false,
}: {
  leftLabel: string
  rightLabel: string
  value: number
  onChange: (v: number) => void
  valueLabel?: string
  accent?: string
  disabled?: boolean
}) {
  return (
    <div>
      {valueLabel != null && (
        <div className="text-center text-xs font-medium mb-1 opacity-90">{valueLabel}</div>
      )}
      <input
        type="range" min={0} max={100} step={1} value={value}
        disabled={disabled}
        onChange={e => onChange(Number(e.target.value))}
        className={`w-full ${accent} disabled:opacity-40`} />
      <div className="flex justify-between text-[10px] mt-0.5">
        <span className="opacity-60">{leftLabel}</span>
        <span className="opacity-60">{rightLabel}</span>
      </div>
    </div>
  )
}
