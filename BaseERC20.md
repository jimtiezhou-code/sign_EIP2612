# BaseERC20 合约

## 概述

BaseERC20 是基于 OpenZeppelin 实现的 ERC-20 代币合约，支持 **EIP-2612 (ERC20Permit)** 离线签名授权。

## 继承链

```
ERC20 → ERC20Permit → BaseERC20
           └── EIP712
           └── Nonces
           └── IERC20Permit
```

- `ERC20` — 标准 ERC-20 代币（转账、授权、余额查询等）
- `ERC20Permit` — EIP-2612 实现，支持链下签名授权
- `EIP712` — EIP-712 类型化数据签名
- `Nonces` — 防签名重放攻击的 nonce 管理

## 构造函数

```solidity
constructor() ERC20("BaseERC20", "BERC20") ERC20Permit("BaseERC20")
```

| 参数 | 说明 |
|------|------|
| name | `"BaseERC20"` |
| symbol | `"BERC20"` |
| decimals | `18` |
| 初始供应量 | 1 亿枚，全部铸造给部署者 |

## ERC-20 标准函数

| 函数 | 说明 |
|------|------|
| `name()` | 返回代币名称 |
| `symbol()` | 返回代币符号 |
| `decimals()` | 返回精度 (18) |
| `totalSupply()` | 返回总供应量 |
| `balanceOf(address)` | 查询地址余额 |
| `transfer(to, amount)` | 转账 |
| `transferFrom(from, to, amount)` | 授权转账 |
| `approve(spender, amount)` | 授权额度 |
| `allowance(owner, spender)` | 查询授权额度 |

## EIP-2612 函数 (ERC20Permit)

| 函数 | 说明 |
|------|------|
| `permit(owner, spender, value, deadline, v, r, s)` | 通过签名完成授权，无需发起 approve 交易 |
| `nonces(owner)` | 查询地址当前 nonce |
| `DOMAIN_SEPARATOR()` | 返回 EIP-712 域名分隔符 |

### permit 签名结构

```
Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)
```

### EIP-712 Domain

```
name:     "BaseERC20"
version:  "1"
chainId:  部署网络的 chainId
verifyingContract: BaseERC20 合约地址
```

## 自定义函数

### transferWithCallback

```solidity
function transferWithCallback(address _to, uint256 _value) public returns (bool success)
```

向合约地址转账时，会调用接收方的 `tokensReceived(from, amount)` 回调，类似 ERC-777 的 `tokensReceived` 钩子。接收方合约需实现 `ITokenReceiver` 接口：

```solidity
interface ITokenReceiver {
    function tokensReceived(address from, uint256 amount) external returns (bool);
}
```

## 安全特性

- 基于 OpenZeppelin 审计过的合约代码
- Nonce 机制防止签名重放攻击
- Permit 支持 deadline 过期时间
- transferWithCallback 仅对合约地址触发回调，EOA 地址不受影响
