// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title Ink liquidity
/// @notice Adds INK to the INK/IMD pool and keeps the positions forever: it has no way to remove
/// liquidity or move a position, so nobody (the owner included) can take the INK back out.
/// It receives the unclaimed seats' INK from the vault after the 24-hour window. Anyone can call
/// addLiquidity() to put its INK into the pool, single-sided, just past the current price, and never below
/// the price the pool had when setPool() was called (the opening price, since the pool is locked until
/// release). Without that floor, a dust sell through the empty side of a single-sided pool could drag the
/// price to the extreme for free and the released INK would be listed at almost nothing.
/// The positions earn the pool's LP fee like any other liquidity. Anyone can call collectFees(): the IMD side
/// goes to the owner and the INK side is burned (sent to 0x…dEaD), the same split as the hook's fee.
contract InkLiquidity is Ownable, IERC721Receiver {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;

    IERC20 public ink;
    PoolKey public poolKey;
    bool public poolSet;
    /// @notice The pool's tick when setPool() was called; released INK is never listed below this price.
    int24 public floorTick;
    /// @notice Width of each new position, in ticks (about 7.4x in price at 20,000).
    int24 public width = 20_000;
    /// @notice How far above the opening price (in ticks, INK dearer) released INK starts; 0 = at the floor.
    /// About 6,931 ticks doubles the price. Can only be set before the first position.
    int24 public premium;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256[] public positions;

    event PoolSet(PoolId indexed poolId, address ink);
    event LiquidityAdded(uint256 indexed positionId, int24 tickLower, int24 tickUpper, uint256 inkAmount);
    event WidthSet(int24 width);
    event PremiumSet(int24 premium);
    event FeesCollected(uint256 fromIndex, uint256 toIndex, uint256 otherToOwner, uint256 inkBurned);

    error PoolAlreadySet();
    error PoolNotSet();
    error NotInkPool();
    error NothingToAdd();
    error BadWidth();
    error BadPremium();
    error NothingToCollect();

    constructor(IPoolManager poolManager_, IPositionManager positionManager_, address owner_) Ownable(owner_) {
        poolManager = poolManager_;
        positionManager = positionManager_;
    }

    /// @notice Points at the swarm-launched INK/IMD pool. Once.
    function setPool(PoolKey calldata key, IERC20 ink_) external onlyOwner {
        if (poolSet) revert PoolAlreadySet();
        Currency c = Currency.wrap(address(ink_));
        if (!(key.currency0 == c || key.currency1 == c)) revert NotInkPool();
        poolKey = key;
        ink = ink_;
        poolSet = true;
        (, floorTick,,) = poolManager.getSlot0(key.toId());
        emit PoolSet(key.toId(), address(ink_));
    }

    function setWidth(int24 width_) external onlyOwner {
        if (width_ < poolKey.tickSpacing) revert BadWidth();
        width = width_;
        emit WidthSet(width_);
    }

    /// @notice Sets the release premium. Only before any INK is listed, so it can't reprice live liquidity.
    function setPremium(int24 premium_) external onlyOwner {
        if (premium_ < 0 || premium_ > 100_000 || positions.length != 0) revert BadPremium();
        premium = premium_;
        emit PremiumSet(premium_);
    }

    /// @notice Adds all INK this contract holds to the pool, single-sided, in a range starting just past
    /// the current price. Anyone can call it.
    function addLiquidity() external returns (uint256 positionId) {
        if (!poolSet) revert PoolNotSet();
        uint256 amount = ink.balanceOf(address(this));
        if (amount == 0) revert NothingToAdd();
        (int24 lower, int24 upper) = _nextRange();
        positionId = _mintSingleSided(lower, upper, amount);
        positions.push(positionId);
        emit LiquidityAdded(positionId, lower, upper, amount);
    }

    /// @notice Collects the LP fees earned by positions[from .. to) (clamped to the list): the other side
    /// (IMD) goes to the owner and INK is burned. Takes a range so a pile of dust positions can't make it
    /// run out of gas. Anyone can call it.
    function collectFees(uint256 from, uint256 to) external returns (uint256 otherOut, uint256 inkBurned) {
        if (!poolSet) revert PoolNotSet();
        if (to > positions.length) to = positions.length;
        if (from >= to) revert NothingToCollect();
        Currency inkC = Currency.wrap(address(ink));
        Currency other = _inkIs0() ? poolKey.currency1 : poolKey.currency0;
        address to_ = owner();
        uint256 otherBefore = other.balanceOf(to_);
        uint256 inkBefore = ink.balanceOf(DEAD);

        uint256 n = to - from;
        bytes memory actions = new bytes(n + 2);
        bytes[] memory params = new bytes[](n + 2);
        for (uint256 i; i < n; i++) {
            // Removing zero liquidity just credits the position's fees to this contract.
            actions[i] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
            params[i] = abi.encode(positions[from + i], uint256(0), uint128(0), uint128(0), bytes(""));
        }
        actions[n] = bytes1(uint8(Actions.TAKE));
        params[n] = abi.encode(other, to_, ActionConstants.OPEN_DELTA);
        actions[n + 1] = bytes1(uint8(Actions.TAKE));
        params[n + 1] = abi.encode(inkC, DEAD, ActionConstants.OPEN_DELTA);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        otherOut = other.balanceOf(to_) - otherBefore;
        inkBurned = ink.balanceOf(DEAD) - inkBefore;
        emit FeesCollected(from, to, otherOut, inkBurned);
    }

    function _inkIs0() internal view returns (bool) {
        return Currency.unwrap(poolKey.currency0) == address(ink);
    }

    /// @dev A range of `width` ticks starting just past the current price, on INK's side of it.
    function _nextRange() internal view returns (int24 lower, int24 upper) {
        (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());
        int24 spacing = poolKey.tickSpacing;
        // Price in ticks is IMD per INK when INK is currency0, INK per IMD when it's currency1, so "never
        // cheaper than the opening price" means tick >= floor or tick <= floor respectively.
        int24 floor_ = _inkIs0() ? floorTick + premium : floorTick - premium;
        if (_inkIs0() ? tick < floor_ : tick > floor_) tick = floor_;
        int24 w = (width / spacing) * spacing;
        if (w == 0) w = spacing;
        if (_inkIs0()) {
            // Token0-only liquidity sits above the price.
            lower = _floor(tick, spacing) + spacing;
            upper = lower + w;
            int24 maxTick = TickMath.maxUsableTick(spacing);
            if (upper > maxTick) upper = maxTick;
        } else {
            // Token1-only liquidity sits below the price.
            upper = _floor(tick, spacing);
            lower = upper - w;
            int24 minTick = TickMath.minUsableTick(spacing);
            if (lower < minTick) lower = minTick;
        }
    }

    function _mintSingleSided(int24 lower, int24 upper, uint256 amount) internal returns (uint256 positionId) {
        bool inkIs0 = _inkIs0();
        uint128 liq = inkIs0
            ? LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
            )
            : LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
            );

        positionId = positionManager.nextTokenId();
        ink.safeTransfer(address(positionManager), amount);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey,
            lower,
            upper,
            uint256(liq),
            inkIs0 ? uint128(amount) : uint128(0),
            inkIs0 ? uint128(0) : uint128(amount),
            address(this),
            bytes("")
        );
        // The position manager pays from the INK just sent to it, then returns any rounding dust.
        params[1] = abi.encode(Currency.wrap(address(ink)), ActionConstants.OPEN_DELTA, false);
        params[2] = abi.encode(Currency.wrap(address(ink)), address(this));
        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SWEEP)), params),
            block.timestamp
        );
    }

    function positionCount() external view returns (uint256) {
        return positions.length;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q--;
        return q * spacing;
    }
}
