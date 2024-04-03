// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/V3Utils.sol";

contract V3UtilsScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address KRYSTAL_ROUTER = 0x051DC16b2ECB366984d1074dCC07c342a9463999;
        V3Utils v3Utils = new V3Utils(KRYSTAL_ROUTER);

        vm.stopBroadcast();
    }
}
