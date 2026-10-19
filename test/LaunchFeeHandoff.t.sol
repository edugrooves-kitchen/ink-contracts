// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILaunchFactory {
    function setRequester(uint64 launchNumber, address next) external;
    function claimFees(uint64 launchNumber) external returns (uint256 amount0, uint256 amount1);
    function owed(address account, address currency) external view returns (uint256);
}

/// Checks, against IMD's real mainnet LaunchFactory, that the wallet which paid for a launch can hand its
/// fee share to a contract (our InkFeeRouter) and that claimFees then pays that contract, not the old wallet.
/// Uses live hook launch 1170, which had unclaimed fees on 2026-10-15 (another with fees: LAUNCH=1245).
///   FORK_RPC_URL=https://ethereum-rpc.publicnode.com forge test --mc LaunchFeeHandoff -vv
contract LaunchFeeHandoffTest is Test {
    ILaunchFactory constant FACTORY = ILaunchFactory(0x12C63b581d07093F6126bc02263c58f7EadaA96F);
    IERC20 constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    uint64 LAUNCH;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        LAUNCH = uint64(vm.envOr("LAUNCH", uint256(1170)));
    }

    function _word(uint256 i) internal view returns (bytes32 w) {
        (bool ok, bytes memory data) =
            address(FACTORY).staticcall(abi.encodeWithSignature("positionOf(uint64)", LAUNCH));
        require(ok, "positionOf");
        assembly {
            w := mload(add(data, add(32, mul(i, 32))))
        }
    }

    function _bal(IERC20 c, address who) internal view returns (uint256) {
        return address(c) == address(0) ? who.balance : c.balanceOf(who);
    }

    function _requester() internal view returns (address r) {
        (bool ok, bytes memory data) =
            address(FACTORY).staticcall(abi.encodeWithSignature("positionOf(uint64)", LAUNCH));
        require(ok, "positionOf");
        // (PoolKey key (5 words), int24 tickLower, int24 tickUpper, address requester)
        assembly {
            r := mload(add(data, 256))
        }
    }

    function test_fork_requesterHandoffPaysTheContract() public {
        address payer = _requester();
        assertTrue(payer != address(0), "launch has a requester");
        address router = makeAddr("feeRouter");

        vm.expectRevert(); // only the current requester can hand it on
        FACTORY.setRequester(LAUNCH, router);

        vm.prank(payer);
        FACTORY.setRequester(LAUNCH, router);
        assertEq(_requester(), router, "router is the requester now");

        vm.expectRevert(); // nor can the old wallet take it back
        vm.prank(payer);
        FACTORY.setRequester(LAUNCH, payer);

        IERC20 c0 = IERC20(address(uint160(uint256(_word(0)))));
        IERC20 c1 = IERC20(address(uint160(uint256(_word(1)))));
        uint256 payer0 = _bal(c0, payer);
        uint256 payer1 = _bal(c1, payer);
        (uint256 a0, uint256 a1) = FACTORY.claimFees(LAUNCH); // anyone can call it
        console2.log("claimed (currency0, currency1) wei:", a0, a1);
        console2.log("router received (currency0, currency1) wei:", _bal(c0, router), _bal(c1, router));
        assertGt(a0 + a1, 0, "the launch had fees to claim");
        assertEq(_bal(c0, payer), payer0, "old wallet gets nothing");
        assertEq(_bal(c1, payer), payer1, "old wallet gets nothing");
        // 80% of the 1.25% pool fee is the requester's (the 1%), paid to the router.
        assertEq(_bal(c0, router), a0 * 8_000 / 10_000, "requester share to the router");
        assertEq(_bal(c1, router), a1 * 8_000 / 10_000, "requester share to the router");
    }
}
