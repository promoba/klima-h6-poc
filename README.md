# Klima Protocol v2 — H-6 PoC (Foundry fork test)

Finding: the stored discounted-forward-balance (DFB) contains **undiscounted**
forward tonnes, so every retirement after the first liquid swap of a day burns
too little kVCM (AAM pricing/accounting manipulation).

Suite: `test/KlimaFork.t.sol` — 4 tests, all passing (see `evidence.log`):

- `test_retireQuoteDropsAfterLiquidSwap_seededForwards` — seeds 20,000 forward
  tonnes into the WIND_INDIA vault via the protocol's own
  `CarbonLedger.addCreditLiquidityToClassVault`; fresh-day quote to retire
  100 tonnes = 712.3299 kVCM; after a permissionless 1-tonne liquid swap the
  stored DFB = 20,000 tonnes and the same quote drops to 652.3875 kVCM.
- `test_actualRetireBurnsReducedQuote` — a real retirement through the AAM
  burns exactly the reduced quote: 59.94 kVCM (8.41%) less than the fresh-day
  price for the same carbon.
- `test_noDiscountFactors_forwardSwapReverts` — supporting: no code writes
  discount factors in v1.0.0 (40/40 live factors are 0).
- `test_unprivilegedMintGuards` — supporting: ProtocolMinter paths are
  role-gated (not part of this finding).

Code under test: KlimaDAO/protocol-v2-core, release **v1.0.0**, commit
`729cab2dac10d1f7c2c332d4b3bed32c5f88a160` (mirrors the deployed Base contracts).

## Replay

```bash
# 1. Klima v2 sources (the tests import them via the klima-src/ remapping)
git clone https://github.com/KlimaDAO/protocol-v2-core klima-v2
cd klima-v2 && git checkout v1.0.0 && git submodule update --init --recursive

# 2. This PoC package
cd /path/to/klima-h6-poc
ln -s /path/to/klima-v2/src klima-src
forge install foundry-rs/forge-std --no-git   # or clone into lib/forge-std
# openzeppelin-contracts, openzeppelin-contracts-upgradeable, prb-math and
# solmate are expected under lib/ — the klima-v2 repo's own lib/ checkouts
# satisfy the last three; symlink or copy them in:
#   lib/openzeppelin-contracts-upgradeable -> klima-v2/lib/openzeppelin-contracts-upgradeable
#   lib/prb-math                           -> klima-v2/lib/prb-math
#   lib/solmate                            -> klima-v2/lib/solmate
#   lib/openzeppelin-contracts             -> a plain openzeppelin-contracts checkout

# 3. Run against a pinned Base mainnet fork
forge test --fork-url <BASE_MAINNET_RPC> --fork-block-number 56549628 -vv
```

Original run: 12 Nov 2026, Base fork block ≈ 56,503,xxx, 4 passed / 0 failed
(full log in `evidence.log`). The suite warps to the next midnight index and
seeds its own forward tonnes, so it reproduces at any recent fork block while
live forward tonnage is 0. No mainnet transactions were sent during testing.
