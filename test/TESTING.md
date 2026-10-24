# BurnTracker test additions

These tests extend the accepted implementation and existing tests. They require only the
repository's existing Solidity dependencies and run without network access.

## Coverage

| File | Additional checks |
| --- | --- |
| `BurnTrackerInvariant.t.sol` | Four actors, two assets and two Intake instances; independent payment and donation accounting; state transitions, fixed pending deadlines, authenticated hashes, owner changes, and configuration changes across random call sequences. |
| `AdversarialPayments.t.sol` | Atomic rollback for invalid/repeated request IDs, incomplete payment consumption, and external reverts; tokens returning false, no data, or malformed data; zero-first approvals and residual allowance cleanup; synchronous callbacks during stale replacement; transient-lock release and one-order enforcement within one transaction. |
| `BoundaryRules.t.sol` | Timing limits and invalid configuration, stale/cooldown equality boundaries, callback status and metadata, live-price slippage, one-wei and maximum-uint256 payments, body/template byte limits, and ownership changes during a pending order. |
| `ResultDocumentProperties.t.sol` | Generated canonical JSON across 750–4,545 bytes, independent JSON decoding, every 32-byte alignment at both size endpoints, escaped decoys, duplicate keys, invalid UUID bytes and lengths, and exact-byte proof authentication through the payment entry point. |

The invariant handler has an independent ledger for each actor and asset. Successful orders
increase the expected treasury payment; donations and owner withdrawals are recorded separately.
Neither failure callbacks nor successful callbacks change that ledger. The tests compare it with
actual balances after every generated call and require all Intake allowances to be zero.

The state model follows the assignment's transition table, including refused opens, updates,
and recoveries. Expected timestamps, hashes, and callback authority are recorded from the
operations the handler requested, rather than copied from the contract's status. Unexpected
handler reverts fail the campaign. A deterministic scenario separately verifies that the handler
can reach payment, refusal, failure, recovery, adoption, stale replacement, asset/Intake rotation,
ownership transfer, and donation withdrawal.

Inline configuration sets the invariant campaign to **256 runs × 128 calls** and the new parser
properties to **1,000 runs each**. Inputs are bounded directly; these additions use no `vm.assume`,
environment mutation, forks, or FFI.

## Interpretation and limits

- A cooldown or stale deadline is reached at equality. Changing `staleAfter` affects future
  orders; the deadline already recorded for a pending order remains fixed.
- Body-size tests verify byte forwarding and limits. The Intake remains responsible for
  schema validation of an owner's raw body or template.
- Parser properties use canonical JSON with unescaped protocol field names. They do not
  claim that the contract implements a general JSON grammar validator.
- Callbacks use the existing mock's actual 200,000-gas call. The existing
  `ParserAndGas.t.sol` additionally records every callback storage write and checks that its
  slot was already nonzero at deployment and remains nonzero. This covers the assignment's
  zero-slot constraint without changing the repository's configured EVM version.
- The existing mainnet tests replay committed bytecode and storage snapshots offline. These
  additions do not claim a new live-mainnet fork or a deployment.

## Run

The pinned fuzz seed is
`0x33a6f309d12a1ca61d39890713d8edefa39048b045c57d726a609eaee244af40`.

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0x33a6f309d12a1ca61d39890713d8edefa39048b045c57d726a609eaee244af40 forge test --out test/scratch/out --cache-path test/scratch/cache
```

The output flags keep generated artifacts inside the assignment's disposable scratch directory.
No submitted test imports a file from scratch.
