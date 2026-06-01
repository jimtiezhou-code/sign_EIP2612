// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/BaseERC20.sol";
import "../src/tokenBank.sol";
import "permit2/Permit2.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        BaseERC20 token = new BaseERC20();
        console.log("BaseERC20 deployed at:", address(token));

        Permit2 permit2 = new Permit2();
        console.log("Permit2 deployed at:", address(permit2));

        TokenBank bank = new TokenBank(address(token), address(permit2));
        console.log("TokenBank deployed at:", address(bank));

        vm.stopBroadcast();
    }
}