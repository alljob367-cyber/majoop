# docs/ — copie de publication GitHub Pages

`index.html` est la **copie de déploiement** de [`app/index.html`](../app/index.html) — l'application canonique (un seul fichier autonome, aucun build).

GitHub Pages sert ce dossier en mode **« Deploy from a branch »** : branche `main`, dossier `/docs`.
URL du site : `https://TON-PSEUDO.github.io/majoop/`

⚠️ Ne modifie pas ce fichier directement. Mets à jour `app/index.html`, puis :

```bash
cp app/index.html docs/index.html
git add -A && git commit -m "Mise à jour du site" && git push
```
