# Validation record

Checked with Foundry 1.8.3, pinned Solidity 0.8.26, optimizer/IR settings in the root `foundry.toml`, and the assignment's pinned fuzz seed. Dependencies and fixtures are vendored. No keys, environment variables, FFI, or broadcasts are used by the tests.

All **61 tests** pass (including seven fuzz properties at 512 cases each); `forge build` and `forge fmt --check` pass. Detailed local outputs are in `docs/build-run.txt` and `docs/test-run.txt`.

## Behavior coverage

| Requirement | Test evidence |
| --- | --- |
| Seven static constructor words; explicit owner; no live dependencies in constructor | `testConstructorStaticWordsAndExactTemplate`, `testConstructorWorksOnEmptyChainWithGivenMainnetAddresses`, `testConstructorRejectsInvalidStaticConfiguration` |
| Exact initial continuation template and owner changes | `testConstructorStaticWordsAndExactTemplate`, `testOwnerEditedBodyAndActionsAreUsedForUpdatesAndRecovery` |
| Owner opening; exactly one awaited order | `testOpenOnlyOwnerAndOneOrderAtATime`, `testOpenCannotReplaceCompletedSite` |
| Live price, exact allowance/payment, no retained funds | `testOpenPaysLivePriceAndContractIsPayer`, `testUpdateProofPriceExactBodyAndEvents`, real Intake integration tests |
| Price bound checked before any token interaction | `testPriceAboveMaximumRevertsBeforeAnyTokenCall` records external account access, with the token configured to fail if reached |
| Proof hash and new completions replace old proof | `testWrongProofCannotSpendTokensOrChooseParent`, `testCompletionReplacesHashAndRestartsCooldown`, mutation fuzzing |
| Real completed documents | `testRealResultDocumentsMatchMainnetHashesAndParseAndOrderExactBody` checks raw bytes against ABI-decoded mainnet completion logs for all five fixtures |
| Sole lowercase UUID; escaped strings/duplicates | Parser unit tests, UUID/duplicate/bad-byte fuzzing, native JSON decoder comparisons, word-boundary/borrow and escaped-string fuzzing |
| Cooldown and both timing limits | `testUpdateRequiresCompletionAndCooldownAtBoundary`, `testInvalidConfiguration`, `testCooldownSettingAffectsExistingIdleCompletion` |
| Refused update, open, recover | `testRefusedUpdatePreservesProofAndRestartsCooldown`, `testRefusedOpenReturnsToUnopenedAndCanRetry`, `testRefusedRecoveryGoesStuck` |
| Failed open, update, recover; open again after failure | `test_FailedOpenCanOpenAgain`, `test_FailedUpdateCanOpenAgain`, `test_FailedRecoveryCanRecoverAgain` |
| Stale recovery with fixed deadline | `testRecoveryOnlyAfterFixedStaleDeadlineAndRejectsLateCallback`, `testStaleOpenCanOpenAgain`, `testStaleRecoveryCanBeReplacedWithAnOpen` |
| Owner hash adoption and invalidated callback | `testSetResultHashInIdleStuckAndStalePending` |
| Correct Intake/request/once-only callbacks | `testCallbackAuthenticationAndOnceOnly`, `test_FailureCannotBeAnsweredTwiceOrWithResult`, `testUnknownFailureRequestCannotChangeAwaitedOrder`, `testChangingIntakeDoesNotChangePendingCallbackAuthority` |
| No unintended expiration of callback | `testCallbackStillAllowedAfterDeadlineUntilOwnerSupersedesIt` |
| 200,000 stipend, no callback slot creation | `testCallbacksWithin200kAndOnlyWriteConstructorInitializedSlots`, across successful and both failure statuses for all kinds |
| Token/Intake failure and reentrancy | `testUnpricedActionsAndPaymentFailuresRollBack`, `testFeeOnTransferTokenRejected`, `testTokenAndIntakeReentrancyCannotOrderOrSettle` |
| Owner-only configuration/withdrawal; ownership acceptance | `testAllAdministrationIsOwnerOnly`, `testSettersAndTwoStepOwnership`, `testWithdrawOnlyOwnerRecoversAccidentalTokens`, `testOwnershipProposalCanBeReplacedButOnlyLatestCandidateCanAccept` |
| Runtime deployment bounds and forbidden escape opcodes | `testRuntimeFitsDeploymentPolicy` mirrors the supplied runtime scan |
| Mainnet payer identity/payment/body | `testMainnetOpenRecordsContractAsPayerAndPaysTreasury`, `testMainnetContinuationWithRealCompletedResultProof` |
| 4,545-byte update gas | `testMainnetUpdate4545BytesUnder300k`, against real Intake/IMD bytecode |

## Mainnet and offline reproduction

Pinned chain: Ethereum (1), block 26,263,700, hash
`0x7be378408b781f75818e7db793e2c48fb2f1eeca76818c63a46ab90499b1e12c`.

The live fork was run through a read-only local RPC recorder backed by `https://ethereum-rpc.publicnode.com`. The recorder forwards only read methods and rejects transaction submission. The same integration cases also pass without a fork, using the committed bytecode and storage snapshot. The latter mode is explicitly logged as a recorded-state replay. There is no silent success/skip when a supplied live RPC fails.

To recreate the recording, start `python3 tools/record-rpc.py`, run the fork tests against `http://127.0.0.1:18545` at the pinned block with `--no-storage-caching`, stop the recorder, and run `python3 tools/build-mainnet-snapshot.py`. In a sandbox with per-command network isolation, start both processes from one shell. The upstream must still serve the pinned historical block.

The 4,545-byte fixture is generated from a real result by repeating file records and adding padding, not represented as an actual completed job. Authentic documents are separately hash-checked against the on-chain events and used as proofs, including one on the mainnet fork.

Recorded gas for the default template:

| Measurement | Gas |
| --- | ---: |
| Large update execution, before refunds and excluding intrinsic | 233,165 |
| Large update transaction, including intrinsic and before refunds | 327,565 |
| Ordinary refund counter (below the 20% cap) | 39,800 |
| Large update settled transaction gas | 287,765 |
| First result callback, including the mock caller's CALL overhead | 20,199 |
| Subsequent result callback in the exercised sequence | 17,399 |
| Failure callbacks | 15,200–15,398 |

`isolate = true` ensures the frame gas includes transaction intrinsic costs. The gas test also calculates intrinsic calldata cost, applies the 20% refund cap, and includes the separate state-gas field if the runtime reports one. No gas is paused and no token/Intake calls are mocked in the integration benchmark.

For the assignment's Glamsterdam storage constraint, the callback test observes the actual writes, checks each against an untouched constructor-only deployment, and asserts every old and new slot value is nonzero. It forwards only 200,000 gas through the mock writer's completion path. The installed runner rejected `--hardfork glamsterdam` as an unknown fork; no claim is made that this named hardfork was run. The test proves that callbacks never trigger the specified zero-slot charge.

## Local security review

Reviewed caller-bound transfers, exact approvals, token balance conservation, the pending-request authority, late/double callbacks, ownership transitions, storage preallocation, quote ordering, the parser's escape/word-boundary logic, and the default-template fast path. All mutators that interact externally are guarded; callbacks perform no external calls. Configuration changes cannot reassign the callback authority of an existing order.

The owner remains trusted to set protocol addresses/actions and safe templates and to adopt only real completions. The Intake/writer remains the result attestor, and the plane remains responsible for continuation admission, delivery and hosting. Live fork tests verify the on-chain contract integration; they do not run the plane or publish a site. Independent review and deployment/source verification remain the launch service's steps. Slither and Mythril were not run in this worker.
