// MAJOOP — Edge Function verify-payment
// Chantier 2 du rapport : vérification AUTOMATIQUE d'une référence de
// paiement MTN MoMo, avec repli manuel si les secrets ne sont pas
// configurés. Déploiement :
//   supabase functions deploy verify-payment
// Secrets optionnels (Supabase → Edge Functions → Secrets) :
//   MOMO_SUBSCRIPTION_KEY, MOMO_API_USER, MOMO_API_KEY,
//   MOMO_TARGET_ENV (sandbox|mtncameroon…), MOMO_BASE_URL
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, code = 200) =>
  new Response(JSON.stringify(body), { status: code, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { check_id } = await req.json();
    if (!check_id) return json({ error: "check_id requis" }, 400);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const subKey = Deno.env.get("MOMO_SUBSCRIPTION_KEY");
    if (!subKey) {
      return json({ status: "manual_required", reason: "MOMO_SUBSCRIPTION_KEY non configuré — validation manuelle" });
    }

    const { data: check, error: e1 } = await admin.from("payment_checks").select("*").eq("id", check_id).single();
    if (e1 || !check) return json({ error: "contrôle introuvable" }, 404);
    if (check.status !== "pending") return json({ status: check.status, already: true });

    const base = Deno.env.get("MOMO_BASE_URL") || "https://sandbox.momodeveloper.mtn.com";
    const apiUser = Deno.env.get("MOMO_API_USER") || "";
    const apiBasic = btoa(`${apiUser}:${Deno.env.get("MOMO_API_KEY") || ""}`);
    const targetEnv = Deno.env.get("MOMO_TARGET_ENV") || "sandbox";

    // 1) Token d'accès Collection
    const tk = await fetch(`${base}/collection/token/`, {
      method: "POST",
      headers: {
        "Authorization": `Basic ${apiBasic}`,
        "Ocp-Apim-Subscription-Key": subKey,
        "X-Reference-Id": apiUser,
      },
    });
    if (!tk.ok) return json({ status: "manual_required", reason: `token MoMo ${tk.status}` });
    const { access_token } = await tk.json();

    // 2) Statut de la transaction (referenceId = référence du paiement)
    const st = await fetch(`${base}/collection/v1_0/requesttopay/${encodeURIComponent(check.reference)}`, {
      headers: {
        "Authorization": `Bearer ${access_token}`,
        "X-Target-Environment": targetEnv,
        "Ocp-Apim-Subscription-Key": subKey,
      },
    });
    const raw = await st.json().catch(() => ({}));
    const map: Record<string, string> = { SUCCESSFUL: "auto_verified", FAILED: "auto_rejected" };
    const status = map[raw?.status] || "pending";

    await admin.from("payment_checks").update({
      status,
      details: { provider_status: raw?.status ?? null, http: st.status, raw },
      checked_at: new Date().toISOString(),
    }).eq("id", check_id);

    return json({ status, provider_status: raw?.status ?? null });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});
