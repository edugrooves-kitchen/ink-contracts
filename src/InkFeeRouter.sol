// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IInkLiquidityFees {
    function ink() external view returns (IERC20);
    function poolSet() external view returns (bool);
    function addLiquidity() external returns (uint256 positionId);
    function MIN_ADD() external view returns (uint256);
}

interface ILaunchFeeFactory {
    function claimFees(uint64 launchNumber) external returns (uint256 amount0, uint256 amount1);
}

/// @title Ink fee router
/// @notice Where the launch's trading-fee share goes. IMD's launch factory pays the requester's share of the pool
/// fee (1% of volume, in INK and IMD) to the launch's requester, which starts as the wallet that paid. Right after
/// the launch that wallet calls factory.setRequester(launchNumber, this router), once; the router has no way to
/// hand the share on again, so from then on the share can only take the two paths below. claimAndRoute() claims
/// it (factory.claimFees pays the requester directly; anyone may call it) and routes it in one call. route()
/// sends every IMD it holds to the treasury and every INK it holds to InkLiquidity, and adds that INK to
/// the pool as a new permanent position once InkLiquidity holds at least MIN_ADD. The positions earn the pool
/// fee too, and InkLiquidity.collectFees() sends their IMD to the same treasury, so the INK side compounds.
/// No owner, nothing to configure, nothing can be taken out except along those two paths. Anyone can call
/// route(). Any other token sent here is stuck, so only send INK and IMD.
contract InkFeeRouter {
    using SafeERC20 for IERC20;

    IInkLiquidityFees public immutable liquidity;
    IERC20 public immutable imd;
    address public immutable treasury;

    event Routed(uint256 imdToTreasury, uint256 inkToLiquidity, uint256 positionId);
    event Claimed(address indexed factory, uint64 indexed launchNumber);

    error ZeroAddress();
    error PoolNotSet();

    constructor(IInkLiquidityFees liquidity_, IERC20 imd_, address treasury_) {
        if (address(liquidity_) == address(0) || address(imd_) == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        liquidity = liquidity_;
        imd = imd_;
        treasury = treasury_;
    }

    /// @notice Claims a launch's accrued pool fees from IMD's launch factory (paying this router its requester
    /// share), then routes everything held. Anyone can call it. Whatever `factory` does, the router can only
    /// send its INK and IMD along the two fixed paths, so a wrong or hostile factory can't take anything.
    function claimAndRoute(ILaunchFeeFactory factory, uint64 launchNumber)
        external
        returns (uint256 imdOut, uint256 inkOut, uint256 positionId)
    {
        factory.claimFees(launchNumber);
        emit Claimed(address(factory), launchNumber);
        return route();
    }

    /// @notice Sends held IMD to the treasury and held INK to the liquidity contract, then adds liquidity if
    /// the liquidity contract has built up at least MIN_ADD INK. Returns the new position id, or 0 if none.
    function route() public returns (uint256 imdOut, uint256 inkOut, uint256 positionId) {
        if (!liquidity.poolSet()) revert PoolNotSet(); // INK's address is only known once the pool is set
        IERC20 ink = liquidity.ink();

        imdOut = imd.balanceOf(address(this));
        if (imdOut != 0) imd.safeTransfer(treasury, imdOut);
        inkOut = ink.balanceOf(address(this));
        if (inkOut != 0) ink.safeTransfer(address(liquidity), inkOut);

        if (ink.balanceOf(address(liquidity)) >= liquidity.MIN_ADD()) positionId = liquidity.addLiquidity();
        emit Routed(imdOut, inkOut, positionId);
    }
}
