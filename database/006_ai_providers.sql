-- ============================================================
-- MAJOOP — Migration 006 : Professeur IA multi-fournisseurs
-- Ajoute les réglages OpenRouter et Mistral (idempotent).
-- Pour les installations existantes : exécuter APRÈS 001→005
-- (les nouvelles installations l'obtiennent déjà via 004 regénéré).
--
-- Secrets à définir côté Supabase (au moins un) :
--   supabase secrets set GEMINI_API_KEY=...        (aistudio.google.com)
--   supabase secrets set OPENROUTER_API_KEY=...    (openrouter.ai)
--   supabase secrets set MISTRAL_API_KEY=...       (console.mistral.ai)
-- ============================================================

-- Choix du fournisseur :
--   'auto'      → essaie Gemini, puis OpenRouter, puis Mistral (repli automatique)
--   'gemini'    → uniquement Gemini
--   'openrouter'→ uniquement OpenRouter
--   'mistral'   → uniquement Mistral
insert into public.admin_settings (key, value, description)
values ('ai_provider', '"auto"'::jsonb,
        'Fournisseur IA : auto (repli gemini→openrouter→mistral) | gemini | openrouter | mistral')
on conflict (key) do update set value = excluded.value, description = excluded.description;

-- Modèle par fournisseur (modifiable dans Administration → XP & IA)
insert into public.admin_settings (key, value, description)
values ('ai_model', '"gemini-2.5-flash"'::jsonb, 'Modèle Gemini utilisé par l''Edge Function')
on conflict (key) do update set description = excluded.description;

insert into public.admin_settings (key, value, description)
values ('ai_model_openrouter', '"meta-llama/llama-3.3-70b-instruct:free"'::jsonb,
        'Modèle OpenRouter (les ID :free changent souvent — voir openrouter.ai/models?max_price=0)')
on conflict (key) do update set value = excluded.value, description = excluded.description;

insert into public.admin_settings (key, value, description)
values ('ai_model_mistral', '"mistral-small-latest"'::jsonb, 'Modèle Mistral (alias stable)')
on conflict (key) do update set value = excluded.value, description = excluded.description;
