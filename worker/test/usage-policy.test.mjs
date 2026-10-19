import test from "node:test";
import assert from "node:assert/strict";
import { ACCESS_POLICY, canReserveUsage, remainingUsage, usageAllowance } from "../src/usage-policy.ts";

test("trial allowance is used up exactly and includes outstanding reservations", () => {
  const allowance = ACCESS_POLICY.trialAllowanceMs;
  assert.equal(usageAllowance("trial"), allowance);
  assert.equal(canReserveUsage("trial", allowance - 1_000, 1_000, 0), true);
  assert.equal(canReserveUsage("trial", allowance - 1_000, 1_000, 1), false);
  assert.equal(remainingUsage("trial", allowance - 1_000, 1_000), 0);
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
