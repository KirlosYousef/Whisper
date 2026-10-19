const ENTITLEMENT_IDENTIFIER = "WhisperNote Pro";

export type StoreTransactionProof = {
  productId?: string;
  transactionId?: string | number;
};

type RevenueCatCustomerResponse = {
  subscriber?: {
    entitlements?: Record<string, {
      product_identifier?: string;
      expires_date?: string | null;
      grace_period_expires_date?: string | null;
    }>;
    subscriptions?: Record<string, {
      store?: string;
      store_transaction_id?: string | number;
      expires_date?: string | null;
      grace_period_expires_date?: string | null;
      refunded_at?: string | null;
    }>;
  };
};

function activeUntil(expiration?: string | null, graceExpiration?: string | null): number {
  const expirationTime = expiration ? Date.parse(expiration) : 0;
  const graceExpirationTime = graceExpiration ? Date.parse(graceExpiration) : 0;
  return Math.max(
    Number.isFinite(expirationTime) ? expirationTime : 0,
    Number.isFinite(graceExpirationTime) ? graceExpirationTime : 0,
  );
}

export async function verifyRevenueCatEntitlement(
  appUserID: string,
  transaction: StoreTransactionProof,
  apiKey: string,
  fetcher: typeof fetch = fetch,
): Promise<boolean> {
  if (!transaction.productId || transaction.transactionId == null) return false;
  const response = await fetcher(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserID)}`, {
    headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json" },
  });
  if (!response.ok) throw new Error("RevenueCat subscription lookup failed.");
  const payload = await response.json() as RevenueCatCustomerResponse;
  const entitlement = payload.subscriber?.entitlements?.[ENTITLEMENT_IDENTIFIER];
  const subscription = payload.subscriber?.subscriptions?.[transaction.productId];
  const transactionID = String(transaction.transactionId);
  const revenueCatTransactionID = subscription?.store_transaction_id == null
    ? ""
    : String(subscription.store_transaction_id);
  return Boolean(
    entitlement && subscription &&
    entitlement.product_identifier === transaction.productId &&
    subscription.store === "app_store" &&
    subscription.refunded_at == null &&
    revenueCatTransactionID === transactionID &&
    activeUntil(entitlement.expires_date, entitlement.grace_period_expires_date) > Date.now() &&
    activeUntil(subscription.expires_date, subscription.grace_period_expires_date) > Date.now()
  );
}
