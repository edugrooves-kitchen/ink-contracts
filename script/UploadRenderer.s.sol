// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {InkRenderer} from "../src/InkRenderer.sol";

/// @notice Uploads the owner's art script to a deployed InkRenderer in chunks. It drops the module
/// line `export default SwarmArt;` so the script runs as a plain <script> in each token's HTML.
/// Does not lock: check a few tokenURIs first, then call lock() yourself.
///
///   RENDERER=0x… forge script script/UploadRenderer.s.sol --rpc-url $RPC --ledger --broadcast
contract UploadRenderer is Script {
    function artScript() public view returns (bytes memory) {
        string memory src = vm.readFile("art/original-art.js");
        return bytes(vm.replace(src, "export default SwarmArt;", ""));
    }

    function run() external {
        InkRenderer renderer = InkRenderer(vm.envAddress("RENDERER"));
        bytes memory art = artScript();
        uint256 chunk = renderer.MAX_CHUNK();
        vm.startBroadcast();
        for (uint256 off; off < art.length; off += chunk) {
            uint256 end = off + chunk > art.length ? art.length : off + chunk;
            bytes memory part = new bytes(end - off);
            for (uint256 i; i < part.length; i++) part[i] = art[off + i];
            renderer.addChunk(part);
        }
        vm.stopBroadcast();
        console.log("Uploaded bytes:", art.length);
        console.log("Chunks:", renderer.chunkCount());
    }
}
