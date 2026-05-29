# sign_EIP2612

基于 **EIP-2612 (ERC20Permit)** 的 Token + TokenBank 存款合约，支持通过离线签名完成 Gasless 授权存款。

## 合约

| 合约 | 说明 |
|------|------|
| `BaseERC20` | ERC-20 代币，基于 OpenZeppelin ERC20 + ERC20Permit，支持 permit 签名授权 |
| `TokenBank` | 存款银行，支持传统存款和 `permitDeposit` 签名一步存款 |

## 快速开始

```bash
# 安装依赖
forge install

# 编译
forge build

# 测试
forge test
```

## 前端

```bash
cd frontend
npm install
npm run dev
```

前端基于 React + Vite + wagmi + viem，连接本地 Hardhat/Anvil 节点。

## 两种存款方式

| | 传统存款 | 签名存款 |
|------|------|------|
| 交易笔数 | 2 (approve + deposit) | 1 (permitDeposit) |
| 钱包操作 | 确认交易 ×2 | 签名 ×1 + 确认交易 ×1 |
| gas 费 | 两次 | 一次 |

## EIP-2612 签名结构

```
Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)
```

签名后调用 `TokenBank.permitDeposit()` 一步完成授权+存款。

## 合约文档

- [BaseERC20](./BaseERC20.md)
- [TokenBank](./TokenBank.md)
- [前端改动说明](./FRONTEND.md)
