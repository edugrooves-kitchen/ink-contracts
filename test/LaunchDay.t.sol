// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MainnetForkSetup} from "./MainnetFork.t.sol";
import {InkHook} from "../src/InkHook.sol";
import {InkVault} from "../src/InkVault.sol";

/// @notice Launch-day rehearsal on a mainnet fork: claim window, release, the first hour, pulls, rerolls,
/// trait rerolls, an agent deposit, a whale, then six days of ordinary trading with a daily fee collection. Every phase
/// checks the vault's backing, custody and the 2,000 cap, and logs the state the owner would watch.
/// Released INK starts at the launch setting (5x); PREMIUM_TICKS overrides it to try another:
///   FORK_RPC_URL=https://ethereum-rpc.publicnode.com forge test --mc LaunchDay -vv
///   PREMIUM_TICKS=0 FORK_RPC_URL=… forge test --mc LaunchDay -vv
contract LaunchDayTest is MainnetForkSetup {
    uint256 constant FANS = 40;
    uint256 constant REROLLS = 10;

    address keeper = makeAddr("keeper");
    address whale = makeAddr("whale");
    address[] fans;
    address[] holders;
    uint256 imdSpent;
    uint256 imdReceived;
    uint256 treasuryImd;
    uint256 inkBurned;

    function _inkAddress() internal pure override returns (address) {
        return address(0x00000000000000000000000000000000000111Aa);
    }

    function _premium() internal view override returns (int24) {
        return int24(int256(vm.envOr("PREMIUM_TICKS", uint256(16_000))));
    }

    /// For expectRevert around swaps the hook refuses.
    function buyExactOut(address who, uint128 amount) external {
        require(msg.sender == address(this));
        _swapExactOut(who, true, amount);
    }

    function test_fork_launchDay() public onlyFork {
        console2.log("Released INK starts above the opening price by (ticks):", uint256(int256(_premium())));

        // ---- Claim window: real seat owners claim; the pool is shut.
        for (uint256 i; i < 4; i++) {
            (address h,) = _claimReal(i);
            holders.push(h);
            deal(address(IMD), h, 2_000e18);
            _approveRouter(h);
        }
        for (uint256 i; i < FANS; i++) {
            address f = makeAddr(string.concat("fan-", vm.toString(i)));
            fans.push(f);
            deal(address(IMD), f, 2_000e18);
            _approveRouter(f);
        }
        deal(address(IMD), whale, 20_000e18);
        _approveRouter(whale);
        vm.expectRevert();
        this.buyExactOut(fans[0], uint128(PORTRAIT));
        _report("claim window (shut)");

        // ---- Release after 24 hours; the first holder buy opens trading.
        _release();
        vm.roll(block.number + 1);
        _buy(holders[0], PORTRAIT);
        uint256 openPrice = _imdPerPortrait();
        _report("release + first trade");

        // ---- First hour: each fan buys one portrait.
        for (uint256 i; i < FANS; i++) _buy(fans[i], PORTRAIT);
        _report("first hour: 40 fans bought");

        // ---- Pulls, revealed by a keeper two blocks later.
        _pullAll(fans);
        _assertFansHoldOne();
        _report("40 pulls revealed");

        // ---- Rerolls: ten fans hand theirs back (1% fee to the bonus pot) and pull again.
        for (uint256 i; i < REROLLS; i++) _deposit(fans[i], _tokenOf(fans[i]), PORTRAIT * 99 / 100);
        assertEq(vault.bonusPot(), REROLLS * PORTRAIT / 100, "reroll fees fill the pot");
        address[] memory again = new address[](REROLLS);
        for (uint256 i; i < REROLLS; i++) {
            again[i] = fans[i];
            _buy(fans[i], PORTRAIT / 100); // top up the fee
        }
        vm.roll(block.number + 1);
        _pullAll(again);
        _report("10 rerolls");

        // ---- Trait rerolls: five fans repaint the swarm portrait they hold (same token, new seed).
        for (uint256 i = REROLLS; i < REROLLS + 5; i++) {
            uint256 t = _tokenOf(fans[i]);
            _buy(fans[i], PORTRAIT / 100);
            bytes32 before = portraits.swarmSeed(t);
            vm.prank(fans[i]);
            vault.rerollTraits(t, PORTRAIT / 100);
            uint256 bn = block.number;
            vm.roll(bn + 2);
            vm.setBlockhash(bn + 1, keccak256(abi.encode("trait entropy", t)));
            vm.prank(keeper);
            assertTrue(vault.revealTraits(t));
            assertTrue(portraits.swarmSeed(t) != before, "repainted");
            assertEq(portraits.ownerOf(t), fans[i]);
        }
        _report("5 trait rerolls");

        // ---- An agent holder hands in their portrait for 400k + bonus (5%, capped by the pot).
        uint256 pot = vault.bonusPot();
        uint256 bonus = pot < PORTRAIT * 5 / 100 ? pot : PORTRAIT * 5 / 100;
        uint256 got = _deposit(holders[1], _seatOf(1), PORTRAIT + bonus);
        assertEq(got, PORTRAIT + bonus, "agent bonus paid");
        _report("agent deposit with bonus");

        // ---- An hour in: a whale buys, some fans sell their INK.
        vm.warp(block.timestamp + 1 hours);
        uint256 whaleImd = 5_000e18;
        _buyExactIn(whale, whaleImd);
        for (uint256 i; i < 5; i++) _sell(fans[i], ink.balanceOf(fans[i]));
        _collect();
        _report("hour 2: whale + 5 sellers");

        // ---- Six ordinary days: buys, pulls, rerolls, sells; fees collected daily.
        for (uint256 d = 1; d <= 6; d++) {
            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 7200);
            for (uint256 j; j < 4; j++) _buy(fans[10 + (d * 4 + j) % 30], PORTRAIT);
            address[] memory batch = new address[](2);
            batch[0] = fans[10 + (d * 4) % 30];
            batch[1] = fans[10 + (d * 4 + 1) % 30];
            _pullAll(batch);
            uint256 t = _tokenOf(batch[0]);
            if (t != type(uint256).max) _deposit(batch[0], t, 0);
            _sell(fans[10 + (d * 4 + 2) % 30], PORTRAIT / 2);
            _sell(whale, ink.balanceOf(whale) / 10);
            _collect();
            _report(string.concat("day ", vm.toString(d + 1)));
        }

        // ---- Summary.
        console2.log("--------");
        console2.log("Opening price, IMD per portrait (x1000):", openPrice);
        console2.log("Final price,   IMD per portrait (x1000):", _imdPerPortrait());
        console2.log("IMD paid in by buyers / out to sellers:", imdSpent / 1e18, imdReceived / 1e18);
        console2.log("Hook fees: IMD to treasury / INK burned:", treasuryImd / 1e15, inkBurned / 1e18);
        console2.log("  (IMD in thousandths)");
        console2.log("Portraits out / swarm minted / in vault:", portraits.totalSupply() - vault.heldCount(), portraits.swarmMinted(), vault.heldCount());
        assertGt(treasuryImd, 0);
        assertGt(_imdPerPortrait(), openPrice, "net buying moved the price up");
    }

    // ---------------------------------------------------------------- actions

    function _buy(address who, uint256 inkOut) internal {
        uint256 b = IMD.balanceOf(who);
        _swapExactOut(who, true, uint128(inkOut));
        imdSpent += b - IMD.balanceOf(who);
    }

    function _buyExactIn(address who, uint256 imdIn) internal {
        _swapExactIn(who, true, uint128(imdIn));
        imdSpent += imdIn;
    }

    function _sell(address who, uint256 inkIn) internal {
        if (inkIn == 0) return;
        uint256 b = IMD.balanceOf(who);
        _swapExactIn(who, false, uint128(inkIn));
        imdReceived += IMD.balanceOf(who) - b;
    }

    function _pullAll(address[] memory who) internal {
        uint256 first = vault.pullCount();
        for (uint256 i; i < who.length; i++) {
            vm.startPrank(who[i]);
            ink.approve(address(vault), type(uint256).max);
            vault.pull(1);
            vm.stopPrank();
        }
        (, uint64 bn,) = vault.pulls(first);
        vm.roll(uint256(bn) + 2);
        vm.setBlockhash(uint256(bn) + 1, keccak256(abi.encode("launch-day entropy", bn)));
        vm.prank(keeper);
        assertEq(vault.revealNext(who.length), who.length, "keeper reveals the whole batch");
        vm.roll(block.number + 1);
    }

    function _deposit(address who, uint256 tokenId, uint256 minOut) internal returns (uint256 got) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.startPrank(who);
        portraits.approve(address(vault), tokenId);
        got = vault.deposit(ids, minOut);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _collect() internal {
        uint256 dead = ink.balanceOf(DEAD);
        (uint256 imdPaid, uint256 burned) = hook.collectFees();
        treasuryImd += imdPaid;
        inkBurned += burned;
        assertEq(ink.balanceOf(DEAD) - dead, burned, "INK fees burned");
    }

    // ---------------------------------------------------------------- reads

    function _seatOf(uint256 i) internal view returns (uint256) {
        return vm.parseJsonUint(json, string.concat(".entries[", vm.toString(i), "].seat"));
    }

    /// The first portrait `who` holds (swarm ids from 10,000, or a fixture seat), or max if none.
    function _tokenOf(address who) internal view returns (uint256) {
        uint256 n = portraits.swarmMinted();
        for (uint256 id = 10_000; id < 10_000 + n; id++) {
            if (portraits.ownerOf(id) == who) return id;
        }
        for (uint256 i; i < 4; i++) {
            uint256 s = _seatOf(i);
            if (portraits.ownerOf(s) == who) return s;
        }
        return type(uint256).max;
    }

    function _assertFansHoldOne() internal view {
        for (uint256 i; i < FANS; i++) assertEq(portraits.balanceOf(fans[i]), 1, "each pull landed");
    }

    function _report(string memory phase) internal view {
        // The same checks as the invariant suite, on the real v4 stack.
        uint256 bal = ink.balanceOf(address(vault));
        if (vault.released()) {
            uint256 outside = portraits.totalSupply() - vault.heldCount();
            uint256 queued = vault.pullCount() - vault.nextReveal();
            assertEq(bal, (outside + queued) * PORTRAIT + vault.bonusPot(), "vault fully backed");
            assertEq(portraits.agentMinted() + vault.swarmSlots(), 2000, "2,000 portraits");
        } else {
            assertEq(bal, 2000 * PORTRAIT, "vault holds every seat's INK");
        }
        assertEq(portraits.balanceOf(address(vault)), vault.heldCount(), "custody");
        assertLe(portraits.totalSupply(), 2000);

        console2.log(string.concat("[", phase, "]"));
        console2.log(
            string.concat(
                "  IMD/portrait x1000 ",
                vm.toString(_imdPerPortrait()),
                " | portraits out ",
                vm.toString(portraits.totalSupply() - vault.heldCount()),
                " | pot INK ",
                vm.toString(vault.bonusPot() / 1e18),
                " | IMD in ",
                vm.toString(imdSpent / 1e18)
            )
        );
    }
}
