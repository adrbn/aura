# Aura site — privacy policy hosting

This folder hosts the **privacy policy page** required by the App Store. It is
deliberately **separate from the app source repo** so you can publish it now,
without publishing the (still-unfinished) app source — the source repo still has
the trial font embedded and `TODO-` placeholders.

`privacy.html` is **ready to deploy as-is** — GitHub user `adrbn` is filled in and
the contact routes through GitHub issues. (Optional later: add a dedicated contact
email by editing the "Contact" section in one place.)

## Deploy to GitHub Pages (dedicated repo)

```bash
# 1. Create a new PUBLIC repo on GitHub named  aura-site
# 2. From the repo root:
cd site
git init
git add privacy.html
git commit -m "chore: privacy policy"
git branch -M main
git remote add origin https://github.com/adrbn/aura-site.git
git push -u origin main
```

Then on GitHub: **Settings → Pages → Source: `main` / root → Save.**

Your live URL (paste into App Store Connect → Privacy Policy URL):

```
https://adrbn.github.io/aura-site/privacy.html
```

> Optional nicety: rename `privacy.html` → `index.html` to get a clean
> `https://adrbn.github.io/aura-site/` URL, or add a landing page as `index.html`
> and keep `privacy.html` alongside.

## Custom domain (optional)

If you register a domain (e.g. `aura-music.app`), add a `CNAME` file in this
folder containing the domain, point DNS at GitHub Pages, and your URL becomes
`https://aura-music.app/privacy.html`.
