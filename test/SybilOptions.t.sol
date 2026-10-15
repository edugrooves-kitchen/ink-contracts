// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {MainnetForkSetup} from "./MainnetFork.t.sol";

/// @notice Compares the first-hour launch guards against a sybil swarm, on a mainnet fork.
/// Each scenario deploys the whole stack with one guard setting, releases, lets one real seat holder make
/// the first buy, then sends 600 fresh wallets each trying to buy three portraits' worth of INK (the
/// launch cap). Afterwards, once the launch hour is over, a single whale spends 4,000 IMD.
///   FORK_RPC_URL=https://ethereum-rpc.publicnode.com forge test --mc Sybil -vv
/// @notice Compares where the released INK starts against a sybil swarm, on a mainnet fork.
/// Each scenario deploys the whole stack with one start price, releases, lets one real seat holder make
/// the first buy, then sends 600 fresh wallets each buying three portraits' worth of INK. Afterwards, an
/// hour later, a single whale spends 4,000 IMD. The launch uses 5x (InkSteps.RELEASE_PREMIUM).
///   FORK_RPC_URL=https://ethereum-rpc.publicnode.com forge test --mc Sybil -vv
abstract contract SybilScenario is MainnetForkSetup {
    uint256 constant BOTS = 600;
    uint256 constant WHALE_IMD = 4_000e18;

    function _inkAddress() internal pure override returns (address) {
        return address(0x00000000000000000000000000000000000111Aa);
    }

    function _name() internal pure virtual returns (string memory);

    function botBuy(address w, uint128 amount) external {
        require(msg.sender == address(this));
        _swapExactOut(w, true, amount);
    }

    function test_fork_sybilScenario() public onlyFork {
        (address holder,) = _claimReal(0);
        _release();
        vm.roll(block.number + 1);
        deal(address(IMD), holder, 1_000e18);
        _approveRouter(holder);
        _swapExactOut(holder, true, uint128(PORTRAIT)); // the first trade: a real seat holder buys one portrait
        uint256 openPrice = _imdPerPortrait();

        uint256 imdSpent;
        uint256 inkTaken;
        uint256 blocked;
        for (uint256 i; i < BOTS; i++) {
            address w = address(uint160(uint256(keccak256(abi.encode("sybil", i)))));
            deal(address(IMD), w, 1_000_000e18);
            _approveRouter(w);
            try this.botBuy(w, uint128(3 * PORTRAIT)) {
                imdSpent += 1_000_000e18 - IMD.balanceOf(w);
                inkTaken += ink.balanceOf(w);
            } catch {
                blocked++;
            }
        }
        (uint256 feeImd,) = hook.collectFees();

        console2.log("==== scenario:", _name());
        console2.log("  bots blocked:", blocked);
        console2.log("  bots' share of supply (bps):", inkTaken * 10_000 / SUPPLY);
        console2.log("  bots' IMD spent:", imdSpent / 1e18);
        if (inkTaken > 0) console2.log("  bots' avg milli-IMD per portrait:", imdSpent * 1000 / (inkTaken / PORTRAIT) / 1e18);
        console2.log("  hook fee to treasury (IMD):", feeImd / 1e18);
        console2.log("  price before / after bots (milli-IMD per portrait):", openPrice, _imdPerPortrait());

        // An hour later: one whale.
        vm.warp(uint256(hook.tradingOpenedAt()) + 1 hours + 1);
        address whale = makeAddr("whale");
        deal(address(IMD), whale, WHALE_IMD);
        _approveRouter(whale);
        _swapExactIn(whale, true, uint128(WHALE_IMD));
        console2.log("  whale an hour later, share for 4,000 IMD (bps):", ink.balanceOf(whale) * 10_000 / SUPPLY);
        console2.log("  price after whale (milli-IMD per portrait):", _imdPerPortrait());
    }
}

contract SybilPremium1xTest is SybilScenario {
    function _name() internal pure override returns (string memory) {
        return "released INK starts at the opening price";
    }

    function _premium() internal pure override returns (int24) {
        return 0;
    }
}

contract SybilPremium2xTest is SybilScenario {
    function _name() internal pure override returns (string memory) {
        return "released INK starts at 2x";
    }

    function _premium() internal pure override returns (int24) {
        return 7_000;
    }
}

contract SybilPremium5xTest is SybilScenario {
    function _name() internal pure override returns (string memory) {
        return "released INK starts at 5x (the launch setting)";
    }

    function _premium() internal pure override returns (int24) {
        return 16_000;
    }
}
