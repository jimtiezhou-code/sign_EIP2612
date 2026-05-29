// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/BaseERC20.sol";
import "../src/tokenBank.sol";

contract TokenBankTest is Test {
    BaseERC20 public token;
    TokenBank public bank;

    address public deployer = makeAddr("deployer");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    // Known private key for EIP-2612 signing tests
    uint256 public alicePk = 0xA11CE;
    address public aliceSigner; // derived from alicePk via vm.addr

    // --- Setup ---

    function setUp() public {
        // Derive aliceSigner from known private key (for permit signing)
        aliceSigner = vm.addr(alicePk);

        // Deployer creates token and bank
        vm.startPrank(deployer);
        token = new BaseERC20();
        bank = new TokenBank(address(token));

        // Transfer tokens to test accounts
        token.transfer(alice, 10_000 * 1e18);
        token.transfer(aliceSigner, 10_000 * 1e18);
        token.transfer(bob, 10_000 * 1e18);
        vm.stopPrank();
    }

    // ==============================
    //  Constructor
    // ==============================

    function testConstructor() public view {
        assertEq(address(bank.token()), address(token));
    }

    function testConstructorZeroAddress() public {
        vm.expectRevert("TokenBank: address is zero");
        new TokenBank(address(0));
    }

    // ==============================
    //  deposit
    // ==============================

    function testDeposit() public {
        uint256 amount = 100 * 1e18;

        vm.startPrank(alice);
        token.approve(address(bank), amount);
        bank.deposit(amount);
        vm.stopPrank();

        assertEq(bank.getDepositBalance(alice), amount);
        assertEq(token.balanceOf(address(bank)), amount);
        assertEq(token.balanceOf(alice), 10_000 * 1e18 - amount);
    }

    function testDepositZeroAmount() public {
        vm.startPrank(alice);
        token.approve(address(bank), 1);
        vm.expectRevert("TokenBank: amount is 0");
        bank.deposit(0);
        vm.stopPrank();
    }

    function testDepositInsufficientBalance() public {
        uint256 tooMuch = 100_000 * 1e18; // alice only has 10k

        vm.startPrank(alice);
        token.approve(address(bank), tooMuch);
        vm.expectRevert("TokenBank: msg.sender insufficient balance");
        bank.deposit(tooMuch);
        vm.stopPrank();
    }

    function testDepositWithoutApproval() public {
        uint256 amount = 100 * 1e18;

        vm.startPrank(alice);
        // no approve
        vm.expectRevert();
        bank.deposit(amount);
        vm.stopPrank();
    }

    // ==============================
    //  withdraw
    // ==============================

    function testWithdraw() public {
        uint256 depositAmount = 500 * 1e18;
        uint256 withdrawAmount = 200 * 1e18;

        vm.startPrank(alice);
        token.approve(address(bank), depositAmount);
        bank.deposit(depositAmount);
        bank.withdraw(withdrawAmount);
        vm.stopPrank();

        assertEq(bank.getDepositBalance(alice), depositAmount - withdrawAmount);
        assertEq(token.balanceOf(address(bank)), depositAmount - withdrawAmount);
        assertEq(token.balanceOf(alice), 10_000 * 1e18 - depositAmount + withdrawAmount);
    }

    function testWithdrawZeroAmount() public {
        vm.startPrank(alice);
        token.approve(address(bank), 100 * 1e18);
        bank.deposit(100 * 1e18);

        vm.expectRevert("TokenBank: amount must be > 0");
        bank.withdraw(0);
        vm.stopPrank();
    }

    function testWithdrawInsufficientDeposit() public {
        vm.startPrank(alice);
        token.approve(address(bank), 100 * 1e18);
        bank.deposit(100 * 1e18);

        vm.expectRevert("TokenBank: amount is invalid");
        bank.withdraw(200 * 1e18);
        vm.stopPrank();
    }

    // ==============================
    //  permitDeposit — EIP-2612
    // ==============================

    function testPermitDeposit() public {
        uint256 amount = 100 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(aliceSigner);

        bytes32 digest = _buildPermitDigest(
            aliceSigner,
            address(bank),
            amount,
            nonce,
            deadline
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        // Anyone can call permitDeposit (use bob as relayer)
        vm.prank(bob);
        bank.permitDeposit(aliceSigner, amount, deadline, v, r, s);

        assertEq(bank.getDepositBalance(aliceSigner), amount);
        assertEq(token.balanceOf(address(bank)), amount);
    }

    function testPermitDepositZeroAmount() public {
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectRevert("TokenBank: amount is 0");
        bank.permitDeposit(aliceSigner, 0, deadline, 0, bytes32(0), bytes32(0));
    }

    function testPermitDepositExpiredSignature() public {
        uint256 amount = 100 * 1e18;
        // block.timestamp at this point is 1 (anvil default).
        // ERC20Permit reverts only when block.timestamp > deadline.
        // Use 0 so when the tx executes, 1 > 0 → expired.
        uint256 deadline = 0;
        uint256 nonce = token.nonces(aliceSigner);

        bytes32 digest = _buildPermitDigest(
            aliceSigner,
            address(bank),
            amount,
            nonce,
            deadline
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC2612ExpiredSignature(uint256)")),
                deadline
            )
        );
        bank.permitDeposit(aliceSigner, amount, deadline, v, r, s);
    }

    function testPermitDepositWrongSigner() public {
        uint256 amount = 100 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(aliceSigner);

        // Sign a permit for aliceSigner as owner, using aliceSigner's key
        bytes32 digest = _buildPermitDigest(
            aliceSigner,
            address(bank),
            amount,
            nonce,
            deadline
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        // Pass a different owner (alice) to permitDeposit.
        // The structHash rebuilt on-chain uses alice, not aliceSigner,
        // so the recovered signer won't match alice → revert.
        vm.prank(bob);
        vm.expectRevert(); // ERC2612InvalidSigner
        bank.permitDeposit(alice, amount, deadline, v, r, s);
    }

    function testPermitDepositReuseSignature() public {
        uint256 amount = 100 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(aliceSigner);

        bytes32 digest = _buildPermitDigest(
            aliceSigner,
            address(bank),
            amount,
            nonce,
            deadline
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        // 第一次使用成功
        vm.prank(bob);
        bank.permitDeposit(aliceSigner, amount, deadline, v, r, s);

        // 第二次使用同一签名 → nonce 已变 → 签名失效
        vm.prank(bob);
        vm.expectRevert();
        bank.permitDeposit(aliceSigner, amount, deadline, v, r, s);
    }

    // ==============================
    //  查询
    // ==============================

    function testGetDepositBalance() public {
        uint256 amount = 250 * 1e18;

        vm.startPrank(alice);
        token.approve(address(bank), amount);
        bank.deposit(amount);
        vm.stopPrank();

        assertEq(bank.getDepositBalance(alice), amount);
        assertEq(bank.getDepositBalance(bob), 0);
    }

    function testGetTotalBalance() public {
        uint256 aDeposit = 100 * 1e18;
        uint256 bDeposit = 300 * 1e18;

        vm.startPrank(alice);
        token.approve(address(bank), aDeposit);
        bank.deposit(aDeposit);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(bank), bDeposit);
        bank.deposit(bDeposit);
        vm.stopPrank();

        assertEq(bank.getTotalBalance(), aDeposit + bDeposit);
    }

    function testGetTokenInfo() public view {
        (string memory name, string memory symbol, uint8 decimals) = bank.getTokenInfo();
        assertEq(name, "BaseERC20");
        assertEq(symbol, "BERC20");
        assertEq(decimals, 18);
    }

    // ==============================
    //  事件
    // ==============================

    function testDepositEvent() public {
        uint256 amount = 100 * 1e18;

        vm.startPrank(alice);
        token.approve(address(bank), amount);

        vm.expectEmit(true, true, false, true);
        emit TokenBank.Deposit(alice, amount);
        bank.deposit(amount);
        vm.stopPrank();
    }

    function testWithdrawEvent() public {
        uint256 amount = 100 * 1e18;

        vm.startPrank(alice);
        token.approve(address(bank), amount);
        bank.deposit(amount);

        vm.expectEmit(true, true, false, true);
        emit TokenBank.Withdraw(alice, amount);
        bank.withdraw(amount);
        vm.stopPrank();
    }

    function testPermitDepositEvent() public {
        uint256 amount = 100 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(aliceSigner);

        bytes32 digest = _buildPermitDigest(
            aliceSigner,
            address(bank),
            amount,
            nonce,
            deadline
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.expectEmit(true, true, false, true);
        emit TokenBank.Deposit(aliceSigner, amount);
        bank.permitDeposit(aliceSigner, amount, deadline, v, r, s);
    }

    // ==============================
    //  Internal Helper
    // ==============================

    function _buildPermitDigest(
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline)
        );

        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
