import assert from "node:assert/strict";
import test from "node:test";
import { verifyRevenueCatEntitlement } from "../src/revenuecat-entitlement.ts";

const productId = "KirlosYousef.Whisper.AnnualUnlimited";
const trialProductId = "KirlosYousef.Whisper.AnnualThreeDayTrial";
const transactionId = "1000000123456789";
const future = new Date(Date.now() + 60 * 60 * 1000).toISOString();
const past = new Date(Date.now() - 60 * 60 * 1000).toISOString();

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

async function verify(payload, proof = { productId, transactionId }) {
  return verifyRevenueCatEntitlement("any-customer", proof, "secret", async () => response(payload));
}

test("accepts an active RevenueCat customer and sends the bearer key", async () => {
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

test("rejects a presented transaction that RevenueCat records as refunded", async () => {
  const refunded = customer({ subscription: { refunded_at: new Date().toISOString() } });
  assert.equal(await verify(refunded), false);
  const refundedTrial = {
    subscriber: {
      subscriptions: {
        [trialProductId]: { store_transaction_id: transactionId, refunded_at: new Date().toISOString(), expires_date: past },
      },
    },
  };
  assert.equal(await verify(refundedTrial, { productId: trialProductId, transactionId }), false);
});

test("ignores a refund that belongs to a different transaction", async () => {
  const otherRefund = customer({ subscription: { store_transaction_id: "older-transaction", refunded_at: new Date().toISOString() } });
  assert.equal(await verify(otherRefund), true);
});

test("accepts renewal lag: RevenueCat still shows the previous transaction with a past expiry", async () => {
  const lagging = customer({
    entitlement: { expires_date: past },
    subscription: { store_transaction_id: "previous-transaction", expires_date: past },
  });
  assert.equal(await verify(lagging), true);
});

test("accepts plan change lag: presented unlimited product while RevenueCat still reports the trial product", async () => {
  const lagging = {
    subscriber: {
      entitlements: {
        "WhisperNote Pro": { product_identifier: trialProductId, expires_date: future },
      },
      subscriptions: {
        [trialProductId]: { store: "app_store", store_transaction_id: "trial-transaction", expires_date: future },
      },
    },
  };
  assert.equal(await verify(lagging, { productId, transactionId }), true);
});

test("rejects an unknown subscriber with no subscription records and no entitlement", async () => {
  assert.equal(await verify({ subscriber: { entitlements: {}, subscriptions: {} } }), false);
  assert.equal(await verify({ subscriber: {} }), false);
});

test("accepts a known subscriber that has only an entitlement", async () => {
  const entitlementOnly = { subscriber: { entitlements: { "WhisperNote Pro": { product_identifier: productId, expires_date: past } } } };
  assert.equal(await verify(entitlementOnly), true);
});

test("treats RevenueCat lookup failures as unresolved verification", async () => {
  await assert.rejects(
    verifyRevenueCatEntitlement("customer", { productId, transactionId }, "secret", async () => response({}, 503)),
  );
});
