// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/V3Utils.sol";

contract MyScript is Script {
    function run() external {
        // Uniswap NonfungiblePositionManager
        INonfungiblePositionManager NFPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        address SWAP_ROUTER = vm.envAddress("KRYSTAL_SWAP_ROUTER");

        vm.startBroadcast();

        V3Utils v3Utils = new V3Utils(NFPM, SWAP_ROUTER);

        vm.stopBroadcast();
    }
}
