// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/BaseERC20.sol";
import "../src/tokenBank.sol";
import "permit2/Permit2.sol";
import "permit2/libraries/PermitHash.sol";

contract TokenBankTest is Test {
    BaseERC20 public token;
    TokenBank public bank;
    Permit2 public permit2;

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

        // Deployer creates Permit2, token and bank
        vm.startPrank(deployer);
        permit2 = new Permit2();
        token = new BaseERC20();
        bank = new TokenBank(address(token), address(permit2));

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
        new TokenBank(address(0), address(permit2));
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
    //  depositWithPermit2 — Permit2
    // ==============================

    function testDepositWithPermit2() public {
        uint256 amount = 100 * 1e18;
        uint256 pnonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        // 1. aliceSigner 先 approve Permit2（一次性，通常设为无限额度）
        vm.prank(aliceSigner);
        token.approve(address(permit2), type(uint256).max);

        // 2. 构建 PermitTransferFrom 签名
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer
            .PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: address(token),
                    amount: amount
                }),
                nonce: pnonce,
                deadline: deadline
            });

        bytes memory signature = _signPermit2Transfer(permit, alicePk, address(bank));

        // 3. 调用 depositWithPermit2（任何人都可以 relay）
        vm.prank(bob);
        bank.depositWithPermit2(aliceSigner, amount, pnonce, deadline, signature);

        assertEq(bank.getDepositBalance(aliceSigner), amount);
        assertEq(token.balanceOf(address(bank)), amount);
    }

    function testDepositWithPermit2_ZeroAmount() public {
        vm.expectRevert("TokenBank: amount is 0");
        bank.depositWithPermit2(aliceSigner, 0, 0, block.timestamp + 1 hours, "");
    }

    function testDepositWithPermit2_ExpiredSignature() public {
        uint256 amount = 100 * 1e18;
        uint256 deadline = 0; // 已过期

        vm.startPrank(aliceSigner);
        token.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer
            .PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: address(token),
                    amount: amount
                }),
                nonce: 0,
                deadline: deadline
            });

        bytes memory signature = _signPermit2Transfer(permit, alicePk, address(bank));

        vm.prank(bob);
        // Permit2 会在 deadline 过期时 revert
        vm.expectRevert();
        bank.depositWithPermit2(aliceSigner, amount, 0, deadline, signature);
    }

    function testDepositWithPermit2_WrongSigner() public {
        uint256 amount = 100 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;

        vm.startPrank(aliceSigner);
        token.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer
            .PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: address(token),
                    amount: amount
                }),
                nonce: 0,
                deadline: deadline
            });

        // 用 alicePk 签名，但 owner 传入 alice（不同地址）
        bytes memory signature = _signPermit2Transfer(permit, alicePk, address(bank));

        // owner 参数传入 alice 而非 aliceSigner
        vm.prank(bob);
        vm.expectRevert();
        bank.depositWithPermit2(alice, amount, 0, deadline, signature);
    }

    function testDepositWithPermit2_ReplaySigner() public {
        uint256 amount = 100 * 1e18;
        uint256 pnonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        vm.startPrank(aliceSigner);
        token.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer
            .PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: address(token),
                    amount: amount
                }),
                nonce: pnonce,
                deadline: deadline
            });

        bytes memory signature = _signPermit2Transfer(permit, alicePk, address(bank));

        // 第一次成功
        vm.prank(bob);
        bank.depositWithPermit2(aliceSigner, amount, pnonce, deadline, signature);

        // 第二次使用同一签名 → nonce 已标记 → revert
        vm.prank(bob);
        vm.expectRevert();
        bank.depositWithPermit2(aliceSigner, amount, pnonce, deadline, signature);
    }

    function testDepositWithPermit2_WithoutPermit2Approval() public {
        uint256 amount = 100 * 1e18;
        uint256 pnonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        // 不 approve Permit2

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer
            .PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: address(token),
                    amount: amount
                }),
                nonce: pnonce,
                deadline: deadline
            });

        bytes memory signature = _signPermit2Transfer(permit, alicePk, address(bank));

        vm.prank(bob);
        vm.expectRevert(); // Permit2: allowance too low
        bank.depositWithPermit2(aliceSigner, amount, pnonce, deadline, signature);
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

    /// @dev 构建 Permit2 PermitTransferFrom 的 EIP-712 签名
    function _signPermit2Transfer(
        ISignatureTransfer.PermitTransferFrom memory permit,
        uint256 privateKey,
        address spender
    ) internal view returns (bytes memory) {
        bytes32 TOKEN_PERMISSIONS_TYPEHASH = keccak256(
            "TokenPermissions(address token,uint256 amount)"
        );
        bytes32 PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
            "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
        );

        bytes32 tokenPermissionsHash = keccak256(
            abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted)
        );
        bytes32 msgHash = keccak256(
            abi.encode(
                PERMIT_TRANSFER_FROM_TYPEHASH,
                tokenPermissionsHash,
                spender,
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 domainSeparator = permit2.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, msgHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
