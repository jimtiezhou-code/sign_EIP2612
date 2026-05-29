# TokenBank 合约

## 概述

TokenBank 是一个代币存款银行合约，支持用户存入 BaseERC20 代币并随时取回。支持两种存款方式：**传统 approve + deposit** 和 **EIP-2612 签名一步存款**。

## 状态变量

| 变量 | 类型 | 说明 |
|------|------|------|
| `depositBalances` | `mapping(address => uint256)` | 用户存款余额 |
| `token` | `BaseERC20` | 存款代币合约引用 |

## 事件

| 事件 | 参数 | 说明 |
|------|------|------|
| `Deposit` | `address indexed user, uint256 amount` | 存款时触发 |
| `Withdraw` | `address indexed user, uint256 amount` | 取款时触发 |

## 构造函数

```solidity
constructor(address _BaseERC20Address)
```

部署时需传入 BaseERC20 代币合约地址。

## 函数

### deposit（传统存款）

```solidity
function deposit(uint256 amount) external
```

**要求**：用户需先调用 BaseERC20 的 `approve` 授权 TokenBank 使用其代币。

**流程**：
1. `approve(TokenBank地址, amount)` — 用户授权
2. `deposit(amount)` — 从用户钱包转账到银行，记录存款余额

| 参数 | 说明 |
|------|------|
| `amount` | 存款金额（最小单位 wei） |

| 异常 | 条件 |
|------|------|
| `"TokenBank: amount is 0"` | 金额为 0 |
| `"TokenBank: msg.sender insufficient balance"` | 用户余额不足 |
| `"TokenBank: deposit failed"` | transferFrom 失败 |

---

### permitDeposit（签名一步存款）

```solidity
function permitDeposit(
    address owner,
    uint256 amount,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) external
```

**核心功能**：通过 EIP-2612 离线签名，将「授权 + 存款」合并为一笔交易。

**流程**：
1. 用户在前端输入存款金额
2. 钱包弹出 EIP-712 签名请求（无需 gas）
3. 签名后获得 `v, r, s`
4. 调用 `permitDeposit`，合约内部先执行 `permit` 授权，再执行 `transferFrom` 存款

**调用者不限**：`msg.sender` 可以是任何人（支持中继器代付 gas），因为签名证明了 owner 的授权意愿。

| 参数 | 说明 |
|------|------|
| `owner` | 代币持有者地址 |
| `amount` | 存款金额 |
| `deadline` | 签名过期时间（Unix 时间戳） |
| `v` | EIP-712 签名 recovery id |
| `r` | EIP-712 签名 r |
| `s` | EIP-712 签名 s |

---

### withdraw（取款）

```solidity
function withdraw(uint256 amount) external
```

| 参数 | 说明 |
|------|------|
| `amount` | 取款金额 |

| 异常 | 条件 |
|------|------|
| `"TokenBank: amount must be > 0"` | 金额为 0 |
| `"TokenBank: amount is invalid"` | 存款余额不足 |

---

### 查询函数

| 函数 | 说明 |
|------|------|
| `getDepositBalance(address user)` | 查询指定用户的存款余额 |
| `getTotalBalance()` | 查询银行持有的代币总量 |
| `getTokenInfo()` | 返回代币的 `(name, symbol, decimals)` |

## 两种存款方式对比

| | 传统存款 | 签名存款 (permitDeposit) |
|------|------|------|
| 交易笔数 | 2 (approve + deposit) | 1 |
| 签名 | 无 | EIP-712 钱包签名 |
| gas 费 | 两次 | 一次 |
| 用户体验 | 需要先授权 | 签名即存款，一步完成 |
| 能否代付 gas | 否 | 是（中继器可代调用） |
