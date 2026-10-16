# NIGHTSHIFT (SHIFT)

An immutable, fixed-supply ERC-20 implemented in `src/Nightshift.sol` using
vendored OpenZeppelin Contracts v5.1.0. Solidity dependencies are included as
ordinary files in `lib/`; builds require no dependency downloads.

| Parameter | Value |
| --- | --- |
| Solidity contract | `Nightshift` |
| Name | `NIGHTSHIFT` |
| Symbol | `SHIFT` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in base units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None |
| Initial recipient | Constructor `msg.sender` (the deploying account or factory) |

The constructor mints the entire supply once and emits the standard `Transfer`
event from the zero address. The token has no owner, roles, mint entry point,
burn entry point, proxy, upgrade mechanism, pause, blacklist, tax, or fees.
Transfers and delegated transfers deliver exactly the requested amount.

## Assumptions and ERC-20 behavior

The brief's transfer rules are interpreted as standard OpenZeppelin ERC-20
behavior. Zero-amount and self transfers are permitted. Transfers to the zero
address and approvals to the zero address revert. Insufficient balances and
allowances revert with ERC-6093 custom errors; successful writes return `true`.
An approval replaces the previous allowance, and approving zero revokes it.
Maximum `uint256` allowances are treated as unlimited and are not decremented.
`transferFrom` emits `Transfer` but does not emit `Approval` when consuming an
allowance, following OpenZeppelin v5 behavior.

All balance quantities and allowance values are base units. One SHIFT is
`10^18` base units. Supply cannot increase or decrease after construction.
No external contract calls, price feeds, addresses, or chain-specific settings
are needed by the constructor or token operations.

## Build and checks

Use Foundry with Solidity **0.8.26** installed. `foundry.toml` pins the compiler,
targets Cancun, enables the optimizer with 200 runs, and sets
`bytecode_hash = "none"`. The project does not require FFI, filesystem cheatcode
permissions, RPC access, private keys, or environment configuration.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xae86053895f8f21a75292af0b6335dacb693deba402a736ed4de6f5ed72bc33e forge test
forge fmt --check
```

Tests cover metadata, constructor issuance and events, deployment through a
factory, exact transfers, full balances, zero/self transfers, approvals and
revocation, finite and unlimited allowances, unauthorized spending, invalid
addresses, insufficient balances, rollback on failure, launch-style allocation
and claims, and absence of admin/mint/burn functions. Fuzz tests exercise transfer
round trips, allowance spending, overdrafts, and supply conservation across
32-transfer sequences. Each test creates fresh state and reads no environment
variables. The supplied protected tests depend on a separate launch harness and
are inputs for the independent verifier, not part of this standalone suite.

## Deployment and operations

Deploy the creation bytecode for `src/Nightshift.sol:Nightshift` with no encoded
constructor arguments and zero ETH value. The intended chain is Ethereum mainnet
(chain ID 1). The deploying account receives all tokens; when the launch factory
creates the contract, the factory receives the supply. The token does not use
`tx.origin`, allocate tokens to any other address, or distribute tokens during
construction. Factory distribution, liquidity seeding, and distributor claims
are ordinary fee-free ERC-20 transfers.

The launch operator is responsible for the authorized deployment, confirming
the compiler settings and deployed source/bytecode, checking metadata and the
`10^27` supply, and executing the launch's allocation and liquidity policy. The
separate launch process supplies its manifest and launch addresses; this project
does not require or produce a manifest. No deployment or broadcast is performed
by the tests.

After launch there are no owner settings or administrative duties in this token.
Holders control transfers and approvals and should grant only the allowances
they need. Transfers to the token contract or other recipients without a recovery
path can strand tokens permanently; this contract has no rescue function.
Deployers cannot reverse transfers or recover lost keys. The automated tests and
local security review are not an independent security audit; independent review
remains a release responsibility. Slither and Mythril are not part of the checks
run for this deliverable.
