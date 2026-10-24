# IMD BurnTracker payer

`src/BurnTracker.sol` is the single application contract. It owns the site's payer identity at IMD Intake v2. The owner opens the initial site; anyone can fund a later refresh using the exact result document authenticated by the preceding completion callback. Callers cannot supply a replacement objective or continuation body.

This assignment delivers the contract, tests, vendored dependencies, and deployment handoff. The IdentityMD launch service creates the manifest and deploys the contract on Ethereum mainnet after acceptance. No transaction was broadcast, no deployment address is invented, and no `launch.json` is included. Building the dashboard itself is the subsequent `open(bytes)` job.

## Build and test offline

Foundry 1.8.3 and Solidity 0.8.26 were used. The compiler is pinned in the root `foundry.toml`; dependencies are ordinary files under `lib/`. There are no submodules, package downloads during compilation, FFI, environment reads in tests, or private credentials. Tests may read only `test/fixtures/`.

```sh
forge build
forge test
forge fmt --check
python3 tools/verify-results.py
```

The requested fuzz seed is pinned in `foundry.toml`:

```text
0x33a6f309d12a1ca61d39890713d8edefa39048b045c57d726a609eaee244af40
```

The build uses the Cancun code target, IR optimization with 100,000 runs, `bytecode_hash = "none"`, and isolated test transactions. The transient reentrancy guard requires EIP-1153, available on Ethereum mainnet. No application library requires linking.

## Launch parameters: seven static ABI words

Deploy **BurnTracker**, with zero ETH, on Ethereum chain **1**. Each row is exactly one 32-byte ABI word, in this order. There are no dynamic constructor arguments or initialization calls. `$owner` is resolved by the launch to its payer, as the objective names no separate owner. Never substitute the factory or `msg.sender`.

| Position | Type / argument | One ABI word |
| --- | --- | --- |
| 1 | `address owner_` | `$owner` (launch-resolved address, left-padded to 32 bytes) |
| 2 | `address intake_` | `0x000000000000000000000000a43e6f75ee006411f79ac1c84120606c2330de82` |
| 3 | `address asset_` | `0x000000000000000000000000d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| 4 | `bytes32 openAction_` | `0x6a6f622e6f70656e406a6f622d31000000000000000000000000000000000000` |
| 5 | `bytes32 continueAction_` | `0x6a6f622e636f6e74696e7565406a6f622d310000000000000000000000000000` |
| 6 | `uint32 cooldown_` | `0x0000000000000000000000000000000000000000000000000000000000015180` (86,400 seconds) |
| 7 | `uint32 staleAfter_` | `0x000000000000000000000000000000000000000000000000000000000002a300` (172,800 seconds) |

The action words are UTF-8 strings, right-padded with zero bytes, **not hashes**. The constructor does not call or require code at either dependency. Empty-chain deployment and runtime size/opcode checks are tested.

The constructor stores `{"parentJobId":"` as `bodyPrefix` and the exact remaining template as `bodySuffix`. The complete, byte-exact template is in [`test/fixtures/continuation-template.json`](test/fixtures/continuation-template.json), without a trailing newline. It has one `{{PARENT}}` marker. The constructor/template test joins the public parts around that marker and compares every byte. The default body uses an identical compiled literal to avoid reading the long suffix from cold storage on every refresh; `setBody` switches subsequent orders to the owner-edited stored parts.

## After launch

The launch service publishes the confirmed BurnTracker address and handles source verification. No protocol setting needs a post-deployment initializer.

1. The owner funds its own wallet with mainnet IMD and approves BurnTracker for the initial order's live price, read from `Intake.priceOf(openAction, asset)`. It calls `open(bytes body)` with the full initial website job body. That body must create a repository with its own `package.json` build script, produce the hosted site in `dist/`, and have the build refresh `dist/data/` or record the reason it retained data in `dist/data/imd-refresh-status.json`. The page must display that refresh time. Request the appropriate GitHub/IPFS delivery so future `import-site` continuations can build the repository. The owner is responsible for this initial objective and reviewing that site's output.
2. The owner/operator watches `Ordered`, `Updated`, `Failed`, and `ResultHashSet`, and retains the callback URI and original result document. Fetch original `result.json` bytes from the callback URI or the protocol's result endpoint. Check their keccak256 against `resultHash()`. Do **not** prettify, reserialize, or use a later changed representation of the job result.
3. Once `status().state == 2` and the cooldown has elapsed, a sponsor reads `price()`, approves BurnTracker for that IMD amount, and submits `updateBurntracker(resultJson, maxPrice)`. A higher live price reverts before **any token call**. Successful orders take exactly the live price from that sponsor, approve Intake for exactly that amount, and leave no additional payment balance or spending allowance behind.
4. If a completion callback is lost, the owner verifies the completion off chain and uses `setResultHash(hash)` when recovery is available. If a job is blocked/failed, or a pending request becomes stale, the owner may call `recover(parentJobId)` to continue a known parent. A blocked job may have no callback at all. If necessary, the owner can open a replacement hosting project after failure or stale pending work.

The Intake sees **BurnTracker** as payer for both opening and continuations. The `Ordered.payer` event field identifies the human/contract that funded that order; it is not the payer recorded by the Intake. The plane enforces project ownership and whether the parent is eligible/newest. On-chain acceptance of an order does not guarantee off-chain admission or successful work. Payments are spent immediately; refusals and failures do not refund them.

`open` and `recover` have no `maxPrice` parameter in the required ABI. The owner can bound their payment with an exact token allowance after checking the relevant live quote. Refresh sponsors should use both an appropriate allowance and `maxPrice`. A sponsor also pays transaction gas; there is no reimbursement or automatic scheduler. An operator or willing sponsors must actually submit refresh transactions.

## States and recovery

States: **UNOPENED = 1**, **IDLE = 2**, **PENDING = 3**, **STUCK = 4**. Kinds: **open = 1**, **continue = 2**, **recover = 3**. `pendingKind` is zero outside PENDING.

| Input / result | Required state | Next state / effect |
| --- | --- | --- |
| Owner `open(body)` | UNOPENED, STUCK, or stale PENDING | PENDING, kind 1; owner pays |
| Anyone `updateBurntracker(proof,maxPrice)` | IDLE, cooldown reached, valid proof and UUID | PENDING, kind 2; caller pays |
| Owner `recover(uuid)` | IDLE, STUCK, or stale PENDING | PENDING, kind 3; owner pays; bypasses cooldown |
| Owner `setResultHash(nonzeroHash)` | IDLE, STUCK, or stale PENDING | IDLE; adopts hash; restarts cooldown |
| Awaited `onResult` | PENDING | IDLE; replaces hash; restarts cooldown |
| Refused open (`onFailure`, status 1) | PENDING, kind 1 | UNOPENED |
| Refused update (`onFailure`, status 1) | PENDING, kind 2 | IDLE; keeps the previous hash; restarts cooldown |
| Refused recovery (`onFailure`, status 1) | PENDING, kind 3 | STUCK |
| Failed work (`onFailure`, status 2) | Any PENDING kind | STUCK |

There is one awaited request. Only the Intake that accepted it can settle it, once. Reconfiguring the current Intake does not change the old request's callback authority. Replacing/adopting a request invalidates its late callbacks. Staleness alone does not discard a request: its callback remains valid until the owner supersedes it.

Both timing settings are inclusive in **[3,600, 2,592,000] seconds**. A deadline is reached at `block.timestamp >= deadline`. `staleAt` is captured when an order is placed; later `setTiming` cannot shorten or extend that order's deadline. Cooldown changes immediately affect the next allowed update relative to `lastDone`.

`status()` returns the named tuple `(state,pendingKind,lastDone,orderedAt,staleAt,cooldown,staleAfter)`. `lastDone` also records a refused update or owner hash adoption, since these restart cooldown. `orderedAt` and `staleAt` retain the most recent order's times after settlement. `nextUpdateAt()` returns `lastDone + cooldown` only in IDLE and zero otherwise; zero is not permission to update. `price()` is the continuation quote; zero means that action/asset pair is not sold, and ordering it reverts.

## Trust and deliberate choices

- The owner can change the body, action identifiers, Intake/asset, and timing; recover/adopt results; withdraw accidentally sent ERC-20 tokens; and propose a new owner. Only the proposed owner can accept ownership. A later proposal replaces an earlier one. Zero ownership proposals are rejected; there is no renunciation path.
- The owner must preserve a safe, accepted template and configure an honest Intake with unique nonzero request IDs and a conventional ERC-20. `setBody` enforces the Intake's 16 KiB body limit including the 36-byte UUID; it does not validate the owner's JSON. Public callers cannot alter its parts. A fee-on-transfer/rebasing payment that changes the expected received/spent amount reverts. Standard no-return tokens are supported by vendored SafeERC20.
- The configured Intake/writer is trusted to attest the result hash. Public refresh proofs are authenticated by keccak256 of the exact bytes. Owner `setResultHash` is intentionally an explicit trust override, so the owner must verify the completion and correct project itself.
- The parser extracts one **literal** `jobId` key anywhere in canonical JSON, rejecting duplicates even across nested objects. It validates exactly 36 lowercase hexadecimal/hyphen UUID characters. It does not impose a UUID version/variant beyond that textual form. Strings with escaped quotes cannot forge keys. Escaped object keys, including Unicode-escaped aliases, are rejected; normal result schema keys are unescaped. This is a specialized extractor for the authenticated canonical result format, not a general JSON/schema validator.
- The initial `resultHash` is the nonzero sentinel `bytes32(uint256(1))`; UNOPENED prevents its use. Zero completion/adoption hashes are rejected. Failure statuses other than 1 or 2 are rejected. These choices prevent callback-written storage from ever becoming zero and reject invalid protocol responses.
- A transient guard protects all mutating entry points that can call out. Callbacks reject synchronous reentry while an order is being placed, make no external calls, and only emit their URI/reason rather than storing dynamic callback data.

## Evidence and gas

[`docs/validation.md`](docs/validation.md) maps the tests and records the measurements. Five unmodified IPFS result documents, their request/completion event logs, block/transaction identifiers, and keccak256 values are saved in [`test/fixtures/results-provenance.json`](test/fixtures/results-provenance.json). Four are completed job open/continue orders; the fifth is a completed launch job. Every document is parsed, checked against its actual completion event hash, and used as a proof for an exact-body continuation in tests.

`result-gas-4545.json` is **synthetic** stress data derived from the real 1,975-byte result: ten realistic file entries and 117 padding bytes, exactly 4,545 bytes total. It is kept separate from the authentic fixtures. `tools/make-gas-fixture.py` regenerates it deterministically.

The real-mainnet fork test uses block **26,263,700** and the actual deployed Intake v2 and IMD bytecode. It checks payment forwarding, callback selectors, exact continuation body, and the Intake's stored payer. The callback in the fork is simulated as coming from Intake; no off-chain job is created. Run it against an archive-capable RPC with:

```sh
forge test --match-contract MainnetIntakeTest \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26263700 --no-storage-caching -vv
```

Plain `forge test` requires no RPC. The same integration tests load saved real bytecode and the storage read at that pinned block from `mainnet-state.json`. This offline replay is explicitly identified in the test log; it is not a live fork or a mock Intake. `mainnet-rpc.json`, `tools/record-rpc.py`, and `tools/build-mainnet-snapshot.py` document how the snapshot was captured. The actual online fork run is recorded in `docs/mainnet-fork-run.txt`.

For the 4,545-byte update with the default template, measured gross **execution** gas is **233,165**, and settled **transaction** gas including calldata is **287,765** after the standard capped refund. Before refunds, the transaction uses **327,565** gas. Senders must use an adequate estimated gas limit; a 300,000 transaction gas limit is not sufficient just because the settled cost is below it. Owner-edited templates and future protocol/token changes can cost more. Tests assert both execution gas and settled transaction gas below 300,000. The accounting follows [Foundry's gas field definitions](https://foundry-rs.github.io/foundry/foundry_evm_core/abi/Vm/struct.Gas.html).

The callback tests forward exactly 200,000 gas and record every storage write. Each written slot was nonzero in a pristine constructor-only deployment, has a nonzero previous value, and stays nonzero. Results cost approximately 17,400–20,200 gas; failures approximately 15,200–15,400. Thus no callback incurs the assignment's approximately 111,000-gas zero-slot creation cost. The installed Foundry does not expose a `glamsterdam` runtime hardfork name; the portable slot-write assertion is the evidence for that constraint rather than a claim that this runner simulated that named fork.

The exact continuation template was submitted to the free `/requests/check` endpoint with a real completed sample parent. It returned HTTP 200 and `blockers: []`; the response is in `docs/preflight.json`. That sample belongs to another existing project and tests body/schema acceptance only. BurnTracker's production parent must come from the project this contract paid for.
