export const ACCESS_POLICY = {
  version: 1,
  trialAllowanceMs: 30 * 60 * 1_000,
  demoAllowanceMs: 15 * 1_000,
  paidAllowanceMs: null as number | null,
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
