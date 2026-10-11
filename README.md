# Keel

Ethereum mainnet launchpad contracts. Each project has a permanently locked TOKEN/IMD Uniswap v4 position. A 1% IMD swap fee funds the team, creator and continued IMD work. This deliverable contains the contracts, vendored dependencies, offline tests and operating documentation; it contains no website or deployment transaction.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, the Cancun EVM, the optimizer and IR compilation. All Solidity dependencies are ordinary files in `lib/`; no submodules, package install, RPC, environment variables, FFI or filesystem permissions are needed to build or test. Foundry and the pinned compiler must be installed by the runner. See [dependency provenance](docs/dependencies.json) for exact commits and the vendored license files for their terms.

Tests execute the real vendored v4 `PoolManager`, including its flash accounting, hook return deltas and ERC-6909 claims. A test-only IMD ERC-20 replaces the mainnet token at its fixed address. `deployCodeTo` executes constructors at the target addresses, preserving PoolManager's immutable no-delegatecall address. No fork is required. Live IMD behavior beyond the standard ERC-20 model is an external integration assumption.

## Contracts

| Contract | Responsibility |
| --- | --- |
| `KeelToken` | Fixed supply of `1e27` raw units (1 billion tokens, 18 decimals), EIP-1167 clone initialization and `Trace208` balance checkpoints. No further mint, public burn, tax, privileged transfer or upgrade. The implementation itself cannot initialize. |
| `KeelVault` | Per-project IMD accounting, verification payments, creator status/share, close notices and historical holder claims. |
| `KeelHook` | Only-factory pool initialization/liquidity addition, 1% swap fees and permissionless distribution. Deployed by the factory constructor. |
| `KeelFactory` | EIP-712 launch authorization, canonical job IDs, token cloning, pool creation and permanent liquidity locking. Starts paused. |
| `KeelRouter` | Exact-input routes between native ETH, IMD and launched tokens; deadlines, minimum outputs and read-only execution quotes. |
| `KeelRelay` | Optional vault verifier added after the launch: submits server-signed run vouchers so the caller, not the server, pays the gas. See below. |

The vault, factory and router each receive the supplied `$owner` and use OpenZeppelin 5 `Ownable2Step`. Ownership changes require `transferOwnership(newOwner)` followed by `acceptOwnership()` from the proposed owner. Their ownership is separate: transfer each contract individually. Inherited `renounceOwnership()` permanently gives up that contract's administrative powers; renouncing the vault also makes future team withdrawals unavailable.

## Deployment parameters

Only constructor deployments belong to deployment. Deploy in this order, supplying actual addresses/references:

| Solidity contract | Constructor arguments |
| --- | --- |
| `KeelToken` | None |
| `KeelVault` | `$owner` |
| `KeelFactory` | `$owner`, `$KeelVault`, `$KeelToken`, `hookSaltStart` (`uint256`) |
| `KeelRouter` | `$owner`, `$KeelFactory` |

The factory deploys the hook through CREATE2 in its constructor. Do not deploy a separate hook. Constructors do not call existing contracts or require mainnet code to be present. An empty-chain deployment test covers this constraint. No linked external libraries are needed.

`hookSaltStart` is a public search offset, not an identity, secret or service configuration. Starting at **0** is supported. The on-chain search increments the salt until all 14 hook permission bits match exactly `0x28cc`. It reuses one 85-byte CREATE2 buffer and does no allocation or code lookup per candidate. The expected length is 16,384 candidates; the actual length and deployment gas depend on the factory address, vault address, compiler output and offset. The factory exposes `hookSalt` and `hookSaltAttempts`, and emits `HookDeployed`. Simulate the exact constructor before deployment; if it exceeds the transaction gas ceiling, choose a different public starting offset. The constructor still performs the search itself. [Validation notes](docs/VALIDATION.md) record measurements from the tests.

The fixed mainnet addresses from the assignment are:

- PoolManager: `0x000000000004444c5dc75cB358380D2e3dE08A90`
- IMD: `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`
- Excluded dust/burn recipient: `0x000000000000000000000000000000000000dEaD`

IMD units use 18 decimals. Read-only mainnet calls during development returned `symbol() = "IMD"` and `decimals() = 18`; PoolManager had code (RPC head observed at block 26,158,416). These checks are not part of the offline test suite. Deploy only on Ethereum mainnet, and recheck contract identity and token transfer behavior before enabling launches.

## After launch

These are post-deployment owner transactions. No requester-owned signer, verifier or market is guessed or embedded in the constructors.

| Setter / operation | What the owner supplies and where it comes from |
| --- | --- |
| `vault.wire(factory)` | The deployed KeelFactory address from the deployment record. One use only; validates `factory.vault()`, takes `factory.hook()`, and checks the hook's factory/vault references. No registration is possible beforehand. |
| `factory.setSigner(signer)` | The IMD launch authorization operator's EOA or EIP-1271 signer contract, obtained from that operator. `revokeSigner()` disables authorization until replaced. |
| `factory.setStartTickBounds(minimum, maximum)` | Reviewed economic bounds selected by the owner. Ticks express IMD per TOKEN in v4's sorted currency order; both currencies use 18 decimals. Bounds must permit a nonempty range above the start tick. Extremely large implied liquidity is rejected by v4's per-tick capacity check. |
| `vault.setVerifier(verifier)` | The trusted swarm verification service address, obtained from that service. It may be revoked with `revokeVerifier()`. Payment and run recording revert while unset. |
| `vault.setRunPrice(price)` | Optional adjustment to the default **0.5 IMD**; allowed range is **0.1–2 IMD** inclusive. Amounts are raw 18-decimal units. |
| `router.setEthPool(fee, tickSpacing)` | The parameters of an existing, liquid, **hookless native ETH/IMD** pool verified with its liquidity provider. Defaults are fee `10000` (1% in v4 pips) and spacing `200`, but ETH routing remains disabled until the owner selects an initialized pool. The router neither creates nor funds it. |
| `factory.setPaused(false)` | Enable launches after all required setup and operational checks. `setPaused(true)` stops new launches; existing token trading and vault claims continue. |

ETH uses v4's canonical `address(0)` native-currency representation. It is not WETH. The router supports hookless ETH pools so its view quotes can reproduce execution; arbitrary third-party swap hooks and dynamic LP fees are not supported. The owner can change the fee/spacing to another existing hookless ETH/IMD pool. Minimum output and deadline protect each submitted swap against changed market conditions.

## Launch authorization and liquidity

Call:

```text
launch(name, symbol, jobRef, projectRef, creatorBps, startTick, deadline, signature, metadata)
```

The caller is the creator and must match the signed creator. `jobRef` and `projectRef` must each be 36-byte lowercase hexadecimal UUID strings with hyphens at positions 8, 13, 18 and 23. The signer must check that they identify real IMD records; syntax checking does not establish their existence. One token may ever be launched per job hash. A creator may have only one Building token; closing it permits another launch with a new job ID.

EIP-712 domain: name `KeelFactory`, version `1`, current chain ID, and the deployed factory address. The exact primary type is:

```text
Launch(address creator,bytes32 jobRef,bytes32 projectRef,bytes32 nameHash,bytes32 symbolHash,int24 startTick,uint256 deadline)
```

`jobRef`, `projectRef`, `nameHash` and `symbolHash` in this typed message are Keccak-256 hashes of the UTF-8 strings supplied to `launch`. `launchDigest(...)` exposes the digest for integration. The one-time job registry provides replay protection. Changing creator, job, project, name, symbol, tick, deadline, chain or factory invalidates the signature. The permit intentionally does not bind `creatorBps` or metadata, matching the requested signed fields; the authenticated creator chooses those at submission.

Names are 1–128 bytes, symbols 1–32 bytes. Metadata is a JSON object of at most 1,024 bytes with nonempty string fields `description` and `image`, plus `links` (an object of string URLs or an array of string URLs). Extra JSON fields are allowed, with bounded nesting. Duplicate required keys and malformed JSON are rejected. Required key names must be literal unescaped strings. Metadata is emitted only in `Launched`, with no storage copy. URLs are untrusted creator text; future clients must escape content and apply their own URL/display policy.

Clones use CREATE2 salts derived from the launch job hash until the address sorts **below IMD**. Thus TOKEN is always currency0. The v4 pool has LP fee zero, spacing 200, and the deployed Keel hook. Initial price is `TickMath.getSqrtPriceAtTick(startTick)`. The position starts at the first usable tick **strictly above** `startTick`, including when `startTick` is already aligned, and ends at tick `887200`. The whole supply is offered as token0-only liquidity; unused integer-rounding dust goes to the excluded dead address. No IMD is required from the creator to launch. The position is owned by the factory, and no factory function can remove, transfer, modify or collect it after launch. Other addresses cannot add liquidity to these pools. Donations and any position fees also remain locked.

## Fees and solvency

The Keel fee is 1% of the gross IMD side of a swap, collected in IMD in both directions:

| Swap mode | Hook accounting |
| --- | --- |
| Exact-input IMD → TOKEN | `floor(input / 100)` in `beforeSwap`; the remaining input reaches the pool. |
| Exact-input TOKEN → IMD | `floor(gross IMD output / 100)` in `afterSwap`; the recipient receives the remainder. |
| Exact-output TOKEN → IMD | The requested net IMD output is grossed up by `ceil(output / 99)` in `beforeSwap`. |
| Exact-output IMD → TOKEN | The pool's IMD input cost is grossed up by `ceil(pool input / 99)` in `afterSwap`. |

Rounding is in IMD wei. Exact-output gross-up rounds against the trader by at most one wei. Swaps with a specified IMD amount must fill that adjusted amount completely or revert, so a fee is never taken on an unfilled IMD budget. External v4 callers remain responsible for slippage checks on their own swaps. KeelRouter supports exact input only and requires full input consumption, positive output, nonzero minimum output and an unexpired deadline; otherwise the entire transaction reverts. Any Uniswap protocol fee, and the ETH pool's LP fee, is additional to the Keel hook fee.

During swaps the hook mints fully backed PoolManager ERC-6909 IMD claims to itself. `pending(token)` attributes them to each project, and `totalPending` tracks their sum. Anyone can call `hook.distribute(token)` after the PoolManager lock is released: it zeros pending accounting, burns the claims in its authenticated unlock callback, takes IMD, transfers it to the vault and calls `vault.accrue`. The whole operation is atomic on failure. A keeper should distribute regularly; there is no keeper reward.

For a Building token, each distributed fee is split as follows:

- Team: `floor(amount * 1000 / 10000)`.
- Active creator: `floor(amount * creatorBps / 10000)`, with launch share in `[0, 8000]`.
- Basket: the exact remainder. An inactive creator's share is redirected here.

`lowerCreatorShare(token, newBps)` is creator-only and requires a strict decrease. `setCreatorActive(token, active)` is owner-only. Both flush pending fees under the old configuration before changing it. The settings apply to the specific Building project. After closing, newly distributed fees pay 10% team and the full remainder to the creator, regardless of its former status or share.

Anyone may `deposit(token, amount)` into a Building basket. Creator and team balances are separate liabilities, withdrawn with `claimCreator(token)` by that creator and `claimTeam()` by the current vault owner. These functions withdraw already accrued amounts; distribute pending fees first when needed. No owner sweep or emergency basket withdrawal exists. Direct unsolicited IMD transfers are unallocated surplus and cannot be recovered by the contracts.

`totalOwed` is the sum of all basket balances (including closed, unclaimed pools), creator balances and the team balance. The vault requires backing before crediting accrued fees and checks the exact amount received on deposits. Outgoing payments decrement the corresponding liability before transferring. All IMD-moving entry points use reentrancy protection. `accrue` itself transfers no tokens and is restricted to the immutable wired hook; it deliberately remains callable during guarded share/status/close operations. The contracts assume IMD does not rebase, tax transfers or change standard ERC-20 transfer semantics.

## Verified work

Only the configured verifier can submit either function:

- `reimburse(token, jobRef, commit, amount)`: Building, active creator, globally unused nonzero job hash, nonzero commit, `0 < amount <= runPrice`, and sufficient basket. Pays the registered creator, never the verifier/caller. Emits both `Reimbursed` and `RunVerified`.
- `recordRun(token, jobRef, commit)`: Building, globally unused nonzero job hash and nonzero commit. Moves no funds and emits `RunVerified` with amount zero. It reverts when the creator is active **and the basket covers the full runPrice**.

The two methods share a global `jobUsed` registry across all launched tokens. Pass `keccak256(bytes(lowercaseUuid))` as a run's `jobRef`; this run registry is separate from launch-job uniqueness. `commit` is a nonzero bytes32 commitment chosen by the verifier's documented commit encoding (for example, a hash of the canonical commit identifier). Commit encoding must be consistent across its service and consumers.

The specified `recordRun` threshold is the full `runPrice`: an active creator with a smaller positive basket can either receive a partial reimbursement or have a zero-payment run recorded. Pending hook fees are not automatically distributed by the two verification methods. The verifier should distribute first when deciding whether a funded reimbursement is available. The verifier is trusted to verify real swarm work and commits; the contract proves authorization, uniqueness and payment limits, not off-chain work quality.

## Closing and holder claims

The vault owner calls `announceClose(token)`, may call `cancelClose(token)`, and may close only once both deadlines have passed: seven days after the most recent notice and thirty days after launch. Cancelling removes the notice; a new notice starts a new seven-day period.

`close(token)` distributes pending fees under Building rules, freezes `poolAtClose = basket`, and snapshots at `block.number - 1`. Circulating supply is fixed total supply minus the PoolManager's and dead address's balances at that same block. The creator's Building slot is released. The token and permanently locked pool continue trading.

Each holder calls `claim(token)` for itself once. Payment is:

```text
floor(poolAtClose * balanceAt(holder, snapshotBlock) / circulating)
```

Current ownership is irrelevant. Transfers or purchases in the close block do not change snapshot rights, and transferring tokens afterwards does not transfer the claim. Custodians and wrappers receive the rights associated with their own ERC-20 balances; the vault does not look through to beneficial owners. PoolManager and the dead address are explicitly excluded from claiming. If circulating supply is zero, no claims are available and the pool remains locked. Integer claim dust and never-claimed allocations also remain locked: there is no expiry, redistribution or administrative sweep. `claimable(token, holder)` reports current unpaid entitlement; zero entitlements cannot submit a successful claim.

## Integration events and quotes

Index `Launched` and `Registered` for creator/project/job/pool/token metadata; `FeePending`, `FeesDistributed`, `FeeAccrued` and `Deposited` for funding; `CreatorShareLowered` and `CreatorStatusChanged` for creator terms; `Reimbursed` and `RunVerified` for work; `CloseAnnounced`, `CloseCancelled`, `Closed` and `Claimed` for the close lifecycle; and `CreatorClaimed`, `TeamClaimed`, configuration and ownership events for payouts and administration. Standard ERC-20 transfers/approvals remain available. See the source ABIs for complete indexed fields. Indexers should process finalized receipts and handle chain reorgs.

`router.quoteExactInput(tokenIn, tokenOut, amountIn)` is a view that reads v4 state, traverses tick bitmaps, crosses initialized liquidity and reproduces v4 swap rounding and directional protocol/LP fees, then applies Keel fees. It supports direct IMD routes, ETH routes through the configured pool, and TOKEN → IMD → TOKEN routes. Quotes revert on insufficient liquidity or more than 4,096 traversal steps. They are execution estimates at the current state, **not price oracles** or guaranteed future outputs. Callers must choose minimum output and deadline; no economic decisions in the vault depend on a DEX quote.

For v4 integration background, see Uniswap's [custom accounting documentation](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting) and the pinned source under `lib/v4-core`. The shipped tests, rather than a remote quote service, check quote equality with actual execution.

## Operational trust and release review

The owner selects launch authorization, tick bounds, ETH market, verifier and run price; can stop new launches, redirect inactive creators' future shares to their baskets, and initiate closing subject to the public delays. It cannot raise a creator's chosen share, withdraw a basket, alter a closed snapshot, remove liquidity or upgrade these contracts. The signer controls launch admission; the verifier controls which eligible work is paid. Operate these roles with separately reviewed access controls and a documented key-rotation/revocation process.

Before production use, independently review the contracts and the exact deployment, verify source/bytecode and role ownership on the explorer, check IMD behavior and ETH/IMD liquidity, simulate gas for the exact constructor, and exercise the post-deployment setup. The local tests and adversarial checks are not an independent security audit. No keys, live transactions or funded wallet operations were used in this assignment.

## KeelRelay

`KeelRelay` is deployed separately, after the core contracts, and made the vault's verifier with
`KeelVault.setVerifier(relay)`. The Keel server then sends no transactions: it checks each IMD
continuation off chain and signs an EIP-712 voucher (domain `KeelRelay`, version `1`):

```
Run(address token, bytes32 jobRef, bytes32 commit, uint256 amount)
```

Anyone, normally the creator, calls `submit(token, jobRef, commit, amount, signature)` and pays its gas.

- `amount > 0`: `hook.distribute(token)` moves the pending fees into the basket, then
  `vault.reimburse(token, jobRef, commit, amount)` pays the creator recorded in the vault.
- `amount == 0`: `vault.recordRun(token, jobRef, commit)` records the run without a payout.

Every vault rule still applies (active creator, amount at most `runPrice`, enough basket, each `jobRef`
once), so a voucher cannot pay anyone but the creator and cannot be used twice. A payout voucher that
reverts with `InsufficientBasket` can be submitted again once trading has refilled the basket.

| Constructor argument | Value |
| --- | --- |
| `owner_` | the team owner |
| `vault_` | KeelVault |
| `hook_` | KeelHook (`KeelFactory.hook()`) |
| `signer_` | the server's voucher key |

The owner can rotate the key with `setSigner` or stop every outstanding voucher with `revokeSigner`.
`test/KeelRelay.t.sol` covers it against the real vault, hook and PoolManager.
