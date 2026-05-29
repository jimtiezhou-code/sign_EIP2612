// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/JimToken.sol";

contract JimTokenTest is Test {
    JimToken public token;
    uint256 public alicePrivateKey = 0xA11CE;
    address public alice = vm.addr(alicePrivateKey);
    address public owner = makeAddr("owner");

    function setUp() public {
        vm.startPrank(owner);
        token = new JimToken(owner);
        token.mint(alice, 1000 * 10 ** token.decimals());
        vm.stopPrank();
    }

    function testTokenName() public view {
        assertEq(token.name(), "JimToken");
        assertEq(token.symbol(), "JIM");
    }

    function testMint() public view {
        assertEq(token.balanceOf(alice), 1000 * 10 ** token.decimals());
    }

    function testPermitAndTransfer() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 100 * 10 ** token.decimals();

        // Build the EIP-2612 permit signature off-chain
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                permitTypehash,
                alice,
                address(this),
                value,
                token.nonces(alice),
                deadline
            )
        );

        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);

        // Execute the permit
        token.permit(alice, address(this), value, deadline, v, r, s);

        // Verify allowance is set
        assertEq(token.allowance(alice, address(this)), value);

        // Transfer via allowance (test contract is the spender)
        token.transferFrom(alice, address(this), value);
        assertEq(token.balanceOf(alice), 900 * 10 ** token.decimals());
    }

    function testDomainSeparator() public view {
        bytes32 separator = token.DOMAIN_SEPARATOR();
        assertTrue(separator != bytes32(0));
    }
}
