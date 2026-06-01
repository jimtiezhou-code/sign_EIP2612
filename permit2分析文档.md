# Permit2 签名存款 — 变更与逻辑分析

> 项目：sign_EIP2612  
> 分支：main  
> 变更时间：2026-06

---

## 一、变更概述

在已有 EIP-2612 `permitDeposit` 的基础上，TokenBank 新增 **Uniswap Permit2** 签名存款方式 `depositWithPermit2`，前端同步支持。

| 文件 | 变更类型 | 说明 |
|------|---------|------|
| `src/tokenBank.sol` | 新增 | `depositWithPermit2()` 函数 + Permit2 集成 |
| `test/TokenBank.t.sol` | 新增+修复 | 6 个 Permit2 测试；修复构造函数适配 Permit2 部署 |
| `frontend/src/contracts/addresses.ts` | 新增 | `PERMIT2_ADDRESS` |
| `frontend/src/contracts/TokenBank.ts` | 更新 | ABI 新增 `depositWithPermit2` + `permit2` |
| `frontend/src/App.tsx` | 新增 | `handlePermit2Deposit()`、`handlePermit2Approve()` + UI |
| `frontend/src/App.scss` | 新增 | Permit2 输入框和按钮样式 |
| `foundry.toml` | 更新 | 启用 `via_ir = true` 解决 Stack too deep |
| `lib/permit2/src/*.sol` | 修复 | 5 个文件 pragma `0.8.17` → `^0.8.17` 解决版本冲突 |
| `test/JimToken.t.sol` | 删除 | 旧测试文件 |

---

## 二、三种存款方式对比

```
┌──────────────────────────────────────────────────────────────────┐
│                    TokenBank 三种存款路径                          │
├──────────────┬─────────────────────┬─────────────────────────────┤
│  传统 deposit │  EIP-2612 permitDeposit │  Permit2 depositWithPermit2 │
├──────────────┼─────────────────────┼─────────────────────────────┤
│ approve       │ 钱包签名 (off-chain)   │ 钱包签名 (off-chain)          │
│   ↓           │   + 上链调用            │   + 上链调用                  │
│ deposit       │                       │                              │
├──────────────┼─────────────────────┼─────────────────────────────┤
│ 2 笔交易      │ 1 笔交易               │ 1 笔交易                     │
│ 2 次 gas      │ 1 次 gas               │ 1 次 gas                     │
│ 无需设置      │ 无需设置               │ 需先一次性授权 Permit2 合约   │
│ 每笔分别授权  │ 每次需要新签名          │ Nonce bitmap，无需顺序使用    │
└──────────────┴─────────────────────┴─────────────────────────────┘
```

---

## 三、Permit2 核心逻辑

### 3.1 什么是 Permit2

Uniswap 推出的 ERC20 授权管理合约，解决传统 `approve` 的痛点：
- **一次性无限授权**：用户只需 `approve(Permit2, MAX)` 一次
- **精确每笔控制**：后续每笔转账通过**离线签名**指定金额、接收方、过期时间
- **无需每次都 approve**：省 gas，无重复授权交易

### 3.2 架构层级

```
┌──────────────────────────────────┐
│         TokenBank                │  ← 业务合约
│   depositWithPermit2()           │
└────────────┬─────────────────────┘
             │ permitTransferFrom(permit, transferDetails, owner, sig)
             ▼
┌──────────────────────────────────┐
│         Permit2                  │  ← Uniswap 授权管理层
│   验证签名 → transferFrom         │
└────────────┬─────────────────────┘
             │ token.transferFrom(owner, to, amount)
             ▼
┌──────────────────────────────────┐
│         BaseERC20                │  ← ERC20 代币
│   allowance[owner][Permit2]      │
└──────────────────────────────────┘
```

### 3.3 签名数据结构 (EIP-712)

Permit2 使用 EIP-712 类型化签名，domain 和结构如下：

#### Domain

```javascript
{
  name: "Permit2",
  chainId: 31337,
  verifyingContract: PERMIT2_ADDRESS
}
```

**注意**：Permit2 的 EIP-712 Domain **没有 version 字段**（与 ERC20Permit 不同）。

#### 类型定义

```javascript
{
  TokenPermissions: [
    { name: "token",    type: "address"  },
    { name: "amount",   type: "uint256"  }
  ],
  PermitTransferFrom: [
    { name: "permitted", type: "TokenPermissions" },  // 嵌套结构
    { name: "spender",   type: "address"           },  // 谁可以使用此许可
    { name: "nonce",     type: "uint256"           },  // 防重放 nonce
    { name: "deadline",  type: "uint256"           }   // 过期时间
  ]
}
```

#### 消息示例

```javascript
{
  permitted: {
    token: "0x5FbDB...",     // BERC20 代币地址
    amount: 100000000000000000000n  // 100 BERC20 (wei)
  },
  spender: "0xe7f1725...",   // TokenBank 地址（msg.sender）
  nonce: 0n,                  // 第一次使用
  deadline: 1717200000n       // 1 小时后过期
}
```

### 3.4 链上验证流程

```
depositWithPermit2(owner, amount, nonce, deadline, signature)
  │
  ├─ 1. require(amount > 0)
  │
  ├─ 2. 构造 PermitTransferFrom 结构体
  │     permitted: { token: BERC20, amount: amount }
  │     nonce: nonce
  │     deadline: deadline
  │
  ├─ 3. 构造 SignatureTransferDetails
  │     to: TokenBank
  │     requestedAmount: amount
  │
  ├─ 4. permit2.permitTransferFrom(permit, details, owner, signature)
  │     │
  │     ├─ 4.1 重建 EIP-712 digest
  │     │     typeHash = keccak256("PermitTransferFrom(...)")
  │     │     tokenHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted))
  │     │     structHash = keccak256(abi.encode(typeHash, tokenHash, msg.sender, nonce, deadline))
  │     │     digest = keccak256("\x19\x01" ‖ DOMAIN_SEPARATOR ‖ structHash)
  │     │
  │     ├─ 4.2 ecrecover(digest, signature) → signer
  │     │     require(signer == owner)  // 签名者必须是 token 持有者
  │     │
  │     ├─ 4.3 检查 deadline
  │     │     require(block.timestamp <= deadline)
  │     │
  │     ├─ 4.4 防重放 — bitmap nonce
  │     │     wordPos = nonce >> 8          // 高 248 位：位图索引
  │     │     bit = 1 << (nonce & 0xFF)      // 低 8 位：位偏移
  │     │     require(nonceBitmap[owner][wordPos] & bit == 0)
  │     │     nonceBitmap[owner][wordPos] |= bit  // 标记已使用
  │     │
  │     └─ 4.5 token.transferFrom(owner, to, amount)
  │           // 利用用户之前对 Permit2 的授权
  │
  └─ 5. depositBalances[owner] += amount
        emit Deposit(owner, amount)
```

### 3.5 Nonce Bitmap 机制

Permit2 使用 **unordered nonce**（无序 nonce），与传统递增 nonce 不同：

```
nonce 是一个 uint256：
  ┌────────────────────────────────────┬──────────┐
  │      高 248 位 (wordPos)           │ 低 8 位  │
  │      位图索引 (0 ~ 2^248-1)        │ 位偏移    │
  └────────────────────────────────────┴──────────┘

示例：
  nonce = 0       → wordPos=0, bit=1   (bit 0)
  nonce = 1       → wordPos=0, bit=2   (bit 1)
  nonce = 256     → wordPos=1, bit=1   (下一个 word 的 bit 0)
  nonce = 0x123456789ABC00  → wordPos=0x123456789ABC, bit=1
```

**优势**：
- 无需按顺序使用 nonce，可以并发签发多个许可
- 已用 nonce 永久标记在 bitmap 中，无法重放
- 一个 word (256 bits) 可记录 256 个不同的 nonce

**对比 EIP-2612 nonce**：
| | EIP-2612 | Permit2 |
|------|------|------|
| 类型 | 递增序号 | 位图标记 |
| 顺序 | 必须顺序使用 | 无序，任意 |
| 并发 | 不支持 | 支持 |
| 存储 | 1 slot/用户 | 1 slot/word (覆盖 256 个 nonce) |

### 3.6 前端签名实现（关键细节）

```typescript
// 与 EIP-2612 的主要差异：
// 1. Domain 没有 version 字段
// 2. 嵌套类型 TokenPermissions → PermitTransferFrom
// 3. 签名后不解析 v/r/s，直接传 bytes 给合约

const signature = await signTypedDataAsync({
  domain: {
    name: 'Permit2',           // ← 固定名称
    chainId: chainId,
    verifyingContract: PERMIT2_ADDRESS,
    // ⚠️ 没有 version 字段！
  },
  types: {
    TokenPermissions: [        // ← 嵌套类型
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    PermitTransferFrom: [      // ← 主类型
      { name: 'permitted', type: 'TokenPermissions' },
      { name: 'spender', type: 'address' },
      { name: 'nonce', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
    ],
  },
  primaryType: 'PermitTransferFrom',
  message: {
    permitted: { token: TOKEN_ADDRESS, amount: parsedAmount },
    spender: TOKEN_BANK_ADDRESS,
    nonce: BigInt(permit2Nonce),
    deadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
  },
});
```

### 3.7 与 EIP-2612 的关键差异

| 特性 | EIP-2612 (permitDeposit) | Permit2 (depositWithPermit2) |
|------|------|------|
| 授权对象 | 每笔签名授权 TokenBank | 一次性授权 Permit2，后续签名使用 |
| 签名结构 | `Permit(owner,spender,value,nonce,deadline)` | `PermitTransferFrom(TokenPermissions,spender,nonce,deadline)` |
| EIP-712 Domain | `{name, version, chainId, verifyingContract}` | `{name, chainId, verifyingContract}` (无 version) |
| Nonce 机制 | 递增序号 (mapping) | 位图标记 (bitmap) |
| 签名格式 | 解析为 `v, r, s` 传入 | `bytes` 直接传入 |
| 中间合约 | 无（TokenBank 直接 transferFrom） | Permit2 合约验证 + transferFrom |
| 签名者 | token owner | token owner |
| Relayer | 任何人可提交 | 任何人可提交 |

---

## 四、用户操作流程

### 4.1 首次设置（一次性）

```
1. 用户 → MetaMask: approve(PERMIT2_ADDRESS, MAX_UINT256)
   → 将 BERC20 无限授权给 Permit2 合约
```

### 4.2 每次存款

```
1. 前端输入：存款金额 + Nonce（默认 0）
2. 点击 "Permit2 签名存款"
3. MetaMask 弹出签名界面：
   ┌─────────────────────────┐
   │  Permit2                │
   │  Token: 0x5FbDB...      │
   │  Amount: 100 BERC20     │
   │  Spender: 0xe7f1725...  │
   │  Nonce: 0               │
   │  Deadline: ...          │
   └─────────────────────────┘
4. 用户确认签名 → 前端调用 depositWithPermit2()
5. 链上：Permit2 验证签名 → transferFrom → TokenBank 记录存款
```

### 4.3 使用下一个 Nonce

```
第一次：nonce = 0 (word 0, bit 0)
第二次：nonce = 1 (word 0, bit 1)
...
第 256 次：nonce = 256 (word 1, bit 0)
```

---

## 五、智能合约完整接口

```solidity
contract TokenBank {
    // 状态
    mapping(address => uint256) public depositBalances;
    BaseERC20 public token;
    ISignatureTransfer public immutable permit2;  // ← 新增

    // 构造函数（新增 _permit2Address 参数）
    constructor(address _BaseERC20Address, address _permit2Address);

    // 三种存款方法
    function deposit(uint256 amount) external;                              // 传统
    function permitDeposit(address owner, uint256 amount, uint256 deadline, // EIP-2612
        uint8 v, bytes32 r, bytes32 s) external;
    function depositWithPermit2(address owner, uint256 amount,               // Permit2 ← 新增
        uint256 nonce, uint256 deadline, bytes calldata signature) external;

    function withdraw(uint256 amount) external;
    function getTotalBalance() external view returns (uint256);
    function getDepositBalance(address user) external view returns (uint256);
    function getTokenInfo() external view returns (string memory, string memory, uint8);
}
```

---

## 六、测试覆盖

| 测试 | 说明 |
|------|------|
| `testDepositWithPermit2` | 正常 Permit2 签名存款 |
| `testDepositWithPermit2_ZeroAmount` | 零金额 revert |
| `testDepositWithPermit2_ExpiredSignature` | deadline 过期 revert |
| `testDepositWithPermit2_WrongSigner` | owner 不匹配 revert |
| `testDepositWithPermit2_ReplaySigner` | 同一签名重复使用 revert |
| `testDepositWithPermit2_WithoutPermit2Approval` | 未授权 Permit2 revert |

---

## 七、部署注意事项

1. **必须同时部署 Permit2 合约**（`Deploy.s.sol` 已更新）
2. **用户需先 `approve(Permit2, MAX)`** 一次
3. **Nonce 从 0 开始**，每次递增使用不同 bit
4. **Permit2 Domain 无 version 字段**，前端签名时必须排除
5. **签名是完整 bytes**（65 字节 `r+s+v`），不拆分为 v/r/s
