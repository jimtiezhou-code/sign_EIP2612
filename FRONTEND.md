# 前端改动说明

## 改动概览

前端新增了 **EIP-2612 签名存款** 功能，用户可通过钱包签名一步完成存款，无需先 approve 再 deposit。

## 改动的文件

### 1. `src/contracts/BaseERC20.ts` — ABI 扩充

新增 2 个合约方法的 ABI 定义：

| 方法 | 用途 |
|------|------|
| `nonces(address owner)` | 查询用户当前 nonce（签名防重放） |
| `DOMAIN_SEPARATOR()` | 获取 EIP-712 域名分隔符 |

### 2. `src/contracts/TokenBank.ts` — ABI 扩充

新增 `permitDeposit` 方法的 ABI 定义：

```ts
{
  functionName: 'permitDeposit',
  inputs: [
    { name: 'owner', type: 'address' },
    { name: 'amount', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
    { name: 'v', type: 'uint8' },
    { name: 'r', type: 'bytes32' },
    { name: 's', type: 'bytes32' },
  ]
}
```

### 3. `src/App.tsx` — 核心逻辑

**新增 import**：
```ts
import { useSignTypedData } from 'wagmi';    // EIP-712 签名 hook
import { parseSignature } from 'viem';        // 拆分签名为 v, r, s
```

**新增 hook**：
```ts
const { signTypedDataAsync } = useSignTypedData();  // 钱包签名方法
const { chainId } = useAccount();                    // 获取当前链 ID
const { data: nonce } = useReadContract({            // 读取用户 nonce
  functionName: 'nonces',
  args: [address],
});
```

**新增 `handlePermitDeposit` 函数** — 签名存款核心流程：

```
用户点击「签名存款」
       │
       ▼
构造 EIP-712 类型数据 (Permit 结构)
       │
       ▼
signTypedDataAsync() → 钱包弹出签名确认
       │
       ▼
parseSignature() 拆分 v, r, s
       │
       ▼
writeContract(permitDeposit) → 链上一步完成授权+存款
```

**关键代码**：
```ts
async function handlePermitDeposit() {
  if (!address || !parsedAmount || !chainId || nonce === undefined) return;

  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

  // 1. EIP-712 签名
  const signature = await signTypedDataAsync({
    types: {
      Permit: [
        { name: 'owner', type: 'address' },
        { name: 'spender', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'deadline', type: 'uint256' },
      ],
    } as const,
    domain: {
      name: tokenName as string,
      version: '1',
      chainId: chainId,
      verifyingContract: TOKEN_ADDRESS,
    },
    primaryType: 'Permit',
    message: {
      owner: address,
      spender: TOKEN_BANK_ADDRESS,
      value: parsedAmount,
      nonce: nonce as bigint,
      deadline,
    },
  });

  // 2. 拆分签名
  const { r, s, v } = parseSignature(signature);

  // 3. 调用合约一步完成
  writeContract({
    address: TOKEN_BANK_ADDRESS,
    abi: tokenBankAbi,
    functionName: 'permitDeposit',
    args: [address, parsedAmount, deadline, v, r, s],
  });
}
```

**新增 UI**：在原有的三个操作按钮下方增加了签名存款区域：

```
┌─────────────────────────────────────────────┐
│  1. 授权  │  2. 存款  │  3. 取款             │
├─────────────────────────────────────────────┤
│   或 使用签名一步完成（无需预先授权）          │
│  ┌─────────────────────────────────────┐    │
│  │   签名存款 (Permit + Deposit)       │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

### 4. `src/App.scss` — 样式

新增 `.permit-section`、`.permit-divider`、`.btn-permit` 三个样式规则，紫色渐变按钮区分于原有操作按钮。

## EIP-712 签名数据结构

```json
{
  "types": {
    "Permit": [
      { "name": "owner", "type": "address" },
      { "name": "spender", "type": "address" },
      { "name": "value", "type": "uint256" },
      { "name": "nonce", "type": "uint256" },
      { "name": "deadline", "type": "uint256" }
    ]
  },
  "domain": {
    "name": "BaseERC20",
    "version": "1",
    "chainId": 31337,
    "verifyingContract": "0x..."
  },
  "primaryType": "Permit",
  "message": {
    "owner": "用户地址",
    "spender": "TokenBank 合约地址",
    "value": "存款金额",
    "nonce": "当前 nonce",
    "deadline": "Unix 时间戳（默认 +1 小时）"
  }
}
```

## 两种存款方式对比

| | 传统存款 | 签名存款 |
|------|------|------|
| 按钮 | 1.授权 → 2.存款 | 签名存款 |
| 交易笔数 | 2 | 1 |
| 钱包操作 | 确认交易 ×2 | 签名 ×1 + 确认交易 ×1 |
| gas 费 | 两次 gas | 一次 gas |
| 适用场景 | 已有授权额度 | 首次存款、快速操作 |
