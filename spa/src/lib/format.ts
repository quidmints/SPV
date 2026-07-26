// Shared display formatters for the dashboard components.
// Extracted so the (previously copy-pasted, byte-identical) helpers live once.

/// Whole-dollar, absolute-value, thousands-separated: `$1,234`.
export const f0 = (v: number) => `$${Math.round(Math.abs(v)).toLocaleString('en-US')}`
