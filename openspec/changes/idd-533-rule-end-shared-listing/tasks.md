## 1. Shared listing

- [ ] 1.1 Differential test over a grid of call shapes through `SeriesListingMemo` with a counting fake: `main`'s order against the branch's; equal answers, one listing fewer exactly where #509 and the baseline ask for the same key. Verify: `RuleEndListingSharingTests` (red first on the listing count), marker `spec-example: series-listing-sharing / listings by call shape`.
- [ ] 1.2 Open `seriesListings.sharing` at the top of the #509 block. Verify: `SingleListingWiringTests` pins updated (where it opens, the refreshes on the own-id route before every shared listing).

## 2. Texts

- [ ] 2.1 CHANGELOG `[Unreleased]`, README sentences on shared listings, code comments.

## 3. Checks

- [ ] 3.1 Suite in three zones, removed-test check, mutants, device timing on a disposable `#533` calendar (`--cli`, signed builds of the branch and of `main`).
