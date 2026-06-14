# CODE FEDDY v7 refreshable Lovable stats

This build adds a Refresh TikTok stats button and a GitHub Action deep sync.

Public button: refreshes latest synced JSON and tries direct Lovable page read if browser allows it.

Deep sync: Actions -> Sync Lovable social stats -> Run workflow. Enable Settings -> Actions -> General -> Workflow permissions -> Read and write permissions.

Keep video at assets/codefeddy-background.mp4


## v8 Revive Hemp top offer

Top affiliate offer is now Revive Hemp Store with code FEDDY for 10% off. The card image points to https://revivehemp.store/favicon.ico and falls back to assets/revive-hemp-logo.svg if the remote logo/favicon fails.


## v9 top affiliate slots

1. Revive Hemp Store — code FEDDY — 10% off
2. CannaClear — code FEDDY — 15% off
3. The Delta Connect — code FEDDY — 15% off

The cards attempt to use each brand site favicon first:
- https://revivehemp.store/favicon.ico
- https://cannaclear.com/favicon.ico
- https://thedeltaconnect.com/favicon.ico

If a favicon fails, the card falls back to local SVG assets.


## v10 affiliate fallback fix

This build fixes the issue where cards could load example.com if data/drops.json failed to load.
The correct top three affiliate offers are now in BOTH:
- data/drops.json
- app.js fallbackData.drops

There are no example.com links in data/drops.json or app.js.

Top three:
1. Revive Hemp Store — code FEDDY — 10% off
2. CannaClear — code FEDDY — 15% off
3. The Delta Connect — code FEDDY — 15% off


## v11 changes

- Top CODE FEDDY brand now shows "(Now on AWIN)".
- Removed old placeholder cards:
  - Creator Tool Slot
  - Accessory / Gear Slot
  - Rotating Weekly Slot
- Added:
  - LIP BALM ACCESSORIES & TOOLS
  - Links to CannaClear 17oz Stainless Steel Water Bottle
  - Uses CannaClear product image from their site with local fallback SVG


## v12 changes

- Removed "· Now on AWIN" from the hero pill, kept "(Now on AWIN)" in the top CODE FEDDY brand.
- Replaced hero copy with:
  "Only the most meticulously hand crafted finds to help fellow healers navigate this weary world with ease."
- Changed "Fast paths to buy" to "Trusted Partner Discounts".
- Changed top vendor card type label from "Affiliate" to "Trusted Lipbalm Provider".
- Removed old placeholder retailer cards and kept only real retailer/product cards.
- Added:
  - CannaClear Lanyard accessory card
  - CannaClear Bulk THCa Diamonds featured lip balm product card
  - Revive Crumble With HTE featured lip balm product card


## v13 changes

- Incorporated the uploaded circular CODE FEDDY logo on the homepage hero.
- The logo now appears to the right of the giant white "CODE FEDDY" title.
- Added the logo file locally as:
  assets/codefeddy-homepage-logo.png


## v14 changes

- Replaced the previous hero logo with the newly uploaded logo.
- Reworked the homepage hero into a sleeker layout.
- Reduced the oversized white title treatment and paired it with a cleaner minimal wordmark.
- Added a soft multicolor glow / halo around the hero logo.
- Kept the logo right-aligned on desktop and stacked elegantly on mobile.


## v15 changes

- Hero copy changed to:
  "Curated deals from trusted vendors to help you get the best price for your balm."
- Removed duplicate "(Now on AWIN)" after the first header appearance.
- Expanded cards from Revive Hemp, CannaClear, and The Delta Connect using publicly visible product/category listings and product pages.
- Card count: 45
- All cards include code/perk, product/store link, and image/fallback image.
- Old placeholder/example cards are still removed.


## v17 changes

- Replaced the favicon reference with the CODE FEDDY logo PNG.
- Removed all product cards whose image could not be verified as a real product image.
- Removed all checkmark/local SVG product placeholders from live card usage.
- Kept only verified real-image cards:
  - CannaClear water bottle
  - CannaClear lanyard
  - CannaClear glass syringe
  - CannaClear Bulk THCa Diamonds
  - Revive Crumble With HTE
  - plus the three trusted partner cards
- If a live product image fails, the card removes itself instead of showing a fake checkmark graphic.


## v18 changes

- Replaced the three trusted partner card images with local logo images copied into the zip.
- Revive Hemp card now uses `assets/revive-site-logo.png`.
- CannaClear card now uses `assets/cannaclear-site-logo.png`.
- The Delta Connect card now uses `assets/delta-connect-site-logo.png`.
- Kept all other v17 behavior the same.


## v19 changes

- Rebuilt Revive vendor card to avoid the revivehemp.com leaf logo and use a revivehemp.store-style wordmark card.
- Rebuilt CannaClear vendor card so the logo fits cleanly inside the card.
- Rebuilt The Delta Connect vendor card using a local brand image card.
- Added product cards only where a product page/listing had a matching visible image and that image was copied into the zip.
- Total cards: 22.
- All card images are local files under assets/vendor-logos or assets/vendor-products.


## v20 changes

- Replaced the top-left brand icon with a smaller local version of the CODE FEDDY hero logo.
- Added `assets/codefeddy-small-brand-icon.png`.
- Updated favicon files from the same icon.
- Tightened topbar icon sizing so it fits cleanly inside the brand pill.


## v22 changes

- Removed the top-left brand image entirely.
- Added CSS guard to hide any brand image that might still be cached in older markup.
- Refreshed social stats from current visible Lovable output:
  - Cumulative following: —
  - Likes: 0
  - Accounts: 16
- Set per-account follower values to unavailable because the current Lovable output does not expose numeric per-account counts.


## v23 changes

- Replaced the bad non-rendered Lovable parse with the rendered Lovable traction values previously captured from the page:
  - Total followers: 3.3K
  - Exact follower total: 3,273
  - Likes: 5.9K
  - Accounts: 16
- Restored per-account follower counts.
- Kept the top-left icon removed.


## v24 changes

- Fixed the 21+ / Enter age gate button.
- Added a defensive `setupAgeGate()` implementation.
- Added an inline fallback click handler so the popup can still close even if cached JS misbehaves.
- Kept the top-left brand icon removed and retained restored rendered traction stats.


## v25 changes

- Removed the full stats/network section completely.
- Kept the small hero proof-strip/blip.
- Restored the verified local-image card set.
- Restored 22 deal/product cards with local images from v19.
- Kept top-left brand image removed.
- Kept the v24 age gate fix.


## v26 changes

- Removed the blocking 21+ age gate modal entirely.
- Removed `age-locked` body behavior.
- Added a small non-blocking 21+ / third-party retailer notice above the footer.
- Kept the restored local card set from v25.
- Kept the big stats/network section removed.


## v28 full regression fix

- Rebuilt `app.js` from scratch to remove the broken dependency chain.
- Restored the historical expanded card set from v15.
- Normalized every card image to a local asset or local fallback.
- Pre-rendered all cards directly into `index.html` and `404.html` so cards appear even if JavaScript fails.
- Kept the 21+ gate removed and kept the non-blocking footer notice.
- Kept the full Network/stats section removed while retaining the small hero proof blip.
- Verified all 45 cards have redirect links and local image paths.


## v29 changes

- Restored the `Portfolio / Traction` button.
- Button links directly to `https://codefeddy.lovable.app/#traction`.
- Added the same direct link to the top navigation.
- Preserved v28 full-card regression fix with 45 pre-rendered cards.


## v30 changes

- Reworked the cards into an image-first layout.
- Restored verified local product photos for the cards that had them.
- Replaced several broken/missing placeholder images with current product image URLs found from vendor product pages.
- Updated offer links so Revive and The Delta Connect use Shopify discount links with `FEDDY`.
- Updated CannaClear links to carry `coupon_code=FEDDY` and copy `FEDDY` on click as a fallback.
- Changed the main card CTA to `Open + apply/copy code`.


## v31 changes

- Corrected the missed image-ID mapping from v30.
- Replaced more placeholder/SVG cards with real product image URLs or already-verified local product photos.
- Preserved the improved v30 card layout and code-copy/open behavior.

## v32 changes
- Rebuilt every product and main-store card link as a code-aware deep link.
- Revive Hemp uses /discount/FEDDY?redirect=...
- The Delta Connect uses /discount/FEDDY?redirect=...
- CannaClear links include coupon=FEDDY, coupon_code=FEDDY, and code=FEDDY.
- All offer clicks also copy FEDDY as a checkout fallback.


## v33 changes

- Hero `Trusted Partner Discounts` now shows only the three main store partners:
  Revive Hemp Store, CannaClear, and The Delta Connect.
- Partner quick-card message restored:
  `Click to shop with FEDDY auto applied in cart`.
- Removed the three main store cards from the product grid so they only appear in the hero panel.
- Product grid now contains product cards only.
- Added extra responsive image-fit rules for mobile and desktop.


## v35 changes

- Made the v34 partner-card fix permanent and removed deploy-canary comments.
- Reordered hero partner cards: Revive Hemp Store, The Delta Connect, CannaClear.
- Changed partner quick-card message to `Click to shop`.
- Reduced spacing/gap around the Trusted Partner Discounts hero panel.
- Refreshed proof blip stats to the visible Lovable traction readout values: 16 accounts, 3.3K reach, 5.9K likes.


V39 update: upgraded placeholder product cards with more realistic brand-styled mockups and large faint brand-logo backgrounds.
