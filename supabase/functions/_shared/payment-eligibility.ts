// Shared payment-eligibility gate used by every order-placement edge function.
//
// A user may place orders ONLY if one of the following is true:
//   1. They are an admin (user_roles.role = 'admin').
//   2. They have an ACTIVE, VERIFIED subscription:
//        - subscriptions.status = 'active'
//        - plan_type ∈ ('monthly', 'yearly', 'lifetime')  (never 'trial' / 'none')
//        - expires_at IS NULL OR expires_at > now()
//      Every active row was written by a service-role webhook after the
//      provider verified the payment — end users cannot INSERT/UPDATE this
//      table (RLS + GRANTs restrict it to service_role).
//
// A wallet balance / deposit alone is NOT enough — the subscription must be
// active. Any other user (fresh account, deposit-only wallet, expired sub) is
// blocked with a 403 before we touch the wallet or the orders tables.

import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { recordSecurityEvent } from "./security-audit.ts";

export type PaymentEligibility =
  | { ok: true; reason: "admin" | "subscription" }
  | { ok: false; status: 403; error: string };

const VALID_ACTIVE_PLANS = ["monthly", "yearly", "lifetime"];

export async function assertPaymentEligible(
  admin: SupabaseClient,
  userId: string,
  ctx?: { source: string; request?: Request },
): Promise<PaymentEligibility> {
  if (!userId) {
    return { ok: false, status: 403, error: "Not authenticated" };
  }

  // 1. Admin bypass
  const { data: adminRow } = await admin
    .from("user_roles")
    .select("role")
    .eq("user_id", userId)
    .eq("role", "admin")
    .maybeSingle();
  if (adminRow) return { ok: true, reason: "admin" };

  // 2. Active, verified subscription
  const { data: sub } = await admin
    .from("subscriptions")
    .select("status, plan_type, expires_at")
    .eq("user_id", userId)
    .order("activated_at", { ascending: false, nullsFirst: false })
    .limit(1)
    .maybeSingle();

  if (sub && sub.status === "active" && VALID_ACTIVE_PLANS.includes(String(sub.plan_type))) {
    const notExpired = !sub.expires_at || new Date(sub.expires_at).getTime() > Date.now();
    if (notExpired) return { ok: true, reason: "subscription" };
  }

  await recordSecurityEvent(admin, {
    category: "payment_gate_denied",
    source: ctx?.source ?? "payment-eligibility",
    reason: "no active subscription",
    user_id: userId,
    http_status: 403,
    request: ctx?.request,
  });

  return {
    ok: false,
    status: 403,
    error:
      "Subscription required: activate a subscription before placing orders.",
  };
}
