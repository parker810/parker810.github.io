---
title: 钱包安全架构设计
date: 2026-09-30T17:00:00+08:00
draft: false
author: Peter
description: 把签名服务从业务进程拆出去，是为了让热钱包私钥不以明文留在业务内存里。业务服务失陷之后，签名服务还不能被当成任意交易的签名接口。
tags:
  - 热钱包
  - 签名
  - 架构
categories:
  - 钱包安全
toc:
  enable: true
  auto: true
---

热钱包要完成提现，签名这件事必须有人做。问题不在「要不要签名」，而在私钥出现在哪个进程里，以及那个进程被拿走之后还能不能决定签什么。

事件经过见 [Bitget热钱包安全事件分析](/posts/bitget-hot-wallet-incident/)。那篇文章说明资金可以被转走，同时私钥并未被导出。下面两节分别写拆分签名服务要挡住的两种风险。

## 私钥留在业务进程里

常规钱包业务服务如果自己持有私钥，密钥材料就会进入这个进程的内存。用 Java 实现时，私钥常常以字符串或字节数组放在堆上，签名完成后也不会立刻消失，要等垃圾回收。在此之前：

- 进程被调试、被注入，内存里能读到明文私钥。
- 开启了堆转储时，`HeapDump` 文件里同样能提取明文私钥。
- 业务服务的容器或主机被拿下，攻击者不必再打穿别的系统，密钥已经在这台机器上。

把签名服务单独拎出来，首先就是挡住这个风险。业务进程不再加载、解密或保存资金私钥。私钥只存在于 signer 的进程，或更好的情况是只存在于 HSM、MPC、托管密钥服务里，signer 只拿到签名结果。业务服务被攻破时，从这台机器的内存和转储里拿不到热钱包私钥。

这一步没有解决第二个问题。业务服务仍然是调用 signer 的那一方。如果 signer 只检查「是不是业务服务在调用」，失陷的业务服务就可以提交任意交易并得到有效签名。私钥还在 signer 里，钱已经可以转走。

## 失陷的业务服务变成调用方

所以签名服务还要有自己的授权边界。它不能因为调用方身份正确就签名。收款地址、资产、金额和动作必须来自一份业务服务改不了的授权。本文后面的组件划分、`WithdrawalIntent` 和接口限制，都是在做这件事。

威胁模型只覆盖这一种失陷，记为 T1：

- 失陷的是常规钱包业务服务，以及它用来调用下游的凭证。
- 仍然可信的是独立授权服务、signer、密钥存储和策略存储。

授权服务失陷、signer 失陷、队列管理面失陷、RPC 被篡改，都是别的威胁模型，不能靠这一套自动覆盖。

在 T1 下，攻击者最多做到三件事：中断服务、拖延一笔已经批准的交易、或抢先提交一笔内容完全相同的已批准交易。他不能新增提现、改收款地址或金额、重放一笔旧授权、自己选密钥，或绕过额度。从业务进程的内存和转储里，他也拿不到私钥明文。

## 组件

{{< mermaid >}}
flowchart LR
  A[独立授权服务] --> B[signer 授权账本]
  B <--> C[常规钱包业务服务]
{{< /mermaid >}}

**独立授权服务**不和业务服务共用身份、部署、存储、发布和运维权限。它自己读取账户和订单事实，执行额度与地址策略，再对规范化的 `WithdrawalIntent` 做签名。签名密钥放在独立的 KMS 或 HSM 里。

**signer**只信任这份已经验过的意图。它检查授权签名、`policyVersion`、有效期和防重放 nonce，并把意图追加进自己的账本。消息队列只负责把数据送过来，队列里的内容不算授权。

**常规钱包业务服务**按不可信调用方处理。它只能提交 `candidateTx`。即使整台机器被拿走，也不能签发新的授权，也不能改已经记下的资金意图。

## 授权意图

`WithdrawalIntent` 至少包含：

```text
WithdrawalIntent {
  intentId, orderNo, environment, network,
  sourceWalletPolicyId, assetId,
  amountInBaseUnits, destination, memoOrTag,
  allowedAction, feeBounds, policyVersion,
  issuedAt, expiresAt, replayNonce
}
```

`orderNo` 只用来关联业务订单，单独拿着它不能授权。调用方不能指定密钥。signer 用 `sourceWalletPolicyId` 在内部映射到固定账户和密钥策略，拒绝调用方传入 `keyId`、`keyAlias` 或 KMS 密文。

## signer 对外接口

业务侧只能调用：

```text
submitWithdrawal(intentId, candidateTransaction) → submissionId
```

下面这些接口不存在：

```text
decrypt(ciphertext) → privateKey
signHash(keyId, arbitraryBytes) → signature
signBytes(keyId, arbitraryBytes) → signature
selectKeyAndSign(callerSuppliedKeyId, arbitraryTransaction)
```

signer 用经审计的链解析库解析并规范化 `candidateTx`。收款方、资产、最小单位整数金额和动作类型必须与已验签的意图一致。nonce、UTXO、recent blockhash 和费用由受控的链适配器分配，或单独校验。未知字段、附加输出、附加指令、任意 calldata，以及解析有歧义的交易，一律拒绝。

链支持时，优先用 HSM、MPC 或托管密钥服务的不可导出签名，使资金私钥不以明文进入 signer 进程。托管服务不支持的链或曲线，要单独规定硬件隔离、密钥封装、最短驻留时间和用完即清。解密后的私钥不能返回给业务服务。

## 状态与广播

一笔提现只沿这条状态前进：

```text
AUTHORIZED → CLAIMED → SIGNED → QUEUED
           → BROADCAST → CONFIRMED / EXPIRED
```

幂等键是 `(intentId, canonicalTxDigest)`。签名结果先写入只追加的 outbox，再对外可见。广播结果不明时，不能另造一笔不同的交易再签一次。

signer 不直接访问公网 RPC。无密钥的广播器通过白名单 RPC 投递，观察器负责确认和对账。这样公网和节点故障不会变成签名组件的攻击面。

## 每条链要核对的内容

下面是启用某条链时，signer 必须自己核对的语义。实际启用的每条链都要有对应规则，不能只校验哈希。

| 链类型 | 必须独立核对 |
| --- | --- |
| EVM / ETH / BSC | 从受控密钥派生发送方；校验 chainId、交易类型、nonce 唯一性、原生 value，或严格解码白名单 token 合约的固定 transfer 调用；限制 gasLimit、maxFeePerGas、maxPriorityFeePerGas、access list 及扩展字段。 |
| BTC / BCH | 用可信 UTXO 数据核对 prevout 金额、脚本和所有权；只允许批准的 sighash、精确收款输出和受控找零输出；校验手续费、费率、sequence、locktime，以及 BCH 重放保护。 |
| Solana | 校验 fee payer、program ID、完整 instruction、账户地址及 writable/signer 属性、mint、金额、地址查找表和 durable nonce。recent blockhash 只检查是否仍然新鲜。 |
| TRON | 校验网络、ref block、expiration、permission_id、由密钥派生的 owner、合约类型、TRX 金额或严格解析的 TRC20 transfer calldata、合约白名单及 feeLimit。 |
| XRPL | 校验由密钥派生的 Account、Destination、DestinationTag、Amount、Sequence、Fee、LastLedgerSequence。未批准的 AccountSet、SignerListSet 等操作拒绝。 |
| Zcash | 核对透明或屏蔽收款方、金额、费用、找零策略、过期高度和全部输出，防止隐藏的附加收款方和异常价值差。 |
| Algorand | 校验 sender、receiver、asset ID、amount、fee、first/last valid。close remainder、asset close 和 rekey 必须与授权一致。 |
| Cosmos / Celestia | 校验 chain ID、account number、sequence、消息类型、denom、最小单位金额、收款地址、fee、gas 和 memo。附加消息拒绝。 |

## 优先控制

先做这些，签名服务才不会在业务服务失陷后变成开口接口。

**P0**

- 授权由独立授权服务签发。队列只传输，signer 必须验签、检查有效期并防重放。
- 不向业务调用方暴露通用签名。内部如果调用 HSM 或 KMS 的摘要签名，摘要必须由已验证交易经审计解析器生成。
- 用 `intentId` 和规范交易摘要做幂等。结果先落盘；重启或广播不确定时，禁止换一笔交易再签。
- 审批、请求、结果和 txid 写入 signer 自己的库，并同步到独立安全账户管理的、带对象锁定的审计存储。业务服务删不掉这条记录。
- 熔断只统计已通过授权验证的请求和实际出金。新地址、异常参数、跨链速度这类组合信号，按密钥、资产或链暂停，避免未认证流量把全局签名打停。恢复要独立控制面的 M-of-N 批准。

**P1**

- 单笔、单钱包、单资产、单链、钱包层级和全局额度都有滚动窗口上限。关联钱包共用预算，并检查拆单。温钱包的大额出金另要 M-of-N 批准。
- 第三方产品不能长期持有能操作钱包控制面的高权凭证。使用独立管理面、按需短时权限、短期凭证，以及最小网络可达范围。

## 怎样算做成

只把常规钱包业务服务及其调用凭证交给攻击者。独立授权服务、signer、密钥存储和策略存储保持可信。

这时攻击者可以让服务中断，可以拖住一笔已批准的交易，也可以抢先提交一笔内容相同的已批准交易。他不能新增提现，不能改变资金意图，不能重放授权，不能选择任意密钥，也不能绕过额度。
