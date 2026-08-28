// The wallet's existing look, lifted out of `App.tsx` unchanged so the swap/LP screens can use
// it rather than inventing a second one (owner, 2026-08-16: "use the existing styles that
// identity wallet was using").
//
// 🔑 **PLAIN `StyleSheet.create`, AND THAT IS THE DECISION — no `nativewind`.** The SPA's view
// layer is DOM + tailwind classes, so the open question porting it was whether to bring tailwind
// across via nativewind or restyle. Restyle, on what is already here. That is why these values
// are byte-identical to what `App.tsx` had: this file is an EXTRACTION, not a redesign, and if a
// screen renders differently after it, the extraction is what is wrong.
//
// ⚠️ **DELIBERATELY ONLY WHAT ALREADY EXISTED.** No button / input / tab entries are pre-added
// for the ported screens, because a style with no consumer is dead code that gets copied before
// it gets read. Each screen adds what it needs when it needs it.

import { StyleSheet } from 'react-native'

/// The palette, named separately because the ported screens need the raw values (chart strokes,
/// status dots, a QR code's foreground) where a `StyleSheet` entry does not fit.
export const colors = {
  /// App background.
  bg: '#0f1020',
  /// Raised surface — cards, panels.
  surface: '#1a1b35',
  /// Primary text.
  text: '#fff',
  /// Secondary text.
  textDim: '#8a8ab0',
  /// Section headings.
  textSection: '#cfcff0',
  /// Field labels.
  textLabel: '#9a9ac8',
  /// Monospace / on-chain values. The one accent in the palette.
  accent: '#7ad7a0',
  /// Warning note: background, rule, text.
  warnBg: '#241a08',
  warnRule: '#c9851f',
  warnText: '#e7c98a',
} as const

export const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: colors.bg },
  container: { padding: 20, paddingBottom: 48 },
  h1: { color: colors.text, fontSize: 26, fontWeight: '800' },
  subtle: { color: colors.textDim, fontSize: 12.5, marginTop: 4, lineHeight: 18 },
  section: { color: colors.textSection, fontSize: 15, fontWeight: '700', marginTop: 20, marginBottom: 6 },
  card: { backgroundColor: colors.surface, borderRadius: 12, padding: 14, marginTop: 10 },
  label: { color: colors.textLabel, fontSize: 11, textTransform: 'uppercase', letterSpacing: 0.5 },
  value: { color: colors.text, fontSize: 15, fontWeight: '600', marginTop: 2 },
  mono: { color: colors.accent, fontSize: 12, fontFamily: 'Courier', marginTop: 4 },
  note: { backgroundColor: colors.warnBg, borderLeftColor: colors.warnRule, borderLeftWidth: 3, borderRadius: 8, padding: 12, marginTop: 22 },
  noteText: { color: colors.warnText, fontSize: 12, lineHeight: 18 },
  bold: { fontWeight: '800', color: colors.text },
})
