# Local validation

Checked on 2026-10-10 with Foundry 1.8.5 and the compiler pinned by `foundry.toml`: Solidity 0.8.26, Cancun, optimizer 200 runs, via IR, metadata bytecode hash disabled. These are contributor self-checks, not an independent security review.

## Results

| Command | Result |
| --- | --- |
| `forge build` | Pass; 115 source files compiled with the pinned compiler. |
| `forge test -vv` | Pass; 61 checks across 10 suites, zero failures or skips. Re-run on 2026-10-11 with Foundry 1.5.1 after the KeelRelay record guard: 75 checks across 11 suites, zero failures. |
| `forge fmt --check` | Pass. |

There are 60 unit/fuzz test functions and four invariant properties, which this Foundry version reports together as one additional invariant check. Fuzz tests use 256 runs. The invariant campaign uses 128 runs of depth 64, with **8,192 calls and zero handler reverts**, and `fail_on_revert = true`.

The stateful handler trades, transfers tokens, funds baskets, distributes fees, lowers shares, changes creator status and run price, verifies work, advances time, announces/cancels/closes projects, and withdraws holder/creator/team entitlements. Its properties check:

- The sum of every basket, creator balance and team balance equals `totalOwed`; the vault covers that sum. In the modeled flow, which has no unsolicited donations, its balance equals that sum.
- All IMD that enters the vault is either still held or accounted for as paid out.
- Closed baskets equal their frozen pool minus claims; total claims never exceed `poolAtClose`.
- Creator shares only decrease, and Building slots agree with project phase.
- Pending hook fees match the hook's PoolManager IMD claims and per-token totals.
- Routers retain no swap funds, and token balances sum to the fixed supply.

A deterministic handler lifecycle test additionally proves the campaign operations can reach paid reimbursement, unpaid run recording, closing and successful holder claims.

## Regression and integration coverage

Tests cover the prior router finding directly. Its only `safeTransferFrom` uses `msg.sender` in the external swap entry point. The callback has no payer parameter, consumes a one-use request hash, requires PoolManager as caller and an active guarded swap, and transfers only funds already held by the router. Tests reject direct and forged-manager callback calls, verify another account's allowance is not used, and exercise transfer-triggered reentrancy.

Other success/failure tests cover:

- Exact hook permission bits and clone ordering; whole-supply liquidity and locked-position ownership.
- Both swap directions in both exact-input and exact-output modes, fee rounding, IMD partial-fill rejection and fee-distribution rollback.
- Quote/execution equality, tick crossings, multiple liquidity ranges, directional v4 protocol fees, ETH routes and TOKEN/IMD/TOKEN routes.
- Fee splits throughout the allowed creator-share range, inactive creators, flushing before share/status changes, and 10/90 fees after closing.
- Payment caps, zero/duplicate/unauthorized runs, shared job IDs across tokens and methods, verifier revocation and the full-run-price recording threshold.
- Both close timers, cancellation/reannouncement, previous-block snapshots, same-close-block transfers/purchases, excluded balances, zero circulating supply, claim rounding and duplicate claims.
- One Building project per creator, relaunch after close, signed-field mutation, wrong chain/factory, malformed and expired permits, EIP-1271 signers, paused/unconfigured state and UUID/metadata validation.
- Constructor deployment on an empty chain, one-time wiring, owner access checks, two-step ownership and failed/reentrant IMD transfers.

Tests require no network, fork, environment variables, FFI or filesystem permission settings. All Solidity dependencies used by the build are vendored. The live read-only mainnet address/decimals checks mentioned in the README are separate from the test suite.

## Gas and bytecode size

Measurements from the final tests:

| Measurement | Result |
| --- | ---: |
| Salt-search candidates in the isolated measurement | 5,322 |
| Salt-search gas | 784,591 |
| Average gas per candidate, including fixed overhead | 147 |
| Factory deployment candidates | 9,434 |
| Factory deployment gas, including real CREATE, salt search and hook deployment | 6,000,580 |

The salt-search fuzz test recomputes CREATE2 addresses independently, checks all permission bits and bounds gas by `200 * attempts + 2,000`. The deployment measurement retrieves init code before measuring and executes a raw `CREATE`: this avoids Foundry dynamic test linking replacing `new Contract(...)` with a gas-free `vm.deployCode` cheatcode. The number does not include a deployment transaction's intrinsic/calldata gas. Deployment addresses and the starting salt affect search length; the owner/deployer must simulate the actual constructor as described in the README.

| Production contract | Runtime bytes | Creation-code bytes, excluding constructor arguments |
| --- | ---: | ---: |
| KeelToken | 4,100 | 4,860 |
| KeelVault | 9,154 | 9,389 |
| KeelHook | 4,440 | 5,223 |
| KeelFactory | 15,707 | 22,820 |
| KeelRouter | 17,070 | 17,415 |

All runtime code is below the 24,576-byte EIP-170 limit. Factory init code including its four constructor arguments is below the 49,152-byte EIP-3860 limit. Factory tests also assert deployment-size limits.

## Review boundaries

The build's advisory lint output was reviewed. Deadline/notice timestamp comparisons implement the specified time rules. Bounded casts follow explicit bounds or v4's signed delta types. Exact balance/settlement equality checks deliberately reject inconsistent or taxed token transfers. JSON and quote loops validate bounded inputs; the CREATE2 loop is intentional and its gas is measured. Hook bytecode plus fixed-width constructor arguments has an unambiguous CREATE2 hash preimage.

Reentrancy guards protect the public money-moving operations. Callback authorization and request consumption protect the callback paths. `accrue` moves no tokens and is deliberately callable from the wired hook during an already-guarded close/share/status update. The owner check preceding some reentrancy modifiers makes no external call. Integration events after trusted v4 settlement describe completed operations; failed transactions revert their logs. Test-only time mutations use explicit launch-time offsets for the cancellation boundary regression.

Slither and Mythril were not run. No claim of an independent audit or successful production deployment is made. The README records the remaining deployment, role-management, IMD behavior, market selection and release-review responsibilities.
