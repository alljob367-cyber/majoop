# 🚀 Mettre MAJOOP en ligne sur GitHub Pages (gratuit)

L'application est **un seul fichier** (`app/index.html`, aucun build) : GitHub Pages l'héberge gratuitement à l'adresse finale :

```
https://TON-PSEUDO.github.io/majoop/
```

*(remplace `TON-PSEUDO` par ton identifiant GitHub, et `majoop` par le nom du dépôt si tu en choisis un autre)*

Deux voies possibles — même résultat. La **voie B** est recommandée : les mises à jour futures se publient d'un simple `git push`.

---

## Voie A — Sans rien installer (5 minutes, navigateur uniquement)

1. Crée un compte sur [github.com](https://github.com) si besoin, puis un **nouveau dépôt public** nommé `majoop` (bouton « New repository » → « Public » → ne coche aucune option d'initialisation → Create).
2. Sur la page du dépôt vide, clique **« uploading an existing file »**, puis glisse-dépose **le fichier `app/index.html`** uniquement. En bas, « Commit changes ».
3. **Settings → Pages** → « Build and deployment » → Source : **« Deploy from a branch »** → Branch : `main`, dossier `/ (root)` → Save.
4. Attends ~1 minute, rafraîchis : l'URL `https://TON-PSEUDO.github.io/majoop/` est verte et l'app s'ouvre.

> Mise à jour de l'app dans cette voie : ouvre le dépôt → le crayon sur `index.html` → remplace tout le contenu → Commit. 

## Voie B — Dépôt complet prêt à pousser (recommandée)

Le dossier `majoop/` de ce livrable est **déjà un dépôt Git prêt** (branche `main`, tout committé, workflow de déploiement inclus dans `.github/workflows/pages.yml`). Chaque push sur `main` republie automatiquement l'app — aucun build, aucune manipulation après coup.

1. **Crée le dépôt** (vide, public, nommé `majoop`) sur [github.com/new](https://github.com/new). Ne coche PAS « Add a README ».
2. **Pousse le dépôt préparé** — sur ta machine, dans le dossier `majoop` :

   ```bash
   git remote add origin https://github.com/TON-PSEUDO/majoop.git
   git push -u origin main
   ```

   *(GitHub te demandera de t'identifier : sur le web c'est le navigateur, en ligne de commande utilise un [Personal Access Token](https://github.com/settings/tokens) comme mot de passe — jamais ton mot de passe de compte.)*
3. **Active Pages** (une seule fois) : dépôt → **Settings → Pages** → Source : **« GitHub Actions »**.
4. Onglet **Actions** du dépôt : le workflow « Déployer MAJOOP sur GitHub Pages » tourne (~1 min). L'URL est alors en ligne.

Mises à jour suivantes : modifie les fichiers, puis `git add -A && git commit -m "…" && git push` → republié automatiquement.

---

## Après la mise en ligne — checklist (les 2 voies)

| # | Action | Où | Pourquoi |
|---|---|---|---|
| 1 | Ouvre l'URL publiée → ⚙️ Réglages → **Connexion Supabase** → colle l'URL + la clé anon de ton projet → Tester et enregistrer | dans l'app | sans ça, l'app reste en MODE DÉMO |
| 2 | `supabase secrets set ALLOWED_ORIGIN=https://TON-PSEUDO.github.io` puis `supabase functions deploy ai-tutor` | Supabase CLI | restreint le CORS de l'IA (optionnel mais recommandé ; la valeur `*` par défaut fonctionne aussi) |
| 3 | Teste : crée un compte, termine une leçon, recharge → l'XP est conservé | dans l'app | vérifie la chaîne complète Pages ↔ Supabase |

## Dépannage Pages

| Symptôme | Cause | Solution |
|---|---|---|
| 404 sur l'URL | Pages pas activé, ou mauvaise branche/dossier | Settings → Pages : voie A = `main` + `/ (root)` ; voie B = « GitHub Actions » |
| Le workflow échoue dans l'onglet Actions | Pages activé en « Deploy from a branch » alors que le workflow exige « GitHub Actions » | Settings → Pages → Source = GitHub Actions, relance le workflow (Re-run) |
| L'app s'affiche mais « MODE DÉMO » | Supabase non connecté dans les Réglages | checklist #1 |
| Le tuteur IA répond mais une erreur CORS apparaît | `ALLOWED_ORIGIN` ne contient pas l'URL Pages | checklist #2 (ou laisse `*`) |
| Modification poussée mais site inchangé | cache Pages | attends ~1 min puis Ctrl+F5 (rechargement forcé) |

## Domaine personnalisé (optionnel)

Settings → Pages → « Custom domain » : ajoute `app.mondomaine.fr` et crée chez ton registrar un enregistrement CNAME vers `TON-PSEUDO.github.io`. Pensée HTTPS automatique par GitHub. Met ensuite à jour `ALLOWED_ORIGIN` avec le nouveau domaine.
