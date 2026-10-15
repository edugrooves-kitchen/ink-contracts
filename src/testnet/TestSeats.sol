// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title Test seats (Sepolia only)
/// @notice Stands in for the identity.md collection on Sepolia, where it doesn't exist. Anyone can mint
/// any unminted seat number, so testers can rehearse agent claims. Never deploy this on mainnet.
contract TestSeats is ERC721("identity.md (test)", "IMD-ID-TEST") {
    function mint(uint256 seat) external {
        _mint(msg.sender, seat);
    }
}
