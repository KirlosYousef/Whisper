export const TRIAL_PRODUCT_ID = "KirlosYousef.Whisper.AnnualThreeDayTrial";
export const UNLIMITED_PRODUCT_ID = "KirlosYousef.Whisper.AnnualUnlimited";
export const APP_STORE_PRODUCTS = new Set([TRIAL_PRODUCT_ID, UNLIMITED_PRODUCT_ID]);

/** Apple's `offerType` for an introductory offer (the trial product's 3-day free trial). */
const INTRODUCTORY_OFFER = 1;

export type AccessTier = "trial" | "paid";

/** The fields of a verified, decoded App Store transaction that decide access. */
export type VerifiedTransaction = {
  originalTransactionId?: string;
  transactionId?: string | number;
  productId?: string;
  expiresDate?: number;
  revocationDate?: number | null;
  isUpgraded?: boolean;
  offerType?: number;
  offerDiscountType?: string;
};

/**
 * A transaction is in its free trial only while it is the trial product's introductory free offer.
 * Once Apple renews it after 3 days, or the user moves to the unlimited product, it is paid.
 * Older payloads may omit `offerDiscountType`, so the introductory `offerType` also counts.
 */
export function accessTierForTransaction(transaction: VerifiedTransaction): AccessTier {
  if (transaction.productId !== TRIAL_PRODUCT_ID) return "paid";
  if (transaction.offerDiscountType === "FREE_TRIAL") return "trial";
  if (transaction.offerDiscountType == null && transaction.offerType === INTRODUCTORY_OFFER) return "trial";
  return "paid";
}

/** True when the transaction can grant access right now. */
export function isUsableTransaction(transaction: VerifiedTransaction, nowMs: number): boolean {
  return Boolean(transaction.originalTransactionId) &&
    APP_STORE_PRODUCTS.has(transaction.productId ?? "") &&
    transaction.revocationDate == null &&
    // An upgraded transaction was replaced by a newer one; it must not pull the user back to the trial.
    transaction.isUpgraded !== true &&
    typeof transaction.expiresDate === "number" &&
    transaction.expiresDate > nowMs;
}

export type TransactionSelection =
  | { ok: true; transaction: VerifiedTransaction & { originalTransactionId: string; productId: string; expiresDate: number }; tier: AccessTier }
  | { ok: false; reason: "none_active" | "ambiguous_owner" };

/**
 * Picks the transaction that decides access from the client's current entitlements.
 * Paid wins over trial (a plan change can briefly report both), then the latest expiry.
 */
export function selectAccessTransaction(transactions: Array<VerifiedTransaction | undefined>, nowMs: number): TransactionSelection {
  const usable = transactions.filter((item): item is VerifiedTransaction => item != null && isUsableTransaction(item, nowMs));
  if (usable.length === 0) return { ok: false, reason: "none_active" };
  if (new Set(usable.map(item => item.originalTransactionId)).size !== 1) return { ok: false, reason: "ambiguous_owner" };
  const [transaction] = [...usable].sort((a, b) => {
    const paidDifference = Number(accessTierForTransaction(b) === "paid") - Number(accessTierForTransaction(a) === "paid");
    return paidDifference || (b.expiresDate ?? 0) - (a.expiresDate ?? 0);
  });
  return {
    ok: true,
    transaction: transaction as VerifiedTransaction & { originalTransactionId: string; productId: string; expiresDate: number },
    tier: accessTierForTransaction(transaction),
  };
}
