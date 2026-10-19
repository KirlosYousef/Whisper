import assert from "node:assert/strict";
import test from "node:test";
import { verifyRevenueCatEntitlement } from "../src/revenuecat-entitlement.ts";

const productId = "KirlosYousef.Whisper.AnnualUnlimited";
const transactionId = "1000000123456789";
const future = new Date(Date.now() + 60 * 60 * 1000).toISOString();

function customer(overrides = {}) {
  return {
    subscriber: {
      entitlements: {
        "WhisperNote Pro": {
          product_identifier: productId,
          expires_date: future,
          ...overrides.entitlement,
        },
      },
      subscriptions: {
        [productId]: {
          store: "app_store",
          store_transaction_id: transactionId,
          expires_date: future,
          ...overrides.subscription,
        },
      },
    },
  };
}

function response(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}

test("requires matching active RevenueCat entitlement and Apple store transaction", async () => {
  let requestedURL;
  const valid = await verifyRevenueCatEntitlement(
    "anonymous/user id",
    { productId, transactionId },
    "server-secret",
    async (url, init) => {
      requestedURL = String(url);
      assert.equal(new Headers(init.headers).get("Authorization"), "Bearer server-secret");
      return response(customer());
    },
  );
  assert.equal(valid, true);
  assert.match(requestedURL, /anonymous%2Fuser%20id$/);
});

test("does not accept a customer ID without the same active product transaction", async () => {
  const cases = [
    customer({ subscription: { store_transaction_id: "another-transaction" } }),
    customer({ subscription: { store: "play_store" } }),
    customer({ subscription: { refunded_at: new Date().toISOString() } }),
    customer({ entitlement: { expires_date: new Date(Date.now() - 60_000).toISOString() } }),
    { subscriber: {} },
  ];
  for (const payload of cases) {
    assert.equal(
      await verifyRevenueCatEntitlement("any-customer", { productId, transactionId }, "secret", async () => response(payload)),
      false,
    );
  }
});

test("treats RevenueCat lookup failures as unresolved verification", async () => {
  await assert.rejects(
    verifyRevenueCatEntitlement("customer", { productId, transactionId }, "secret", async () => response({}, 503)),
  );
});
