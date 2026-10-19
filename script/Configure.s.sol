// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkHook} from "../src/InkHook.sol";
import {InkLiquidity} from "../src/InkLiquidity.sol";
import {InkRenderer} from "../src/InkRenderer.sol";
import {InkSteps} from "./InkSteps.sol";

/// @notice Launch step 2, for the owner after the contracts launch: checks what the swarm deployed, then
/// setVault, setRenderer and the art upload. Rehearsed by script/Rehearse.s.sol.
///   PORTRAITS=… VAULT=… LIQUIDITY=… RENDERER=… OWNER=… \
///   forge script script/Configure.s.sol:ConfigureNft --rpc-url $RPC   # simulate first, add --broadcast to send
contract ConfigureNft is InkSteps {
    function run() external {
        InkPortraits portraits = InkPortraits(vm.envAddress("PORTRAITS"));
        InkVault vault = InkVault(vm.envAddress("VAULT"));
        InkLiquidity liq = InkLiquidity(vm.envAddress("LIQUIDITY"));
        InkRenderer renderer = InkRenderer(vm.envAddress("RENDERER"));
        address owner = vm.envAddress("OWNER");
        checkContractsLaunch(portraits, vault, liq, renderer, owner);
        vm.startBroadcast(owner);
        stepConfigureNft(portraits, vault, renderer);
        vm.stopBroadcast();
        console2.log("Chunks uploaded:", renderer.chunkCount());
        console2.log("Next: check a few tokenURIs, then InkRenderer.lock() and InkPortraits.lockRenderer().");
    }
}

/// @notice Launch step 4, for the owner after the hook launch: checks the hook, pool and vault balance, then
/// setInk, setPool and setup. CLAIM_START (a unix time within 30 days) defaults to the owner's schedule in InkSteps.
///   … HOOK=… INK=… TREASURY=… POOL_FEE=12500 TICK_SPACING=200 ROOT=0x… [CLAIM_START=…] \
///   forge script script/Configure.s.sol:OpenClaims --rpc-url $RPC   # simulate first, add --broadcast to send
contract OpenClaims is InkSteps {
    function run() external {
        InkPortraits portraits = InkPortraits(vm.envAddress("PORTRAITS"));
        InkVault vault = InkVault(vm.envAddress("VAULT"));
        InkLiquidity liq = InkLiquidity(vm.envAddress("LIQUIDITY"));
        InkHook hook = InkHook(vm.envAddress("HOOK"));
        IERC20 ink = IERC20(vm.envAddress("INK"));
        address owner = vm.envAddress("OWNER");
        bool inkIs0 = address(ink) < IMD;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(inkIs0 ? address(ink) : IMD),
            currency1: Currency.wrap(inkIs0 ? IMD : address(ink)),
            fee: uint24(vm.envUint("POOL_FEE")),
            tickSpacing: int24(int256(vm.envUint("TICK_SPACING"))),
            hooks: IHooks(address(hook))
        });
        checkHookLaunch(hook, portraits, vault, TREASURY, ink, key);
        vm.startBroadcast(owner);
        stepOpenClaims(vault, liq, ink, key, vm.envBytes32("ROOT"), uint64(vm.envOr("CLAIM_START", uint256(CLAIM_START))));
        vm.stopBroadcast();
        console2.log("Claims open at", vault.claimStart(), "and close at", vault.claimEnd());
    }
}
