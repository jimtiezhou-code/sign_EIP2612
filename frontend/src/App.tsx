import { useState, useEffect } from 'react';
import {
  useAccount,
  useConnect,
  useDisconnect,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
  useBalance,
  useSignMessage,
  useSignTypedData,
} from 'wagmi';
import { formatUnits, parseUnits, parseSignature } from 'viem';
import { baseErc20Abi } from './contracts/BaseERC20';
import { tokenBankAbi } from './contracts/TokenBank';
import { TOKEN_ADDRESS, TOKEN_BANK_ADDRESS, PERMIT2_ADDRESS } from './contracts/addresses';
import './App.scss';

interface TransferRecord {
  id: number;
  tx_hash: string;
  block_number: number;
  from_address: string;
  to_address: string;
  amount: string;
  timestamp: number;
  created_at: string;
}

function App() {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { data: ethBalance } = useBalance({ address });
  const { signMessageAsync } = useSignMessage();
  const { signTypedDataAsync } = useSignTypedData();

  const [amount, setAmount] = useState('');
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>();
  const [action, setAction] = useState<'approve' | 'deposit' | 'withdraw'>('deposit');
  const [siweAuthed, setSiweAuthed] = useState(false);
  const [siweSigning, setSiweSigning] = useState(false);
  const [transfers, setTransfers] = useState<TransferRecord[]>([]);
  const [transfersLoading, setTransfersLoading] = useState(false);
  const [permit2Nonce, setPermit2Nonce] = useState('0');

  // Read token info
  const { data: tokenName } = useReadContract({
    address: TOKEN_ADDRESS,
    abi: baseErc20Abi,
    functionName: 'name',
  });

  const { data: tokenSymbol } = useReadContract({
    address: TOKEN_ADDRESS,
    abi: baseErc20Abi,
    functionName: 'symbol',
  });

  const { data: decimals } = useReadContract({
    address: TOKEN_ADDRESS,
    abi: baseErc20Abi,
    functionName: 'decimals',
  });

  // Read token balance
  const { data: tokenBalance, refetch: refetchTokenBalance } = useReadContract({
    address: TOKEN_ADDRESS,
    abi: baseErc20Abi,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  // Read deposit balance
  const { data: depositBalance, refetch: refetchDepositBalance } = useReadContract({
    address: TOKEN_BANK_ADDRESS,
    abi: tokenBankAbi,
    functionName: 'getDepositBalance',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  // Read total bank balance
  const { data: totalBankBalance } = useReadContract({
    address: TOKEN_BANK_ADDRESS,
    abi: tokenBankAbi,
    functionName: 'getTotalBalance',
  });

  // Read allowance
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: TOKEN_ADDRESS,
    abi: baseErc20Abi,
    functionName: 'allowance',
    args: address ? [address, TOKEN_BANK_ADDRESS] : undefined,
    query: { enabled: !!address },
  });

  // Read nonce for EIP-2612 permit
  const { data: nonce } = useReadContract({
    address: TOKEN_ADDRESS,
    abi: baseErc20Abi,
    functionName: 'nonces',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  // Read Permit2 allowance
  const { data: permit2Allowance, refetch: refetchPermit2Allowance } = useReadContract({
    address: TOKEN_ADDRESS,
    abi: baseErc20Abi,
    functionName: 'allowance',
    args: address ? [address, PERMIT2_ADDRESS] : undefined,
    query: { enabled: !!address },
  });

  const { writeContract, data: writeHash, isPending: isWriting } = useWriteContract();

  const { isLoading: isWaiting, isSuccess: txSuccess } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  useEffect(() => {
    if (writeHash) {
      setTxHash(writeHash);
    }
  }, [writeHash]);

  useEffect(() => {
    if (txSuccess) {
      refetchTokenBalance();
      refetchDepositBalance();
      refetchAllowance();
      refetchPermit2Allowance();
      setTxHash(undefined);
      setAmount('');
    }
  }, [txSuccess, refetchTokenBalance, refetchDepositBalance, refetchAllowance]);

  // Reset SIWE auth and transfers when wallet account changes
  useEffect(() => {
    setSiweAuthed(false);
    setTransfers([]);
  }, [address]);

  const tokenDecimals = (decimals as number) ?? 18;

  const parsedAmount = (() => {
    try {
      return amount ? parseUnits(amount, tokenDecimals) : BigInt(0);
    } catch {
      return BigInt(0);
    }
  })();

  function handleApprove() {
    if (!parsedAmount) return;
    writeContract({
      address: TOKEN_ADDRESS,
      abi: baseErc20Abi,
      functionName: 'approve',
      args: [TOKEN_BANK_ADDRESS, parsedAmount],
    });
    setAction('approve');
  }

  function handleDeposit() {
    if (!parsedAmount) return;
    writeContract({
      address: TOKEN_BANK_ADDRESS,
      abi: tokenBankAbi,
      functionName: 'deposit',
      args: [parsedAmount],
    });
    setAction('deposit');
  }

  async function handlePermitDeposit() {
    if (!address || !parsedAmount || !chainId || nonce === undefined) return;

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

    try {
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
          name: (tokenName as string) ?? 'BaseERC20',
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

      const { r, s, v } = parseSignature(signature);

      writeContract({
        address: TOKEN_BANK_ADDRESS,
        abi: tokenBankAbi,
        functionName: 'permitDeposit',
        args: [address, parsedAmount, deadline, v, r, s],
      });
      setAction('deposit');
    } catch {
      // user rejected signature or other error
    }
  }

  async function handlePermit2Deposit() {
    if (!address || !parsedAmount || !chainId) return;

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const pnonce = BigInt(permit2Nonce || '0');

    try {
      const signature = await signTypedDataAsync({
        types: {
          TokenPermissions: [
            { name: 'token', type: 'address' },
            { name: 'amount', type: 'uint256' },
          ],
          PermitTransferFrom: [
            { name: 'permitted', type: 'TokenPermissions' },
            { name: 'spender', type: 'address' },
            { name: 'nonce', type: 'uint256' },
            { name: 'deadline', type: 'uint256' },
          ],
        } as const,
        domain: {
          name: 'Permit2',
          chainId: chainId,
          verifyingContract: PERMIT2_ADDRESS,
        },
        primaryType: 'PermitTransferFrom',
        message: {
          permitted: {
            token: TOKEN_ADDRESS,
            amount: parsedAmount,
          },
          spender: TOKEN_BANK_ADDRESS,
          nonce: pnonce,
          deadline,
        },
      });

      writeContract({
        address: TOKEN_BANK_ADDRESS,
        abi: tokenBankAbi,
        functionName: 'depositWithPermit2',
        args: [address, parsedAmount, pnonce, deadline, signature],
      });
      setAction('deposit');
    } catch {
      // user rejected or error
    }
  }

  function handlePermit2Approve() {
    writeContract({
      address: TOKEN_ADDRESS,
      abi: baseErc20Abi,
      functionName: 'approve',
      args: [PERMIT2_ADDRESS, BigInt('0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff')],
    });
    setAction('approve');
  }

  function handleWithdraw() {
    if (!parsedAmount) return;
    writeContract({
      address: TOKEN_BANK_ADDRESS,
      abi: tokenBankAbi,
      functionName: 'withdraw',
      args: [parsedAmount],
    });
    setAction('withdraw');
  }

  async function handleSIWE() {
    if (!address) return;
    setSiweSigning(true);
    try {
      const message = `TokenBank Sign-In\n\nSign this message to verify you own ${address}.\n\nNonce: ${Date.now()}`;
      await signMessageAsync({ message });
      setSiweAuthed(true);
      fetchTransfers(address);
    } catch {
      // user rejected signing
    } finally {
      setSiweSigning(false);
    }
  }

  async function fetchTransfers(addr: string) {
    setTransfersLoading(true);
    try {
      const res = await fetch(`/api/transfers/${addr}?limit=100`);
      const json = await res.json();
      if (json.success) {
        setTransfers(json.data);
      }
    } catch (err) {
      console.error('Failed to fetch transfers:', err);
    } finally {
      setTransfersLoading(false);
    }
  }

  const isProcessing = isWriting || isWaiting;
  const hasAllowance =
    allowance !== undefined &&
    (allowance as bigint) >= parsedAmount &&
    parsedAmount > BigInt(0);

  return (
    <div className="app">
      <header className="header">
        <h1 className="title">TokenBank</h1>
        <div className="wallet-section">
          {isConnected ? (
            <div className="wallet-info">
              <span className="wallet-address">
                {address?.slice(0, 6)}...{address?.slice(-4)}
              </span>
              <span className="eth-balance">
                {ethBalance ? Number(formatUnits(ethBalance.value, ethBalance.decimals)).toFixed(4) : '0'} ETH
              </span>
              {siweAuthed ? (
                <span className="siwe-badge">SIWE</span>
              ) : (
                <button
                  className="btn btn-outline btn-sm"
                  onClick={handleSIWE}
                  disabled={siweSigning}
                >
                  {siweSigning ? '签名中...' : '登录'}
                </button>
              )}
              <button className="btn btn-outline" onClick={() => disconnect()}>
                断开连接
              </button>
            </div>
          ) : (
            <button
              className="btn btn-primary"
              onClick={() => connect({ connector: connectors[0] })}
            >
              连接钱包
            </button>
          )}
        </div>
      </header>

      {isConnected && (
        <main className="main">
          <div className="card-grid">
            {/* Token Info Card */}
            <div className="card">
              <h2 className="card-title">代币信息</h2>
              <div className="info-row">
                <span className="info-label">名称</span>
                <span className="info-value">{tokenName ?? '...'}</span>
              </div>
              <div className="info-row">
                <span className="info-label">符号</span>
                <span className="info-value">{tokenSymbol ?? '...'}</span>
              </div>
              <div className="info-row">
                <span className="info-label">银行总存款</span>
                <span className="info-value">
                  {totalBankBalance !== undefined && tokenSymbol
                    ? `${formatUnits(totalBankBalance as bigint, tokenDecimals)} ${tokenSymbol}`
                    : '...'}
                </span>
              </div>
            </div>

            {/* Balance Card */}
            <div className="card">
              <h2 className="card-title">我的余额</h2>
              <div className="info-row">
                <span className="info-label">钱包余额</span>
                <span className="info-value balance">
                  {tokenBalance !== undefined && tokenSymbol
                    ? `${formatUnits(tokenBalance as bigint, tokenDecimals)} ${tokenSymbol}`
                    : '...'}
                </span>
              </div>
              <div className="info-row">
                <span className="info-label">存款余额</span>
                <span className="info-value balance highlight">
                  {depositBalance !== undefined && tokenSymbol
                    ? `${formatUnits(depositBalance as bigint, tokenDecimals)} ${tokenSymbol}`
                    : '...'}
                </span>
              </div>
              <div className="info-row">
                <span className="info-label">授权额度</span>
                <span className="info-value allowance">
                  {allowance !== undefined && tokenSymbol
                    ? `${formatUnits(allowance as bigint, tokenDecimals)} ${tokenSymbol}`
                    : '...'}
                </span>
              </div>
            </div>
          </div>

          {/* Actions Card */}
          <div className="card action-card">
            <h2 className="card-title">操作</h2>
            <div className="input-group">
              <input
                type="text"
                className="amount-input"
                placeholder="输入金额"
                value={amount}
                onChange={(e) => {
                  const v = e.target.value;
                  if (v === '' || /^\d*\.?\d*$/.test(v)) {
                    setAmount(v);
                  }
                }}
                disabled={isProcessing}
              />
              <span className="input-suffix">{tokenSymbol ?? '...'}</span>
            </div>

            {txHash && (
              <div className="tx-notice">
                <span className="spinner" />
                交易处理中...{' '}
                <code className="tx-hash">{txHash.slice(0, 10)}...</code>
              </div>
            )}

            {txSuccess && <div className="tx-notice success">交易成功!</div>}

            <div className="btn-group">
              <button
                className="btn btn-primary"
                onClick={handleApprove}
                disabled={!parsedAmount || isProcessing}
              >
                {isProcessing && action === 'approve' ? '授权中...' : '1. 授权'}
              </button>
              <button
                className="btn btn-success"
                onClick={handleDeposit}
                disabled={!hasAllowance || isProcessing}
              >
                {isProcessing && action === 'deposit' ? '存款中...' : '2. 存款'}
              </button>
              <button
                className="btn btn-danger"
                onClick={handleWithdraw}
                disabled={
                  !parsedAmount ||
                  isProcessing ||
                  !depositBalance ||
                  (depositBalance as bigint) < parsedAmount
                }
              >
                {isProcessing && action === 'withdraw' ? '取款中...' : '3. 取款'}
              </button>
            </div>

            <div className="permit-section">
              <div className="permit-divider">
                <span>或 使用签名一步完成（无需预先授权）</span>
              </div>
              <button
                className="btn btn-permit"
                onClick={handlePermitDeposit}
                disabled={
                  !parsedAmount ||
                  isProcessing ||
                  !address ||
                  !tokenBalance ||
                  (tokenBalance as bigint) < parsedAmount
                }
              >
                {isProcessing && action === 'deposit'
                  ? '处理中...'
                  : 'EIP-2612 签名存款 (Permit + Deposit)'}
              </button>
            </div>

            <div className="permit-section">
              <div className="permit-divider">
                <span>或 使用 Permit2 签名存款（需先授权 Permit2 合约）</span>
              </div>
              <div className="permit2-row">
                <label className="permit2-label">Nonce:</label>
                <input
                  type="text"
                  className="permit2-nonce-input"
                  value={permit2Nonce}
                  onChange={(e) => {
                    const v = e.target.value;
                    if (v === '' || /^\d+$/.test(v)) setPermit2Nonce(v);
                  }}
                  disabled={isProcessing}
                  placeholder="0"
                />
              </div>
              <div className="btn-group-permit2">
                <button
                  className="btn btn-outline btn-sm"
                  onClick={handlePermit2Approve}
                  disabled={!address || isProcessing}
                >
                  {isProcessing && action === 'approve' ? '授权中...' : '授权 Permit2 (一次性)'}
                </button>
                <button
                  className="btn btn-permit"
                  onClick={handlePermit2Deposit}
                  disabled={
                    !parsedAmount ||
                    isProcessing ||
                    !address ||
                    !tokenBalance ||
                    (tokenBalance as bigint) < parsedAmount ||
                    !permit2Allowance ||
                    (permit2Allowance as bigint) < parsedAmount
                  }
                >
                  {isProcessing && action === 'deposit'
                    ? '处理中...'
                    : 'Permit2 签名存款'}
                </button>
              </div>
            </div>

            <p className="hint">
              操作流程：方式一：先授权再存款（两步）；方式二：签名存款，通过钱包签名授权并一步完成存款
            </p>
          </div>

          {/* Transfer Records */}
          {siweAuthed && (
            <div className="card transfer-card">
              <div className="transfer-header">
                <h2 className="card-title">转账记录</h2>
                <button
                  className="btn btn-outline btn-sm"
                  onClick={() => address && fetchTransfers(address)}
                  disabled={transfersLoading}
                >
                  {transfersLoading ? '刷新中...' : '刷新'}
                </button>
              </div>
              {transfers.length === 0 && !transfersLoading ? (
                <p className="transfer-empty">暂无转账记录</p>
              ) : (
                <div className="transfer-table-wrapper">
                  <table className="transfer-table">
                    <thead>
                      <tr>
                        <th>交易哈希</th>
                        <th>区块</th>
                        <th>发送方</th>
                        <th>接收方</th>
                        <th>金额</th>
                      </tr>
                    </thead>
                    <tbody>
                      {transfers.map((t) => (
                        <tr key={t.id}>
                          <td className="mono">
                            {t.tx_hash.slice(0, 10)}...
                          </td>
                          <td>{t.block_number}</td>
                          <td className="mono">
                            {t.from_address.toLowerCase() === address?.toLowerCase() ? (
                              <span className="tag tag-self">自己</span>
                            ) : (
                              `${t.from_address.slice(0, 6)}...${t.from_address.slice(-4)}`
                            )}
                          </td>
                          <td className="mono">
                            {t.to_address.toLowerCase() === address?.toLowerCase() ? (
                              <span className="tag tag-self">自己</span>
                            ) : (
                              `${t.to_address.slice(0, 6)}...${t.to_address.slice(-4)}`
                            )}
                          </td>
                          <td className={`transfer-amount ${t.from_address.toLowerCase() === address?.toLowerCase() ? 'in' : 'out'}`}>
                            {t.from_address.toLowerCase() === address?.toLowerCase() ? '+' : '-'}
                            {formatUnits(BigInt(t.amount), tokenDecimals)} {tokenSymbol ?? ''}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          )}
        </main>
      )}

      {!isConnected && (
        <div className="connect-prompt">
          <div className="prompt-card">
            <h2>欢迎使用 TokenBank</h2>
            <p>请连接钱包以开始使用存款和取款功能</p>
          </div>
        </div>
      )}
    </div>
  );
}

export default App;
