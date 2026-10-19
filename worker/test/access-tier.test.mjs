import assert from "node:assert/strict";
import test from "node:test";
import {
  accessTierForTransaction,
  isUsableTransaction,
  selectAccessTransaction,
  TRIAL_PRODUCT_ID,
  UNLIMITED_PRODUCT_ID,
} from "../src/access-tier.ts";

const NOW = 1_800_000_000_000;
const DAY = 86_400_000;

function transaction(overrides = {}) {
  return {
    originalTransactionId: "1000",
    transactionId: "1001",
    productId: TRIAL_PRODUCT_ID,
    expiresDate: NOW + 3 * DAY,
    revocationDate: null,
    offerType: 1,
    offerDiscountType: "FREE_TRIAL",
    ...overrides,
  };
}

test("the trial product's free introductory offer is the trial tier", () => {
  assert.equal(accessTierForTransaction(transaction()), "trial");
});

test("an introductory offer without offerDiscountType (older payloads) is still the trial tier", () => {
  assert.equal(accessTierForTransaction(transaction({ offerDiscountType: undefined })), "trial");
});

test("the trial product after its 3 days auto-renew is paid", () => {
  const renewed = transaction({ transactionId: "1002", offerType: undefined, offerDiscountType: undefined, expiresDate: NOW + 365 * DAY });
  assert.equal(accessTierForTransaction(renewed), "paid");
});

test("the unlimited product is always paid", () => {
  assert.equal(accessTierForTransaction(transaction({ productId: UNLIMITED_PRODUCT_ID, offerType: undefined, offerDiscountType: undefined })), "paid");
});

test("expired, revoked, upgraded and unknown-product transactions grant nothing", () => {
  assert.equal(isUsableTransaction(transaction(), NOW), true);
  assert.equal(isUsableTransaction(transaction({ expiresDate: NOW - 1 }), NOW), false);
  assert.equal(isUsableTransaction(transaction({ revocationDate: NOW - DAY }), NOW), false);
  assert.equal(isUsableTransaction(transaction({ isUpgraded: true }), NOW), false);
  assert.equal(isUsableTransaction(transaction({ productId: "other.product" }), NOW), false);
  assert.equal(isUsableTransaction(transaction({ originalTransactionId: undefined }), NOW), false);
});

test("upgrading from the trial to unlimited selects the paid transaction on the same ledger", () => {
  const trial = transaction();
  const unlimited = transaction({ transactionId: "2001", productId: UNLIMITED_PRODUCT_ID, offerType: undefined, offerDiscountType: undefined, expiresDate: NOW + 365 * DAY });
  const selection = selectAccessTransaction([trial, unlimited], NOW);
  assert.equal(selection.ok, true);
  assert.equal(selection.tier, "paid");
  assert.equal(selection.transaction.productId, UNLIMITED_PRODUCT_ID);
  assert.equal(selection.transaction.originalTransactionId, "1000");
});

test("the upgraded trial transaction never pulls an unlimited user back to the trial", () => {
  const upgradedTrial = transaction({ isUpgraded: true, expiresDate: NOW + 2 * DAY });
  const selection = selectAccessTransaction([upgradedTrial], NOW);
  assert.deepEqual(selection, { ok: false, reason: "none_active" });
});

test("only a trial transaction selects the trial tier", () => {
  const selection = selectAccessTransaction([transaction(), undefined], NOW);
  assert.equal(selection.ok, true);
  assert.equal(selection.tier, "trial");
});

test("transactions from different subscriptions are rejected as ambiguous", () => {
  const selection = selectAccessTransaction([transaction(), transaction({ originalTransactionId: "9999" })], NOW);
  assert.deepEqual(selection, { ok: false, reason: "ambiguous_owner" });
});

test("no transactions selects nothing", () => {
  assert.deepEqual(selectAccessTransaction([], NOW), { ok: false, reason: "none_active" });
  assert.deepEqual(selectAccessTransaction([undefined], NOW), { ok: false, reason: "none_active" });
});
