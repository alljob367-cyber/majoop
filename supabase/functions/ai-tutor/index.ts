// ============================================================
// MAJOOP — Edge Function : ai-tutor
// Professeur IA MULTI-FOURNISSEURS : Gemini, OpenRouter, Mistral.
//  • Auth JWT obligatoire, quotas journaliers, anti-spam
//  • Clés API stockées en secrets serveur (jamais côté client)
//  • Fournisseur choisi via admin_settings.ai_provider :
//      "auto" (repli automatique) | "gemini" | "openrouter" | "mistral"
//  • En mode auto, si un fournisseur échoue (quota, indispo),
//    le suivant disponible répond — l'apprenant n'est jamais bloqué.
//
// Déploiement :
//   supabase functions deploy ai-tutor
//   supabase secrets set GEMINI_API_KEY=...        (aistudio.google.com)
//   supabase secrets set OPENROUTER_API_KEY=...    (openrouter.ai — modèles :free)
//   supabase secrets set MISTRAL_API_KEY=...       (console.mistral.ai — tier gratuit)
//   (option) supabase secrets set ALLOWED_ORIGIN=https://mon-site.fr
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") ?? "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

interface ChatRequest {
  conversationId: string;
  message: string;
}

type ProviderName = "gemini" | "openrouter" | "mistral";

const DEFAULT_MODELS: Record<ProviderName, string> = {
  gemini: "gemini-2.5-flash",
  openrouter: "meta-llama/llama-3.3-70b-instruct:free",
  mistral: "mistral-small-latest",
};

const PROVIDER_KEYS: Record<ProviderName, string> = {
  gemini: "GEMINI_API_KEY",
  openrouter: "OPENROUTER_API_KEY",
  mistral: "MISTRAL_API_KEY",
};

/** Ordre de repli en mode auto : Gemini d'abord (compatibilité existante),
    puis OpenRouter (modèles :free), puis Mistral (tier gratuit). */
const AUTO_CHAIN: ProviderName[] = ["gemini", "openrouter", "mistral"];

const MAX_MESSAGE_LENGTH = 4000;

/** Langue d'interface -> nom lisible, pour les explications du tuteur. */
const UI_LANG_NAMES: Record<string, string> = {
  fr: "français", en: "English", es: "español", de: "Deutsch",
};

/** Langue cible -> nom lisible. */
const TARGET_LANG_NAMES: Record<string, string> = {
  en: "anglais / English", fr: "français", es: "español / Spanish",
  de: "Deutsch / German",
};

/** Construit le prompt système selon le profil et le mode. */
export function buildSystemPrompt(ctx: any): string {
  const user = ctx?.user ?? {};
  const mode: string = ctx?.mode ?? "tutor";
  const scenario: string | null = ctx?.scenario ?? null;
  const uiLang: string = user.interface_lang ?? "fr";
  const targetLang: string = user.target_lang ?? "en";
  const level: string = user.cefr_level ?? "A1";
  const firstName: string = user.first_name || "";

  const uiName = UI_LANG_NAMES[uiLang] ?? "français";
  const targetName = TARGET_LANG_NAMES[targetLang] ?? targetLang;

  const base = [
    "Tu es MAJOOP, un professeur de langues bienveillant, patient et encourageant.",
    `Tu enseignes le ${targetName} à l'apprenant${firstName ? ` ${firstName}` : ""}.`,
    `Son niveau CECRL est ${level} : adapte STRICTEMENT ton vocabulaire et ta grammaire à ce niveau.`,
    `La langue maternelle / d'interface de l'apprenant est : ${uiName}.`,
    `Explique la grammaire et les consignes en ${uiName}, mais pratique la langue cible en ${targetName}.`,
    "Réponds en 120 mots maximum : phrases courtes, un point clé par réponse.",
    "Si l'apprenant fait une erreur de langue, commence ta réponse par une ligne de correction au format :",
    "✏️ Correction : « phrase corrigée » — puis une explication très courte.",
    "Termine par une question ou un petit défi pour faire progresser l'apprenant.",
    "Encourage toujours, jamais de sarcasme, jamais de contenu hors apprentissage des langues.",
  ].join("\n");

  const modePrompts: Record<string, string> = {
    tutor: `MODE PROFESSEUR : explique les règles, corrige les fautes, enseigne du vocabulaire utile, propose un mini-exercice quand c'est pertinent.`,
    conversation: `MODE CONVERSATION LIBRE : tiens une conversation naturelle en langue cible, au niveau ${level}. Reformule doucement ce que dit l'apprenant s'il se trompe (technique de la reformulation).`,
    grammar: `MODE ENTRAÎNEMENT GRAMMATICAL : propose UNE règle à la fois, un exemple, puis un exercice à trous ou une question. Corrige la réponse avant de passer à la suivante.`,
    vocabulary: `MODE VOCABULAIRE : propose 4 à 6 mots du thème choisi, avec traduction et un exemple d'usage chacun. Puis demande à l'apprenant de faire une phrase avec l'un des mots.`,
    situation: `MODE SIMULATION DE SITUATION RÉELLE : joue le rôle du personnage de la scène, en langue cible, au niveau ${level}. Reste dans le rôle jusqu'à la fin de la scène, puis donne un bref bilan avec 2 corrections utiles.`,
  };

  let prompt = `${base}\n\n${modePrompts[mode] ?? modePrompts.tutor}`;
  if (mode === "situation" && scenario) {
    prompt += `\n\nSCÉNARIO : ${scenario}. Commence la scène en te présentant brièvement dans le rôle.`;
  }
  return prompt;
}

/** Message normalisé pour les API compatibles OpenAI (OpenRouter, Mistral). */
interface ChatMsg { role: "system" | "user" | "assistant"; content: string; }

function toChatMessages(systemPrompt: string, history: { role: string; content: string }[]): ChatMsg[] {
  const msgs: ChatMsg[] = [{ role: "system", content: systemPrompt }];
  for (const m of history) {
    if (m.role === "user") msgs.push({ role: "user", content: m.content });
    else if (m.role === "tutor") msgs.push({ role: "assistant", content: m.content });
  }
  return msgs;
}

/** Appel réel à l'API Gemini (AI Studio, tier gratuit). */
export async function callGemini(
  apiKey: string,
  model: string,
  systemPrompt: string,
  history: { role: string; content: string }[],
): Promise<string> {
  const contents = history
    .filter((m) => m.role === "user" || m.role === "tutor")
    .map((m) => ({
      role: m.role === "user" ? "user" : "model",
      parts: [{ text: m.content }],
    }));

  const body = {
    systemInstruction: { parts: [{ text: systemPrompt }] },
    contents,
    generationConfig: { temperature: 0.7, maxOutputTokens: 600 },
  };

  const resp = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    },
  );

  const data = await resp.json();
  if (!resp.ok) {
    const msg = data?.error?.message ?? `HTTP ${resp.status}`;
    throw new Error(`GEMINI_${resp.status}: ${msg}`);
  }

  const parts = data?.candidates?.[0]?.content?.parts ?? [];
  const text = parts
    .map((p: any) => p?.text ?? "")
    .join("")
    .trim();
  if (!text) throw new Error("GEMINI_EMPTY: réponse vide (contenu bloqué ou quota)");
  return text;
}

/** Appel aux API compatibles OpenAI : OpenRouter et Mistral. */
export async function callChatCompletions(
  provider: "openrouter" | "mistral",
  apiKey: string,
  model: string,
  systemPrompt: string,
  history: { role: string; content: string }[],
): Promise<string> {
  const baseUrl = provider === "openrouter"
    ? "https://openrouter.ai/api/v1/chat/completions"
    : "https://api.mistral.ai/v1/chat/completions";

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${apiKey}`,
  };
  if (provider === "openrouter") {
    // Attribution recommandée par OpenRouter (classement d'usage)
    headers["HTTP-Referer"] = Deno.env.get("ALLOWED_ORIGIN") ?? "https://majoop.app";
    headers["X-Title"] = "MAJOOP";
  }

  const resp = await fetch(baseUrl, {
    method: "POST",
    headers,
    body: JSON.stringify({
      model,
      messages: toChatMessages(systemPrompt, history),
      temperature: 0.7,
      max_tokens: 600,
    }),
  });

  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    const msg = data?.error?.message ?? data?.detail ?? `HTTP ${resp.status}`;
    throw new Error(`${provider.toUpperCase()}_${resp.status}: ${msg}`);
  }
  const text = (data?.choices?.[0]?.message?.content ?? "").trim();
  if (!text) throw new Error(`${provider.toUpperCase()}_EMPTY: réponse vide`);
  return text;
}

/** Appel unifié par fournisseur. */
export async function callProvider(
  provider: ProviderName,
  apiKey: string,
  model: string,
  systemPrompt: string,
  history: { role: string; content: string }[],
): Promise<string> {
  if (provider === "gemini") return callGemini(apiKey, model, systemPrompt, history);
  return callChatCompletions(provider, apiKey, model, systemPrompt, history);
}

/** Lit un réglage (admin_settings) via RPC — service_role. */
async function readSetting(adminClient: any, key: string, fallback: string): Promise<string> {
  try {
    const { data } = await adminClient.rpc("get_setting", {
      p_key: key,
      p_default: JSON.stringify(fallback),
    });
    if (typeof data === "string" && data) return data.replace(/"/g, "");
    return fallback;
  } catch {
    return fallback;
  }
}

/** Résout la chaîne de fournisseurs à tenter, dans l'ordre. */
export function resolveProviderChain(
  providerSetting: string,
  env: (name: string) => string | undefined,
): { provider: ProviderName; reason: string }[] {
  const setting = (providerSetting || "auto").toLowerCase();
  if (setting === "auto") {
    return AUTO_CHAIN
      .filter((p) => env(PROVIDER_KEYS[p]))
      .map((p) => ({ provider: p, reason: "auto" }));
  }
  const explicit = AUTO_CHAIN.find((p) => p === setting);
  if (!explicit) return [];
  return [{ provider: explicit, reason: "configuré" }];
}

// ------------------------------------------------------------
// Handler principal (exporté pour les tests)
// ------------------------------------------------------------
export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Méthode non autorisée" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    // ---------- 1. Authentification obligatoire ----------
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Authentification requise" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const adminClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      // Client serveur : pas de session utilisateur à persister
      { auth: { persistSession: false, autoRefreshToken: false } },
    );

    const token = authHeader.replace("Bearer ", "");
    const { data: userData, error: userError } = await adminClient.auth.getUser(token);
    if (userError || !userData?.user) {
      return new Response(JSON.stringify({ error: "Jeton invalide" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const userId = userData.user.id;

    // ---------- 2. Validation de la demande ----------
    const { conversationId, message } = (await req.json()) as ChatRequest;
    if (!conversationId || !message?.trim()) {
      return new Response(
        JSON.stringify({ error: "conversationId et message requis" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }
    if (message.length > MAX_MESSAGE_LENGTH) {
      return new Response(JSON.stringify({ error: "Message trop long" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ---------- 3. Propriété de la conversation ----------
    const { data: conv, error: convError } = await adminClient
      .from("ai_conversations")
      .select("id, user_id")
      .eq("id", conversationId)
      .single();
    if (convError || !conv) {
      return new Response(JSON.stringify({ error: "Conversation introuvable" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (conv.user_id !== userId) {
      return new Response(JSON.stringify({ error: "Conversation non autorisée" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ---------- 4. Quota + anti-spam + enregistrement du message ----------
    const { data: quota, error: quotaError } = await adminClient.rpc(
      "ai_consume_quota",
      { p_conversation: conversationId, p_user_msg: message.trim() },
    );
    if (quotaError) throw quotaError;
    if (quota?.ok === false) {
      return new Response(
        JSON.stringify({ error: quota.message, reason: quota.reason }),
        { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // ---------- 5. Résolution du fournisseur IA (multi-provider) ----------
    const providerSetting = await readSetting(adminClient, "ai_provider", "auto");
    const chain = resolveProviderChain(providerSetting, (n) => Deno.env.get(n));
    if (chain.length === 0) {
      return new Response(
        JSON.stringify({
          error:
            "Le professeur IA n'est pas encore configuré : ajoute au moins un secret GEMINI_API_KEY, OPENROUTER_API_KEY ou MISTRAL_API_KEY sur Supabase. Voir GUIDE_INSTALLATION.md.",
          reason: "no_api_key",
        }),
        { status: 501, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }
    // Fournisseur explicite mais clé absente = erreur de configuration :
    // on échoue immédiatement avec le nom exact du secret à ajouter.
    if (providerSetting.toLowerCase() !== "auto") {
      const only = chain[0];
      if (only && !Deno.env.get(PROVIDER_KEYS[only.provider])) {
        return new Response(
          JSON.stringify({
            error: `Le fournisseur ${only.provider} est sélectionné (admin_settings.ai_provider) mais le secret ${PROVIDER_KEYS[only.provider]} est absent sur Supabase.`,
            reason: "no_api_key",
          }),
          { status: 501, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
    }

    // ---------- 6. Contexte pédagogique ----------
    const { data: ctx, error: ctxError } = await adminClient.rpc("ai_get_context", {
      p_conversation: conversationId,
      p_history: 12,
    });
    if (ctxError) throw ctxError;

    const systemPrompt = buildSystemPrompt(ctx);
    const history = (ctx?.history ?? []) as { role: string; content: string }[];

    // ---------- 7. Appel avec repli automatique ----------
    let reply = "";
    let usedProvider: ProviderName | null = null;
    let usedModel = "";
    const errorsTried: string[] = [];

    for (const { provider } of chain) {
      const settingKey = provider === "gemini" ? "ai_model" : `ai_model_${provider}`;
      const model = await readSetting(adminClient, settingKey, DEFAULT_MODELS[provider]);
      const apiKey = Deno.env.get(PROVIDER_KEYS[provider])!;
      try {
        reply = await callProvider(provider, apiKey, model, systemPrompt, history);
        usedProvider = provider;
        usedModel = model;
        break;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        errorsTried.push(`${provider}: ${msg}`);
        // Le repli continue vers le fournisseur suivant de la chaîne
      }
    }

    if (!usedProvider) {
      const allQuota = errorsTried.length > 0 && errorsTried.every((e) => e.includes("_429"));
      return new Response(
        JSON.stringify({
          error: allQuota
            ? "Limite des modèles gratuits atteinte pour aujourd'hui — réessaie plus tard !"
            : `Erreur du professeur IA (${errorsTried.join(" | ")})`,
        }),
        { status: allQuota ? 429 : 502, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // ---------- 8. Sauvegarde de la réponse ----------
    await adminClient.rpc("ai_save_tutor_message", {
      p_conversation: conversationId,
      p_content: reply,
    });

    return new Response(
      JSON.stringify({ reply, conversationId, provider: usedProvider, model: usedModel }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (e) {
    console.error("ai-tutor error:", e);
    return new Response(JSON.stringify({ error: "Erreur interne du serveur IA" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
}

// En déploiement Supabase, ce fichier EST le point d'entrée → serve.
// En test (import du module), import.meta.main est false → le serveur ne démarre pas.
if (import.meta.main) {
  Deno.serve(handler);
}
