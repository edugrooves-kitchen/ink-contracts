// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkHook, IAgentPortraits, IInkVault} from "../src/InkHook.sol";
import {InkLiquidity} from "../src/InkLiquidity.sol";
import {InkRenderer} from "../src/InkRenderer.sol";

/// A contract wallet with no onERC721Received.
contract NoReceiver {}

contract MockSeats is ERC721("identity.md", "IMD-ID") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @notice Simulates the IMD swarm's univ4_hook launch: a plain 1B token, 10% to the swarm, 80% (a full
/// 400,000-INK portrait for each of 2,000 seats) to the vault, 10% seeded single-sided into an INK/IMD pool
/// with a 1.25% fee. The pool stays locked until the vault releases the unclaimed INK.
contract InkSystemTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant PORTRAIT = 400_000e18;
    uint24 constant POOL_FEE = 12_500; // IMD launch policy: 1.25%
    int24 constant SPACING = 200;
    int24 constant OPEN_TICK = 129_000; // ~400,000 INK per IMD: the 2,500 IMD market cap IMD launches open at
    int24 constant RANGE = 46_000;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address swarm = makeAddr("swarm");
    address agentA = makeAddr("agentA"); // seat 280, busy agent
    address agentB = makeAddr("agentB"); // seat 7
    address idle = makeAddr("idle"); // seat 1, never worked
    address buyer = makeAddr("buyer");
    address other = makeAddr("other");

    MockSeats seats;
    MockERC20 imd;
    MockERC20 ink;
    InkPortraits portraits;
    InkVault vault;
    InkHook hook;
    InkLiquidity liq;
    IPositionManager posm;
    PoolKey poolKey;
    bool inkIs0;

    InkPortraits.AgentStats statsA = InkPortraits.AgentStats(3351, 9860, 12000, 461, false);
    InkPortraits.AgentStats statsB = InkPortraits.AgentStats(40, 9000, 300, 20, true);
    InkPortraits.AgentStats statsIdle = InkPortraits.AgentStats(0, 0, 0, 0, false);
    bytes32[4] leaves;
    bytes32 root;

    function _leaf(uint256 seat, InkPortraits.AgentStats memory s) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(keccak256(abi.encode(seat, s.accepted, s.rateBps, s.turns, s.hoursTenths, s.outdated)))
        );
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// Proof for leaf i in a 4-leaf tree.
    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaves[i ^ 1];
        p[1] = i < 2 ? _pair(leaves[2], leaves[3]) : _pair(leaves[0], leaves[1]);
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        seats = new MockSeats();
        seats.mint(agentA, 280);
        seats.mint(agentB, 7);
        seats.mint(idle, 1);
        imd = new MockERC20("Identity.md", "IMD", 18);

        // 1. Contracts launch: NFT, vault and liquidity contract, owned by the owner wallet.
        portraits = new InkPortraits(owner);
        vault = new InkVault(portraits, seats, owner);
        posm = IPositionManager(
            address(
                new PositionManager(
                    manager, IAllowanceTransfer(deployPermit2()), 100_000, IPositionDescriptor(address(0)), IWETH9(address(0))
                )
            )
        );
        liq = new InkLiquidity(manager, posm, owner);
        vm.prank(owner);
        portraits.setVault(address(vault));

        // 2. Hook launch: hook, token and single-sided pool.
        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "InkHook.sol:InkHook",
            abi.encode(
                manager,
                IAgentPortraits(address(portraits)),
                IInkVault(address(vault)),
                Currency.wrap(address(imd)),
                treasury,
                uint16(25)
            ),
            hookAddr
        );
        hook = InkHook(hookAddr);

        ink = new MockERC20("INK", "INK", 18);
        ink.mint(address(this), SUPPLY);
        ink.transfer(swarm, SUPPLY / 10);
        ink.transfer(address(vault), 2000 * PORTRAIT);
        uint256 poolInk = SUPPLY - SUPPLY / 10 - 2000 * PORTRAIT;

        inkIs0 = address(ink) < address(imd);
        poolKey = PoolKey({
            currency0: Currency.wrap(inkIs0 ? address(ink) : address(imd)),
            currency1: Currency.wrap(inkIs0 ? address(imd) : address(ink)),
            fee: POOL_FEE,
            tickSpacing: SPACING,
            hooks: IHooks(hookAddr)
        });
        int24 openTick = inkIs0 ? -OPEN_TICK : OPEN_TICK;
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(openTick));
        (int24 lower, int24 upper) = inkIs0 ? (openTick, openTick + RANGE) : (openTick - RANGE, openTick);
        uint128 l = inkIs0
            ? LiquidityAmounts.getLiquidityForAmount0(TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), poolInk)
            : LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), poolInk);
        ink.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(poolKey, ModifyLiquidityParams(lower, upper, int256(uint256(l)), bytes32(0)), "");

        // 3. Owner wires INK in and opens the 24-hour claim window.
        leaves[0] = _leaf(280, statsA);
        leaves[1] = _leaf(7, statsB);
        leaves[2] = _leaf(1, statsIdle);
        leaves[3] = _leaf(99, statsIdle);
        root = _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
        vm.startPrank(owner);
        vault.setInk(IERC20(address(ink)));
        liq.setPool(poolKey, IERC20(address(ink)));
        vault.setup(root, uint64(block.timestamp), address(liq));
        vm.stopPrank();

        imd.mint(buyer, 100_000e18);
        imd.mint(other, 100_000e18);
        imd.mint(agentA, 100_000e18);
    }

    // ---------------------------------------------------------------- helpers

    function _swap(address who, bool buyInk, uint256 exactOut, bool expectRevert) internal {
        vm.startPrank(who, who);
        imd.approve(address(swapRouter), type(uint256).max);
        ink.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = buyInk ? !inkIs0 : inkIs0;
        if (expectRevert) vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(exactOut), // exact output: the hook fee comes from what's paid in
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function _buyInk(address who, uint256 inkOut) internal {
        _swap(who, true, inkOut, false);
    }

    function _claimA() internal {
        vm.prank(agentA);
        vault.claim(280, statsA, _proof(0));
    }

    /// The 24 hours pass and the unclaimed INK goes into the pool, which opens trading.
    function _release() internal {
        vm.warp(vault.claimEnd());
        vault.release();
    }

    /// Release, then a first small trade.
    function _releaseAndTrade() internal {
        _release();
        _buyInk(buyer, 1e18);
    }

    function _pullAndReveal(address who) internal returns (uint256 tokenId) {
        vm.startPrank(who);
        ink.approve(address(vault), type(uint256).max);
        uint256 pullId = vault.pull(1);
        vm.stopPrank();
        vm.roll(block.number + 2);
        assertTrue(vault.reveal(pullId));
        for (uint256 id = 10_000; id < 10_000 + portraits.swarmMinted(); id++) {
            if (portraits.ownerOf(id) == who) tokenId = id;
        }
    }

    function _deposit(address who, uint256 tokenId) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.startPrank(who);
        portraits.approve(address(vault), tokenId);
        vault.deposit(ids, 0);
        vm.stopPrank();
        vm.roll(block.number + 1); // it joins the draw for pulls from the next block on
    }

    function _pull(address who, uint256 count) internal returns (uint256 pullId) {
        vm.startPrank(who);
        ink.approve(address(vault), type(uint256).max);
        pullId = vault.pull(count);
        vm.stopPrank();
    }

    function _depositNoRoll(address who, uint256 tokenId) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.startPrank(who);
        portraits.approve(address(vault), tokenId);
        vault.deposit(ids, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- launch, setup, ownership

    function test_launchSplit() public view {
        assertEq(ink.totalSupply(), SUPPLY);
        assertEq(ink.balanceOf(swarm), SUPPLY / 10, "10% to the swarm");
        assertEq(ink.balanceOf(address(vault)), 2000 * PORTRAIT, "a full portrait for each of 2,000 seats");
        assertEq(ink.balanceOf(owner), 0, "owner holds no INK");
        assertEq(vault.claimEnd(), block.timestamp + 24 hours);
        assertEq(vault.swarmSlots(), 0, "no swarm slots during the window");
        assertFalse(hook.tradingOpen(), "the pool starts locked");
    }

    function test_ownerIsOwnerWalletNotDeployer() public {
        address swarmDeployer = makeAddr("swarmDeployer");
        vm.startPrank(swarmDeployer);
        InkPortraits p = new InkPortraits(owner);
        InkVault v = new InkVault(p, seats, owner);
        InkLiquidity l = new InkLiquidity(manager, posm, owner);
        vm.stopPrank();
        assertEq(p.owner(), owner);
        assertEq(v.owner(), owner);
        assertEq(l.owner(), owner);
        (address royaltyTo, uint256 royalty) = p.royaltyInfo(1, 10_000);
        assertEq(royaltyTo, owner, "royalty info names the owner wallet");
        assertEq(royalty, 0, "0% trading fee");

        vm.prank(swarmDeployer);
        vm.expectRevert();
        p.setVault(address(v));

        assertEq(hook.treasury(), treasury);
        (bool ok,) = address(hook).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "the hook has no owner function");
    }

    function test_setupRules() public {
        vm.startPrank(owner);
        vm.expectRevert(InkVault.AlreadySetUp.selector);
        vault.setup(root, 0, address(liq));
        vm.expectRevert(InkVault.InkAlreadySet.selector);
        vault.setInk(IERC20(address(imd)));
        vm.stopPrank();

        InkVault empty = new InkVault(portraits, seats, owner);
        vm.startPrank(owner);
        empty.setInk(IERC20(address(ink)));
        vm.expectRevert(InkVault.NotFunded.selector);
        empty.setup(root, uint64(block.timestamp), address(liq));
        vm.stopPrank();
    }

    /// Audit #7: a typo'd start (e.g. milliseconds) used to freeze the 800M INK for centuries.
    function test_setupStartMustBeSoon() public {
        vm.warp(1_760_000_000);
        InkVault v = new InkVault(portraits, seats, owner);
        ink.mint(address(v), 2000 * PORTRAIT);
        vm.startPrank(owner);
        v.setInk(IERC20(address(ink)));
        vm.expectRevert(InkVault.BadSetup.selector);
        v.setup(root, uint64(block.timestamp * 1000), address(liq));
        vm.expectRevert(InkVault.BadSetup.selector);
        v.setup(root, uint64(block.timestamp - 1), address(liq));
        v.setup(root, uint64(block.timestamp + 30 days), address(liq));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- the locked pool

    function test_poolLockedUntilRelease() public {
        _swap(buyer, true, PORTRAIT, true); // nobody can buy during the window
        _swap(agentA, true, PORTRAIT, true); // seat holders neither

        vm.warp(vault.claimEnd());
        _swap(buyer, true, PORTRAIT, true); // the 24 hours alone don't open it

        vault.release();
        assertTrue(hook.tradingOpen());
        _buyInk(buyer, PORTRAIT);
        assertEq(ink.balanceOf(buyer), PORTRAIT);
    }

    /// Owner decision after the audit: no time-based fallback. However long release takes, nobody can trade
    /// before it, so nothing can move the price the released INK is listed at.
    function test_poolNeverOpensWithoutRelease() public {
        vm.warp(vault.claimEnd() + 365 days);
        assertFalse(hook.tradingOpen());
        _swap(buyer, true, PORTRAIT, true);
        _swap(swarm, false, 1e18, true); // no dust sells either
        vault.release();
        assertTrue(hook.tradingOpen());
        _buyInk(buyer, PORTRAIT);
        assertEq(ink.balanceOf(buyer), PORTRAIT);
    }

    /// Defense in depth: InkLiquidity never lists INK below the price at setPool, even if the price has been
    /// dragged to the extreme. Shown on a pool without the hook, where swaps are possible before liquidity.
    function test_liquidityFloorHoldsIfPriceIsDragged() public {
        PoolKey memory k = poolKey;
        k.hooks = IHooks(address(0));
        int24 openTick = inkIs0 ? -OPEN_TICK : OPEN_TICK;
        manager.initialize(k, TickMath.getSqrtPriceAtTick(openTick));
        (int24 lower, int24 upper) = inkIs0 ? (openTick, openTick + RANGE) : (openTick - RANGE, openTick);
        ink.mint(address(this), 2_000_000e18);
        uint128 l = inkIs0
            ? LiquidityAmounts.getLiquidityForAmount0(TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), 1_000_000e18)
            : LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), 1_000_000e18);
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(lower, upper, int256(uint256(l)), bytes32(0)), "");
        InkLiquidity l2 = new InkLiquidity(manager, posm, owner);
        vm.prank(owner);
        l2.setPool(k, IERC20(address(ink)));

        // A 1-INK sell crosses the empty side for free and drags the price to the extreme.
        ink.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            k,
            SwapParams({zeroForOne: inkIs0, amountSpecified: -1e18, sqrtPriceLimitX96: inkIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (, int24 dragged,,) = manager.getSlot0(k.toId());
        assertTrue(inkIs0 ? dragged < openTick - 100_000 : dragged > openTick + 100_000, "dragged for free");

        ink.transfer(address(l2), 1_000_000e18);
        l2.addLiquidity();
        (, PositionInfo info) = posm.getPoolAndPositionInfo(l2.positions(0));
        if (inkIs0) assertGe(info.tickLower(), openTick, "listed at or above the opening price");
        else assertLe(info.tickUpper(), openTick, "listed at or above the opening price");
    }

    // ---------------------------------------------------------------- 24-hour agent claims

    function test_agentClaimsOwnPortraitFree() public {
        uint256 inkBefore = ink.balanceOf(agentA);
        _claimA();
        assertEq(portraits.ownerOf(280), agentA);
        assertEq(portraits.agentBalanceOf(agentA), 1);
        assertEq(portraits.agentStats(280).accepted, 3351);
        assertEq(ink.balanceOf(agentA), inkBefore, "claiming costs nothing");
        assertFalse(portraits.isAgentHolder(agentA), "perks start from the next block");
        vm.roll(block.number + 1);
        assertTrue(portraits.isAgentHolder(agentA));
        assertEq(ink.balanceOf(address(vault)), 2000 * PORTRAIT, "the seat's INK stays as backing");
    }

    function test_idleSeatClaimsToo() public {
        vm.prank(idle);
        vault.claim(1, statsIdle, _proof(2));
        assertEq(portraits.ownerOf(1), idle);
        assertEq(portraits.agentStats(1).accepted, 0, "no work: it renders as a Sketch");
    }

    function test_claimRules() public {
        vm.prank(other);
        vm.expectRevert(InkVault.NotSeatOwner.selector);
        vault.claim(280, statsA, _proof(0));

        vm.prank(agentA);
        vm.expectRevert(InkVault.InvalidProof.selector);
        vault.claim(280, statsB, _proof(0));

        _claimA();
        vm.prank(agentA);
        vm.expectRevert();
        vault.claim(280, statsA, _proof(0)); // portrait 280 already exists

        vm.warp(vault.claimEnd());
        vm.prank(agentB);
        vm.expectRevert(InkVault.ClaimClosed.selector);
        vault.claim(7, statsB, _proof(1));
    }

    /// Audit #6: a seat held by a contract without onERC721Received couldn't claim.
    function test_contractWalletSeatCanClaim() public {
        NoReceiver wallet = new NoReceiver();
        vm.prank(agentA);
        seats.transferFrom(agentA, address(wallet), 280);
        vm.prank(address(wallet));
        vault.claim(280, statsA, _proof(0));
        assertEq(portraits.ownerOf(280), address(wallet));
    }

    function test_seatSoldDuringWindowNewOwnerClaims() public {
        vm.prank(agentA);
        seats.transferFrom(agentA, other, 280);
        vm.prank(other);
        vault.claim(280, statsA, _proof(0));
        assertEq(portraits.ownerOf(280), other);
    }

    // ---------------------------------------------------------------- after 24 hours

    function test_releaseTurnsUnclaimedSeatsIntoSlotsAndPoolInk() public {
        _claimA();
        vm.warp(vault.claimEnd());
        uint256 toPool = vault.release();
        assertEq(toPool, 1999 * PORTRAIT, "every unclaimed seat's INK goes to the pool");
        assertEq(vault.swarmSlots(), 1999, "and becomes a swarm slot");
        assertEq(liq.positionCount(), 1, "added to the pool in the same transaction");
        assertLt(ink.balanceOf(address(liq)), 1e6);
        assertEq(ERC721(address(posm)).ownerOf(liq.positions(0)), address(liq), "and it stays there");
        assertEq(ink.balanceOf(address(vault)), PORTRAIT, "only the claimed portrait's backing is left");

        vm.expectRevert(InkVault.AlreadyReleased.selector);
        vault.release();
    }

    function test_noPullsUntilRelease() public {
        // The swarm's INK exists from launch, but nothing can be pulled during the window.
        vm.startPrank(swarm);
        ink.approve(address(vault), PORTRAIT);
        vm.expectRevert(InkVault.NotReleased.selector);
        vault.pull(1);
        vm.stopPrank();

        _release();
        uint256 pullId = _pull(swarm, 1);
        vm.roll(block.number + 2);
        vault.reveal(pullId);
        assertEq(portraits.swarmMinted(), 1);
    }

    function test_pullRerollPullAgain() public {
        _claimA();
        _releaseAndTrade();
        _buyInk(buyer, PORTRAIT);
        uint256 first = _pullAndReveal(buyer);
        assertEq(portraits.ownerOf(first), buyer);

        _deposit(buyer, first);
        assertEq(ink.balanceOf(buyer), PORTRAIT * 99 / 100 + 1e18, "1% reroll fee");
        _buyInk(buyer, PORTRAIT / 100);
        uint256 second = _pullAndReveal(buyer);
        assertEq(portraits.ownerOf(second), buyer);
    }

    function test_agentHoldersRerollForHalf() public {
        _claimA();
        vm.roll(block.number + 1);
        _releaseAndTrade();
        _buyInk(agentA, PORTRAIT);
        uint256 a = _pullAndReveal(agentA);
        uint256 potBefore = vault.bonusPot();
        _deposit(agentA, a);
        assertEq(vault.bonusPot() - potBefore, PORTRAIT / 200, "agent holder: 0.5%");

        _buyInk(buyer, PORTRAIT);
        uint256 b = _pullAndReveal(buyer);
        potBefore = vault.bonusPot();
        _deposit(buyer, b);
        assertEq(vault.bonusPot() - potBefore, PORTRAIT / 100, "everyone else: 1%");
    }

    // ---------------------------------------------------------------- trait rerolls

    function _rerollTraits(address who, uint256 tokenId) internal returns (uint256 fee) {
        vm.startPrank(who);
        ink.approve(address(vault), type(uint256).max);
        fee = vault.rerollTraits(tokenId, type(uint256).max);
        vm.stopPrank();
    }

    function test_traitRerollRepaintsSameToken() public {
        _releaseAndTrade();
        _buyInk(buyer, PORTRAIT + PORTRAIT / 100);
        uint256 t = _pullAndReveal(buyer);
        bytes32 oldSeed = portraits.swarmSeed(t);

        uint256 fee = _rerollTraits(buyer, t);
        assertEq(fee, PORTRAIT / 100, "1% for everyone else");
        assertEq(vault.bonusPot(), fee, "the fee goes into the bonus pot");
        vm.expectRevert(InkVault.TooEarly.selector);
        vault.revealTraits(t);

        vm.roll(block.number + 2);
        vm.expectEmit(address(portraits));
        emit InkPortraits.MetadataUpdate(t);
        vm.prank(other); // anyone can reveal
        assertTrue(vault.revealTraits(t));
        assertEq(portraits.ownerOf(t), buyer, "same token, same owner");
        assertTrue(portraits.swarmSeed(t) != oldSeed, "new seed, so new art and traits");
        assertEq(vault.traitRerollBlock(t), 0);
        // Backing still holds: one portrait outside, its 400k plus the pot.
        assertEq(ink.balanceOf(address(vault)), PORTRAIT + vault.bonusPot());
    }

    function test_traitRerollHalfPriceForAgentHolders() public {
        _claimA();
        vm.roll(block.number + 1);
        _releaseAndTrade();
        _buyInk(agentA, PORTRAIT + PORTRAIT / 200);
        uint256 t = _pullAndReveal(agentA);
        assertEq(_rerollTraits(agentA, t), PORTRAIT / 200, "0.5% for agent holders");
    }

    function test_traitRerollGuards() public {
        _claimA();
        _releaseAndTrade();
        _buyInk(buyer, PORTRAIT + PORTRAIT / 50);
        uint256 t = _pullAndReveal(buyer);

        vm.prank(agentA);
        vm.expectRevert(InkVault.AgentPortrait.selector);
        vault.rerollTraits(280, type(uint256).max);
        vm.prank(other);
        vm.expectRevert(InkVault.NotYourPortrait.selector);
        vault.rerollTraits(t, type(uint256).max);
        vm.prank(buyer);
        vm.expectRevert(InkVault.FeeTooHigh.selector);
        vault.rerollTraits(t, PORTRAIT / 100 - 1);
        vm.expectRevert(InkVault.NoRerollPending.selector);
        vault.revealTraits(t);

        _rerollTraits(buyer, t);
        vm.prank(buyer);
        vm.expectRevert(InkVault.RerollPending.selector);
        vault.rerollTraits(t, type(uint256).max);
        // Can't hand it in while the reroll is pending.
        uint256[] memory ids = new uint256[](1);
        ids[0] = t;
        vm.startPrank(buyer);
        portraits.approve(address(vault), t);
        vm.expectRevert(InkVault.RerollPending.selector);
        vault.deposit(ids, 0);
        vm.stopPrank();

        // Only the vault can set a seed, and never on an agent portrait.
        vm.expectRevert(InkPortraits.OnlyVault.selector);
        portraits.setSwarmSeed(t, bytes32(uint256(1)));
        vm.prank(address(vault));
        vm.expectRevert(InkPortraits.NotASwarmPortrait.selector);
        portraits.setSwarmSeed(280, bytes32(uint256(1)));
    }

    function test_traitRerollBeforeReleaseReverts() public {
        vm.prank(buyer);
        vm.expectRevert(InkVault.NotReleased.selector);
        vault.rerollTraits(10_000, type(uint256).max);
    }

    function test_traitRerollExpiredHashRenews() public {
        _releaseAndTrade();
        _buyInk(buyer, PORTRAIT + PORTRAIT / 100);
        uint256 t = _pullAndReveal(buyer);
        bytes32 oldSeed = portraits.swarmSeed(t);
        _rerollTraits(buyer, t);
        vm.roll(block.number + 300);
        assertFalse(vault.revealTraits(t), "renewed, not applied");
        assertEq(portraits.swarmSeed(t), oldSeed);
        assertEq(vault.traitRerollBlock(t), block.number);
        vm.roll(block.number + 2);
        assertTrue(vault.revealTraits(t));
        assertTrue(portraits.swarmSeed(t) != oldSeed);
    }

    function test_agentDepositsPortraitForBonus() public {
        _claimA();
        _releaseAndTrade();
        _buyInk(buyer, 2 * PORTRAIT);
        uint256 s1 = _pullAndReveal(buyer);
        _deposit(buyer, s1);
        _buyInk(buyer, PORTRAIT / 50);
        uint256 s2 = _pullAndReveal(buyer);
        _deposit(buyer, s2);
        assertEq(vault.bonusPot(), PORTRAIT / 50);

        uint256 before = ink.balanceOf(agentA);
        _deposit(agentA, 280);
        assertEq(ink.balanceOf(agentA) - before, PORTRAIT + PORTRAIT / 50, "full pot (under the 5% cap) as bonus");
        assertEq(vault.bonusPot(), 0);
        assertEq(portraits.ownerOf(280), address(vault), "the agent portrait is now in the pool");
    }

    function test_agentBonusCappedAtFivePercent() public {
        _claimA();
        _releaseAndTrade();
        _buyInk(buyer, PORTRAIT + PORTRAIT / 10);
        for (uint256 i; i < 10; i++) {
            uint256 t = _pullAndReveal(buyer);
            _deposit(buyer, t);
        }
        assertGt(vault.bonusPot(), PORTRAIT / 20);
        uint256 before = ink.balanceOf(agentA);
        _deposit(agentA, 280);
        assertEq(ink.balanceOf(agentA) - before, PORTRAIT + PORTRAIT / 20, "bonus capped at 5%");
    }

    function test_depositedAgentPortraitIsPullable() public {
        _claimA();
        _releaseAndTrade();
        _deposit(agentA, 280);
        assertEq(vault.waitingCount(), 1);

        // Pretend every swarm slot is already minted, so the only possible pick is seat 280's portrait.
        vm.mockCall(address(portraits), abi.encodeWithSignature("swarmMinted()"), abi.encode(vault.swarmSlots()));
        _buyInk(buyer, PORTRAIT);
        vm.startPrank(buyer);
        ink.approve(address(vault), PORTRAIT);
        uint256 pullId = vault.pull(1);
        vm.stopPrank();
        vm.roll(block.number + 2);
        vault.reveal(pullId);
        assertEq(portraits.ownerOf(280), buyer, "the pull hands out the agent portrait");
        assertEq(portraits.agentBalanceOf(buyer), 1, "and the puller now gets agent discounts");
    }

    function test_vaultStaysFullyBacked() public {
        _claimA();
        _releaseAndTrade();
        _buyInk(buyer, 2 * PORTRAIT);
        uint256 t = _pullAndReveal(buyer);
        _deposit(buyer, t);
        _deposit(agentA, 280);
        _pullAndReveal(buyer);
        uint256 outside = portraits.totalSupply() - vault.heldCount();
        assertEq(ink.balanceOf(address(vault)), outside * PORTRAIT + vault.bonusPot());
    }

    function test_revealIsNotEarlyAndNotTwice() public {
        _release();
        _buyInk(buyer, PORTRAIT);
        vm.startPrank(buyer);
        ink.approve(address(vault), PORTRAIT);
        uint256 pullId = vault.pull(1);
        vm.stopPrank();
        vm.expectRevert(InkVault.TooEarly.selector);
        vault.reveal(pullId);
        vm.roll(block.number + 1);
        vm.expectRevert(InkVault.TooEarly.selector);
        vault.reveal(pullId);
        vm.roll(block.number + 1);
        vault.reveal(pullId);
        vm.expectRevert(InkVault.AlreadyRevealed.selector);
        vault.reveal(pullId);
    }

    /// Audit #1: the same agent portrait could be deposited, pulled back and deposited again for a fresh
    /// 5% bonus each time, draining the pot.
    function test_agentBonusPaidOncePerPortrait() public {
        _claimA();
        _releaseAndTrade();
        _buyInk(buyer, 30 * PORTRAIT);
        for (uint256 i; i < 25; i++) {
            _deposit(buyer, _pullAndReveal(buyer)); // fill the pot with reroll fees
        }
        uint256 before = ink.balanceOf(agentA);
        _deposit(agentA, 280);
        assertEq(ink.balanceOf(agentA) - before, PORTRAIT + PORTRAIT / 20, "first deposit earns the bonus");
        assertTrue(vault.bonusPaid(280));

        // Every slot minted, so a pull can only land on what's in the vault. Keep pulling and handing back
        // until seat 280's portrait comes round again.
        vm.mockCall(address(portraits), abi.encodeWithSignature("swarmMinted()"), abi.encode(vault.swarmSlots()));
        ink.mint(agentA, 100 * PORTRAIT);
        uint256 again;
        for (uint256 i; i < 200 && again < 2; i++) {
            uint256 pullId = _pull(agentA, 1);
            vm.roll(block.number + 2);
            vault.reveal(pullId);
            if (portraits.ownerOf(280) == agentA) {
                uint256 pot = vault.bonusPot();
                before = ink.balanceOf(agentA);
                _deposit(agentA, 280);
                assertEq(ink.balanceOf(agentA) - before, PORTRAIT, "no second bonus");
                assertEq(vault.bonusPot(), pot, "the pot is untouched");
                again++;
            } else {
                _deposit(agentA, _swarmHeldBy(agentA));
            }
        }
        assertEq(again, 2, "seat 280's portrait came round twice");
    }

    function _swarmHeldBy(address who) internal view returns (uint256) {
        for (uint256 id = 10_000; id < 10_000 + 40; id++) {
            try portraits.ownerOf(id) returns (address o) {
                if (o == who) return id;
            } catch {}
        }
        revert("none");
    }

    /// Audit #3: a puller could see the block hash, then hand in portraits to change the draw's modulus
    /// and land an agent portrait. Now deposits only join for later pulls and reveals go in order.
    function test_depositAfterPullCannotSteerTheDraw() public {
        _claimA();
        _releaseAndTrade();
        _buyInk(buyer, 3 * PORTRAIT);
        uint256 s1 = _pullAndReveal(buyer);

        uint256 pullId = _pull(buyer, 1);
        uint256 availAtPull = vault.available();
        vm.roll(block.number + 2);
        // The hash is public now. Handing portraits in doesn't change what this pull can land on.
        _depositNoRoll(buyer, s1);
        vm.prank(agentA);
        portraits.approve(address(vault), 280);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 280;
        vm.prank(agentA);
        vault.deposit(ids, 0);
        assertEq(vault.available(), availAtPull, "deposits wait for later pulls");
        vault.reveal(pullId);
        assertEq(portraits.ownerOf(280), address(vault));
        assertEq(vault.waitingCount(), 2);
    }

    function test_revealsGoInOrder() public {
        _releaseAndTrade();
        _buyInk(buyer, 2 * PORTRAIT);
        uint256 first = _pull(buyer, 2);
        vm.roll(block.number + 2);
        assertTrue(vault.reveal(first + 1), "revealing a later pull reveals the earlier ones first");
        assertEq(vault.nextReveal(), first + 2);
        assertEq(portraits.balanceOf(buyer), 2);
    }

    function test_expiredPullIsRenewedNotSkipped() public {
        _releaseAndTrade();
        _buyInk(buyer, PORTRAIT);
        uint256 pullId = _pull(buyer, 1);
        vm.roll(block.number + 300);
        assertFalse(vault.reveal(pullId), "the hash is gone: renewed against a new block");
        vm.roll(block.number + 2);
        assertTrue(vault.reveal(pullId));
    }

    /// Audit #11: fees can change between signing and mining, so deposits take a minimum payout.
    function test_depositMinOut() public {
        _releaseAndTrade();
        _buyInk(buyer, PORTRAIT);
        uint256 t = _pullAndReveal(buyer);
        vm.prank(owner);
        vault.setFees(500, 500, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = t;
        vm.startPrank(buyer);
        portraits.approve(address(vault), t);
        vm.expectRevert(InkVault.BelowMinOut.selector);
        vault.deposit(ids, PORTRAIT * 99 / 100);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- hook fees

    function test_hookFeeImdToTreasury() public {
        _release();
        _buyInk(buyer, PORTRAIT);
        (uint256 imdPaid, uint256 inkBurned) = hook.collectFees();
        assertGt(imdPaid, 0);
        assertEq(inkBurned, 0);
        assertEq(imd.balanceOf(treasury), imdPaid);
    }

    function test_hookFeeInkIsBurned() public {
        _releaseAndTrade();
        _buyInk(buyer, 100 * PORTRAIT);
        _swap(buyer, false, 10e18, false); // sell INK for exactly 10 IMD
        (, uint256 inkBurned) = hook.collectFees();
        assertGt(inkBurned, 0);
        assertEq(ink.balanceOf(DEAD), inkBurned);
    }

    function test_agentHoldersPayNoHookFee() public {
        _claimA();
        vm.roll(block.number + 1);
        _release();
        _buyInk(agentA, PORTRAIT);
        (uint256 imdPaid,) = hook.collectFees();
        assertEq(imdPaid, 0);
        _buyInk(buyer, PORTRAIT);
        (imdPaid,) = hook.collectFees();
        assertGt(imdPaid, 0);
    }

    /// Audit #8: an agent portrait lent for one transaction used to waive the hook fee.
    function test_borrowedAgentPortraitGetsNoWaiver() public {
        _claimA();
        _release();
        vm.prank(agentA);
        portraits.transferFrom(agentA, buyer, 280);
        _buyInk(buyer, PORTRAIT);
        (uint256 imdPaid,) = hook.collectFees();
        assertGt(imdPaid, 0, "same block as receiving it: pays the fee");
    }

    /// Size limits: gas for big pulls and reveal batches, against a 36M-gas block.
    function test_gasAtScale() public {
        _releaseAndTrade();
        uint256[4] memory counts = [uint256(1), 10, 100, 400];
        address whale = makeAddr("whale");
        ink.mint(whale, 1000 * PORTRAIT);
        vm.prank(whale);
        ink.approve(address(vault), type(uint256).max);
        for (uint256 k; k < counts.length; k++) {
            uint256 n = counts[k];
            uint256 g = gasleft();
            vm.prank(whale);
            vault.pull(n);
            uint256 pullGas = g - gasleft();
            vm.roll(block.number + 2);
            g = gasleft();
            uint256 revealed = vault.revealNext(n);
            uint256 revealGas = g - gasleft();
            assertEq(revealed, n);
            emit log_named_uint(string.concat("pull(", vm.toString(n), ") gas"), pullGas);
            emit log_named_uint(string.concat("revealNext(", vm.toString(n), ") gas"), revealGas);
            emit log_named_uint("  per reveal", revealGas / n);
        }
        // Hand-backs in bulk.
        uint256[] memory ids = new uint256[](100);
        for (uint256 i; i < 100; i++) ids[i] = 10_000 + i;
        vm.startPrank(whale);
        portraits.setApprovalForAll(address(vault), true);
        uint256 g2 = gasleft();
        vault.deposit(ids, 0);
        emit log_named_uint("deposit(100 portraits) gas", g2 - gasleft());
        vm.stopPrank();
    }

    /// Every permission and argument guard, so none of them is untested code.
    function test_guards() public {
        // InkHook constructor and callbacks
        vm.expectRevert(InkHook.ZeroAddress.selector);
        new InkHook(manager, IAgentPortraits(address(portraits)), IInkVault(address(vault)), Currency.wrap(address(imd)), address(0), 25);
        vm.expectRevert(InkHook.FeeTooHigh.selector);
        new InkHook(manager, IAgentPortraits(address(portraits)), IInkVault(address(vault)), Currency.wrap(address(imd)), treasury, 101);
        vm.expectRevert(InkHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), poolKey, 0);
        vm.expectRevert(InkHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), poolKey, SwapParams(true, 1, 0), "");
        vm.expectRevert(InkHook.HookNotImplemented.selector);
        hook.afterInitialize(address(0), poolKey, 0, 0);

        // InkLiquidity
        vm.startPrank(owner);
        vm.expectRevert(InkLiquidity.PoolAlreadySet.selector);
        liq.setPool(poolKey, IERC20(address(ink)));
        InkLiquidity l2 = new InkLiquidity(manager, posm, owner);
        vm.expectRevert(InkLiquidity.NotInkPool.selector);
        l2.setPool(poolKey, IERC20(address(0xBEEF)));
        vm.expectRevert(InkLiquidity.BadWidth.selector);
        liq.setWidth(SPACING - 1);
        liq.setWidth(4 * SPACING);
        assertEq(liq.width(), 4 * SPACING);
        vm.stopPrank();
        vm.expectRevert(InkLiquidity.PoolNotSet.selector);
        l2.addLiquidity();
        vm.expectRevert(InkLiquidity.NothingToAdd.selector);
        liq.addLiquidity();
        vm.prank(other);
        vm.expectRevert();
        liq.setWidth(1000);

        // InkPortraits
        vm.expectRevert(InkPortraits.OnlyVault.selector);
        portraits.mintSwarm(other, bytes32(0));
        vm.prank(owner);
        vm.expectRevert(InkPortraits.VaultAlreadySet.selector);
        portraits.setVault(other);
        vm.prank(address(vault));
        vm.expectRevert(InkPortraits.NotASeat.selector);
        portraits.mintAgent(2000, other, statsIdle);
        InkRenderer r = new InkRenderer(portraits, owner);
        vm.startPrank(owner);
        portraits.setRenderer(address(r));
        portraits.lockRenderer();
        vm.expectRevert(InkPortraits.Locked.selector);
        portraits.setRenderer(other);
        vm.stopPrank();
        assertTrue(portraits.supportsInterface(0x49064906) && portraits.supportsInterface(0x2a55205a), "ERC-4906 + ERC-2981");

        // InkRenderer
        bytes memory big = new bytes(r.MAX_CHUNK() + 1);
        vm.startPrank(owner);
        vm.expectRevert(InkRenderer.ChunkTooLarge.selector);
        r.addChunk(big);
        r.addChunk("x");
        r.lock();
        vm.expectRevert(InkRenderer.IsLocked.selector);
        r.addChunk("y");
        vm.expectRevert(InkRenderer.IsLocked.selector);
        r.setPreviewBase("https://x/");
        vm.stopPrank();

        // InkVault
        InkVault v2 = new InkVault(portraits, seats, owner);
        vm.startPrank(owner);
        vm.expectRevert(InkVault.InkNotSet.selector);
        v2.setup(root, uint64(block.timestamp), address(liq));
        vm.expectRevert(InkVault.FeeTooHigh.selector);
        vault.setFees(501, 0, 0);
        vm.expectRevert(InkVault.FeeTooHigh.selector);
        vault.setFees(100, 101, 0);
        vm.expectRevert(InkVault.FeeTooHigh.selector);
        vault.setFees(100, 50, 1001);
        vm.stopPrank();
        vm.expectRevert(InkVault.InkNotSet.selector);
        v2.release();
        vm.expectRevert(InkVault.ClaimStillOpen.selector);
        vault.release();
        _release();
        vm.expectRevert(InkVault.ZeroPulls.selector);
        vault.pull(0);
        vm.expectRevert(InkVault.UnknownPull.selector);
        vault.reveal(0);
        assertEq(vault.inventorySize(), 0);
        assertEq(vault.onERC721Received(address(0), address(0), 0, ""), vault.onERC721Received.selector);
        assertEq(liq.onERC721Received(address(0), address(0), 0, ""), liq.onERC721Received.selector);

        // A swap too small to owe any hook fee still goes through, fee-free.
        _buyInk(buyer, 100);
        (uint256 imdPaid,) = hook.collectFees();
        assertEq(imdPaid, 0);
    }

    /// Static analysis: locking with nothing set would break metadata permanently, so it's refused.
    function test_cantLockAnEmptyRenderer() public {
        vm.prank(owner);
        vm.expectRevert(InkPortraits.NoRenderer.selector);
        portraits.lockRenderer();
        InkRenderer r = new InkRenderer(portraits, owner);
        vm.prank(owner);
        vm.expectRevert(InkRenderer.NoScript.selector);
        r.lock();
    }

    /// Resales carry no creator fee: ERC-2981 reports 0% for every token and sale price.
    function test_zeroTradingFee() public view {
        assertEq(portraits.ROYALTY_BPS(), 0);
        (, uint256 a) = portraits.royaltyInfo(1, 10_000);
        (, uint256 b) = portraits.royaltyInfo(portraits.SWARM_ID_OFFSET(), 1_000_000 ether);
        assertEq(a, 0);
        assertEq(b, 0);
    }

    function test_noPerWalletLimitAfterRelease() public {
        _release();
        _buyInk(buyer, 10 * PORTRAIT);
        assertEq(ink.balanceOf(buyer), 10 * PORTRAIT);
    }

    function test_onlyOnePool() public {
        PoolKey memory second = poolKey;
        second.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(second, TickMath.getSqrtPriceAtTick(0));
    }

    // ---------------------------------------------------------------- release premium

    function test_releasePremiumListsAboveTheOpeningPrice() public {
        vm.prank(other);
        vm.expectRevert();
        liq.setPremium(7_000);
        vm.prank(owner);
        vm.expectRevert(InkLiquidity.BadPremium.selector);
        liq.setPremium(-1);
        vm.prank(owner);
        liq.setPremium(7_000);
        _release();
        (, PositionInfo info) = posm.getPoolAndPositionInfo(liq.positions(0));
        if (inkIs0) assertGe(info.tickLower(), liq.floorTick() + 7_000);
        else assertLe(info.tickUpper(), liq.floorTick() - 7_000);
        vm.prank(owner);
        vm.expectRevert(InkLiquidity.BadPremium.selector);
        liq.setPremium(0); // can't reprice once INK is listed
    }

    // ---------------------------------------------------------------- LP fees on the released INK

    /// The released positions earn the pool's 1.25% like any liquidity; collectFees() pays the IMD side to
    /// the owner and burns the INK side, so nothing is stranded in a contract with no way out.
    function test_collectFeesPaysImdToOwnerAndBurnsInk() public {
        _release();
        vm.expectRevert(InkLiquidity.NothingToCollect.selector);
        liq.collectFees(1, 5); // clamped to the one position, so the range is empty

        _buyInk(buyer, 50_000_000e18); // pays IMD in: fee in IMD
        ink.mint(other, 200_000_000e18);
        _swap(other, false, 1_000e18, false); // exact-output sell pays INK in: fee in INK

        uint256 imdBefore = imd.balanceOf(owner);
        uint256 deadBefore = ink.balanceOf(liq.DEAD());
        uint256 liqInk = ink.balanceOf(address(liq));
        vm.prank(other); // anyone can call it
        (uint256 imdOut, uint256 inkBurned) = liq.collectFees(0, type(uint256).max);
        assertGt(imdOut, 0, "IMD fees reach the owner");
        assertGt(inkBurned, 0, "INK fees are burned");
        assertEq(imd.balanceOf(owner) - imdBefore, imdOut);
        assertEq(ink.balanceOf(liq.DEAD()) - deadBefore, inkBurned);
        assertEq(ink.balanceOf(address(liq)), liqInk, "nothing left behind in the liquidity contract");
        assertEq(imd.balanceOf(address(liq)), 0);

        // Collecting again right away finds nothing new, and the position's liquidity is untouched.
        (imdOut, inkBurned) = liq.collectFees(0, 1);
        assertEq(imdOut, 0);
        assertEq(inkBurned, 0);
        assertGt(posm.getPositionLiquidity(liq.positions(0)), 0);
    }

    /// The premium can be set before the pool, which is the order the launch step uses: until setPool()
    /// nobody can list INK through addLiquidity(), so a dust donation can't lock the premium at 0.
    function test_premiumBeforePoolCannotBeFrontRun() public {
        InkLiquidity l2 = new InkLiquidity(manager, posm, owner);
        ink.mint(other, 1e18);
        vm.startPrank(other);
        ink.transfer(address(l2), 1); // a griefer's dust
        vm.expectRevert(InkLiquidity.PoolNotSet.selector);
        l2.addLiquidity();
        vm.stopPrank();
        vm.startPrank(owner);
        l2.setPremium(16_000);
        l2.setPool(poolKey, IERC20(address(ink)));
        vm.stopPrank();
        assertEq(l2.premium(), 16_000);
        InkLiquidity l3 = new InkLiquidity(manager, posm, owner);
        vm.expectRevert(InkLiquidity.PoolNotSet.selector);
        l3.collectFees(0, 1);
    }
}
