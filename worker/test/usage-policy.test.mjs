import test from "node:test";
import assert from "node:assert/strict";
import { ACCESS_POLICY, canReserveUsage, chargeableUsage, remainingUsage, usageAllowance } from "../src/usage-policy.ts";

test("trial allowance is 30 minutes and includes outstanding reservations", () => {
  assert.equal(ACCESS_POLICY.trialAllowanceMs, 1_800_000);
  assert.equal(usageAllowance("trial"), 1_800_000);
  assert.equal(canReserveUsage("trial", 1_700_000, 100_000, 0), true);
  assert.equal(canReserveUsage("trial", 1_700_000, 100_000, 1), false);
  assert.equal(remainingUsage("trial", 1_700_000, 100_000), 0);
});

test("paid access remains unlimited above the future cap's trial-sized threshold", () => {
  assert.equal(ACCESS_POLICY.paidAllowanceMs, null);
  assert.equal(usageAllowance("paid"), null);
  assert.equal(canReserveUsage("paid", 1_800_000, 50_000, 86_400_000), true);
  assert.equal(remainingUsage("paid", 86_400_000, 10_000), null);
});

test("onboarding demo keeps its separate 15-second allowance", () => {
  assert.equal(usageAllowance("demo"), 15_000);
  assert.equal(canReserveUsage("demo", 10_000, 5_000, 0), true);
  assert.equal(canReserveUsage("demo", 10_000, 5_000, 1), false);
});

test("the trial's last segment may overrun slightly and is charged only what was left", () => {
  // 5 seconds left, a 20-second segment arrives: accept it and land exactly on 30 minutes.
  assert.equal(chargeableUsage("trial", 1_795_000, 0, 20_000), 5_000);
  assert.equal(remainingUsage("trial", 1_795_000 + 5_000, 0), 0);
  // Reservations still in flight count as used.
  assert.equal(chargeableUsage("trial", 1_790_000, 5_000, 20_000), 5_000);
});

test("the trial grace never covers a long request or an exhausted trial", () => {
  assert.equal(chargeableUsage("trial", 1_795_000, 0, 5_000 + ACCESS_POLICY.trialFinalRequestGraceMs + 1), null);
  assert.equal(chargeableUsage("trial", 1_800_000, 0, 1), null);
  assert.equal(chargeableUsage("trial", 1_000_000, 0, 600_000), 600_000);
});

test("demo and paid tiers have no grace", () => {
  assert.equal(chargeableUsage("demo", 10_000, 0, 6_000), null);
  assert.equal(chargeableUsage("demo", 10_000, 0, 5_000), 5_000);
  assert.equal(chargeableUsage("paid", 86_400_000, 0, 86_400_000), 86_400_000);
});
