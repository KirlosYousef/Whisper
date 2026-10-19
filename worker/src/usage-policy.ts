export const ACCESS_POLICY = {
  version: 1,
  trialAllowanceMs: 30 * 1_000, // TEST ONLY: 30-second trial, do not merge
  demoAllowanceMs: 15 * 1_000,
  paidAllowanceMs: null as number | null,
  /**
   * A trial request may run past the allowance by up to this much (one 20-second segment plus margin).
   * Only the remaining allowance is charged, so the trial ends at exactly 0 instead of a few unusable seconds.
   */
  trialFinalRequestGraceMs: 30 * 1_000,
} as const;

export type UsageTier = "trial" | "demo" | "paid";

export function usageAllowance(tier: UsageTier): number | null {
  if (tier === "paid") return ACCESS_POLICY.paidAllowanceMs;
  return tier === "demo" ? ACCESS_POLICY.demoAllowanceMs : ACCESS_POLICY.trialAllowanceMs;
}

export function canReserveUsage(tier: UsageTier, consumedMs: number, reservedMs: number, requestedMs: number): boolean {
  const allowance = usageAllowance(tier);
  return allowance == null || consumedMs + reservedMs + requestedMs <= allowance;
}

export function remainingUsage(tier: UsageTier, consumedMs: number, reservedMs: number): number | null {
  const allowance = usageAllowance(tier);
  return allowance == null ? null : Math.max(0, allowance - consumedMs - reservedMs);
}

/**
 * How much of `requestedMs` to charge, or null when the request must be refused.
 * The trial's last request may overrun by `trialFinalRequestGraceMs`; it is charged only what was left.
 */
export function chargeableUsage(tier: UsageTier, consumedMs: number, reservedMs: number, requestedMs: number): number | null {
  if (canReserveUsage(tier, consumedMs, reservedMs, requestedMs)) return requestedMs;
  const remaining = remainingUsage(tier, consumedMs, reservedMs) ?? 0;
  if (tier === "trial" && remaining > 0 && requestedMs - remaining <= ACCESS_POLICY.trialFinalRequestGraceMs) return remaining;
  return null;
}
