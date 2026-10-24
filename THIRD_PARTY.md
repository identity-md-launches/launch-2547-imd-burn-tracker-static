# Vendored dependencies

These are ordinary source files, with no submodules and no install step at verification time.

- **OpenZeppelin Contracts v5.2.0**: selected ERC-20 interfaces, SafeERC20, and ReentrancyGuardTransient/TransientSlot, from https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.2.0. MIT license retained in `lib/openzeppelin-contracts/LICENSE`. No OpenZeppelin concrete application is deployed.
- **forge-std v1.9.7**: `src/` from https://github.com/foundry-rs/forge-std/tree/v1.9.7. Test-only. MIT and Apache-2.0 licenses retained in `lib/forge-std/LICENSE-MIT` and `LICENSE-APACHE`. The test-local `IFrameGas` interface describes the additional Foundry 1.8 gas field; it does not modify the vendored library.
- **IIntake**: public interface copied from the task-supplied Intake client reference, with the same ABI and pragma 0.8.26.

Result JSON fixtures are public completed IdentityMD job documents. Their source IPFS URIs, retrieval URLs, and mainnet event provenance are in `test/fixtures/results-provenance.json`; they are test data, not contract code or instructions.
