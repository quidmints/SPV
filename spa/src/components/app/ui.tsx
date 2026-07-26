// Shared presentational atoms for the dashboard tabs.
// Extracted so the (previously copy-pasted, byte-identical) pieces live once.

/// Muted "no data" placeholder, with an optional reason suffix.
export const Empty = ({ note }: { note?: string }) =>
  <p className="text-xs opacity-40">No data{note ? ` — ${note}` : ''}.</p>
