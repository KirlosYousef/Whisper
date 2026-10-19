const ENTITLEMENT_IDENTIFIER = "WhisperNote Pro";
const APP_STORE_PRODUCTS = ["KirlosYousef.Whisper.AnnualThreeDayTrial", "KirlosYousef.Whisper.AnnualUnlimited"];

export type StoreTransactionProof = {
  productId?: string;
  transactionId?: string | number;
};

type RevenueCatCustomerResponse = {
  subscriber?: {
    entitlements?: Record<string, unknown>;
    subscriptions?: Record<string, {
      store_transaction_id?: string | number;
      refunded_at?: string | null;
    }>;
  };
};

/**
 * RevenueCat is a refund and ownership signal only: the Apple JWS (verified by the caller, including expiry)
 * is the authoritative proof of an active subscription, and RevenueCat lags behind StoreKit after renewals and plan changes.
 */
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
  const subscriber = (await response.json() as RevenueCatCustomerResponse).subscriber;
  const subscriptions = subscriber?.subscriptions ?? {};
  const records = APP_STORE_PRODUCTS.flatMap(product => subscriptions[product] ? [subscriptions[product]] : []);
  const transactionID = String(transaction.transactionId);
  const refunded = records.some(record => record.refunded_at != null && record.store_transaction_id != null &&
    String(record.store_transaction_id) === transactionID);
  if (refunded) return false;
  return records.length > 0 || subscriber?.entitlements?.[ENTITLEMENT_IDENTIFIER] != null;
}
