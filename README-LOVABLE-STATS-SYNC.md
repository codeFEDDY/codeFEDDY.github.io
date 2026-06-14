# CODE FEDDY v3: Lovable social stats sync

Upload these files over the repo root and commit.

## What this changes

- `data/accounts.json` now mirrors the 16-handle order from `https://codefeddy.lovable.app/#traction`.
- `data/site.json` uses the values exposed by that public Lovable page.
- `app.js` now displays numeric follower counts when they exist, but gracefully falls back to `followers` when Lovable does not expose a number.
- `scripts/sync-lovable-stats.mjs` can scrape the rendered Lovable traction page and rewrite `data/accounts.json` and `data/site.json`.
- `.github/workflows/sync-lovable-stats.yml` lets GitHub Actions run the sync manually or daily.

## Manual sync from your computer

```bash
npm init -y
npm install --save-dev playwright
npx playwright install chromium
node scripts/sync-lovable-stats.mjs
```

Then commit the changed `data/accounts.json` and `data/site.json`.

## GitHub Actions sync

After upload:

1. Go to GitHub → Actions.
2. Choose `Sync Lovable social stats`.
3. Click `Run workflow`.

If it cannot push changes, go to:

Settings → Actions → General → Workflow permissions → Read and write permissions → Save.

## Reality check

The public text currently exposed by Lovable shows:

- cumulative following: `—`
- total likes: `0`
- 16 accounts
- each account row as `@ handle — followers`

If your browser view shows more specific numbers, the Playwright sync script is included so GitHub can render the page and capture them if they are actually present in the DOM.
