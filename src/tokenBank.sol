
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "./BaseERC20.sol";

contract TokenBank {
    mapping(address => uint256) public depositBalances;
    BaseERC20 public token;

    constructor(address _BaseERC20Address) {
        require(_BaseERC20Address != address(0), "TokenBank: address is zero");
        token = BaseERC20(_BaseERC20Address);
    }

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    /**
     * @dev 通过 EIP-2612 permit 签名 + 存款一步完成
     * @param owner 代币持有人
     * @param amount 存款金额
     * @param deadline permit 签名截止时间
     * @param v 签名 v
     * @param r 签名 r
     * @param s 签名 s
     */
    function permitDeposit(
        address owner,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(amount > 0, "TokenBank: amount is 0");

        // 1. 执行 permit，授权 TokenBank 使用 owner 的 token
        IERC20Permit(address(token)).permit(owner, address(this), amount, deadline, v, r, s);

        // 2. 存款
        require(token.transferFrom(owner, address(this), amount), "TokenBank: deposit failed");
        depositBalances[owner] += amount;
        emit Deposit(owner, amount);
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "TokenBank: amount is 0");
        require(token.balanceOf(msg.sender) >= amount, "TokenBank: msg.sender insufficient balance");
        require(token.transferFrom(msg.sender, address(this), amount), "TokenBank: deposit failed");
        depositBalances[msg.sender] += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "TokenBank: amount must be > 0");
        require(depositBalances[msg.sender] >= amount, "TokenBank: amount is invalid");
        depositBalances[msg.sender] -= amount;
        require(token.transfer(msg.sender, amount), "TokenBank: transfer to msg.sender failed");
        emit Withdraw(msg.sender, amount);

    }

    function getTotalBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
    //查询用户自己的存款余额
    function getDepositBalance(address user) external view returns (uint256) {
        return depositBalances[user];
    }

    //返回银行的token信息

    function getTokenInfo() external view returns (string memory, string memory, uint8) {
        return (token.name(),token.symbol(), token.decimals());
    }




}

