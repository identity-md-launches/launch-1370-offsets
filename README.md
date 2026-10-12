# OFFSETS

A custom token launch on Ethereum (chain id 1): the **OFFSETS** token and the **OffsetsRegistry**,
which estimates the footprint of the network's own public job records, attributes each estimate to
the NFT seat that did the work, and lets that seat's holder fund a regenerative contribution in
OFFSETS.

| Contract (Solidity name) | File | Role |
| --- | --- | --- |
| `OffsetsToken` | `src/OffsetsToken.sol` | The token. Name `OFFSETS`, symbol `OFFSETS`, 18 decimals, 1,000,000,000 tokens minted once to the deployer. |
| `OffsetsRegistry` | `src/OffsetsRegistry.sol` | Job records, footprint estimates, seat attribution, and funding of contributions. |

Both Solidity names are under 32 characters. No library the contracts call is public or external,
so the bytecode has no link placeholders.

## The token

`OffsetsToken` is a plain OpenZeppelin v5 ERC-20. Its constructor mints the whole supply,
`1_000_000_000 * 1e18` minor units, to `msg.sender`, which at launch is the IMD factory. It has no
owner, no mint, no burn-from, no pause, no blocklist, no fee and no transfer hook. The supply can
never grow after launch, and nothing but a holder's own signature can move or freeze a holder's
balance. Every launch flow (factory to distributor, distributor to claimant, factory to pool,
trades through the Uniswap v4 PoolManager) moves exactly the amount asked for.

The constructor takes no arguments and calls no contract.

## The registry

### What it does

1. **Estimates.** The recorder (or the owner) posts a public job record with `recordJob(jobId,
   seatId, measure, record)`. `measure` is the measured work in the recorder's unit (for example
   compute-seconds); `record` is an opaque pointer to the public record (a content hash). The
   registry estimates the job's footprint with the owner-set factor:

   `footprint = measure * footprintFactor / FACTOR_SCALE` with `FACTOR_SCALE = 1e6`.

   A factor of `2_500_000` means 2.5 footprint units (for example grams CO2e) per unit of measure.
   The factor in force when a job is recorded is the one that applies to it; later changes affect
   only later records. `recordJobs` posts a batch atomically.
2. **Attributes.** Footprint accrues to the seat id on the configured seat NFT, and to the
   network-wide total. A job is attributed only if the seat exists on the NFT at recording time.
   Attribution follows the seat, not whoever holds it.
3. **Corrects.** A mis-posted record can be voided once by the recorder or owner with `voidJob`,
   which backs its footprint out of the seat and the totals. The job id stays used. Funding already
   made against the seat is untouched.
4. **Suggests.** With the owner-set `contributionRate` (OFFSETS minor units per footprint unit),
   `suggestedContribution(seatId)` is the seat's live footprint times the rate, `outstanding`
   is what remains unfunded against that, and `coverageBps` is the seat's funding as basis points
   of the suggestion (10,000 is fully covered, more is over-funded, a seat with no footprint reads
   as 0). `networkCoverageBps` does the same network-wide. These views revert with
   `NotConfigured("setContributionRate")` until the rate is set.
5. **Funds.** The current holder of a seat calls `fund(seatId, amount)` after approving the
   registry for `amount` OFFSETS. The tokens go straight from the holder to the configured
   beneficiary; the registry never holds tokens. Any positive amount is accepted, with or without
   recorded footprint, above or below the suggestion. Funding is tracked per seat and in total.

### Access control

| Who | Can |
| --- | --- |
| Owner (two-step `Ownable2Step`) | Set the seat NFT, beneficiary, recorder, footprint factor and contribution rate. Record and void jobs. Transfer ownership (new owner must accept). |
| Recorder | Record and void jobs. Revoked by setting it to the zero address. |
| Seat holder | Fund a contribution against a seat they currently hold. |
| Anyone | Read everything. |

Neither owner nor recorder can move anyone's OFFSETS, change a seat's recorded funding, or redirect
funds already sent. Changing the beneficiary only affects later `fund` calls. The owner can
re-point the seat NFT; attribution already recorded is keyed by seat id and is not migrated.

### Errors

Every failure is a custom error: `NotConfigured(setting)` names the setter still needed;
`NotRecorder`, `NotSeatHolder`, `JobAlreadyRecorded`, `UnknownJob`, `JobAlreadyVoided`,
`FootprintOverflow`, `LengthMismatch`, `ZeroAddress`, `ZeroValue`. A seat id that does not exist
on the NFT surfaces as the NFT's own `ERC721NonexistentToken` error.

## Deployment parameters

The launch factory deploys both contracts from their built bytecode. Constructor arguments:

| Contract | Argument | Value |
| --- | --- | --- |
| `OffsetsToken` | none | Mints to `msg.sender` (the factory). |
| `OffsetsRegistry` | `owner_` (address) | `$owner`: the launch's owner. Never the factory. Must be non-zero. |
| `OffsetsRegistry` | `offsets` (address) | `$token`: the deployed `OffsetsToken`. Must be non-zero; not called in the constructor. |

Neither constructor calls another contract or requires code at any address, so the launch checks
can run them on an empty chain. The registry's token address is first used when someone funds.

Launch values decided by the launch (not open questions): Ethereum mainnet, paired with IMD at
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, pool fee 12500, tick spacing 60, economics
`{"poolBps":8800,"initialMarketCapWei":"2500000000000000000000","remainderTo":"0x556bbff02ea3b61431e2d80e4845a90db4526352"}`.
The manifest step writes `launch.json`; this repository does not.

`script/Deploy.s.sol` is a reference deployment for a local chain or a testnet only. Its `deploy`
function takes the owner as an argument and is exercised directly by `test/Deploy.t.sol`; `run`
reads `OFFSETS_OWNER` from the environment and broadcasts. On a local deployment the token's
supply lands with whoever deploys it.

## After launch

The registry is deliberately inert until the owner configures it. Each setter is `onlyOwner` and
emits an event. Until a setting is in place, every function that needs it reverts with
`NotConfigured("<setter>")`.

| Setter | Set it to | Where the owner gets it | Needed by |
| --- | --- | --- | --- |
| `setSeats(address)` | The network's seat NFT (ERC-721) whose token ids are the seats. | The requester's own seat NFT deployment. | `recordJob`, `recordJobs`, `fund` |
| `setBeneficiary(address)` | The address that receives funded contributions: the regenerative project's treasury or the account that forwards to it. | The requester's chosen regenerative partner or treasury. | `fund` |
| `setRecorder(address)` | The hot key or service that posts and voids job records. Zero revokes it; the owner can always record. | The requester's indexing/attestation operator. | `recordJob`, `recordJobs`, `voidJob` (owner may call without it) |
| `setFootprintFactor(uint256)` | Footprint units per unit of measure, times `1e6`. Example: 2.5 gCO2e per compute-second is `2_500_000`. | The requester's chosen emissions methodology for the network's compute. | `recordJob`, `recordJobs` |
| `setContributionRate(uint256)` | OFFSETS minor units suggested per footprint unit. Example: 0.001 OFFSETS per gCO2e is `1e15`. | The requester's pricing of a regenerative contribution. | `suggestedContribution`, `outstanding`, `coverageBps`, `networkCoverageBps` |

`isConfigured()` returns true once all four non-recorder settings are in place.

## Operational responsibilities

- **Owner key.** Holds every setting above and may record or void jobs. Use a multisig or a
  timelock; ownership transfer is two-step so a typo cannot strand the registry.
- **Recorder.** Trusted to post honest measures with the right seat ids and to void only genuine
  mistakes. The registry cannot verify a measure; it only estimates from it. Rotate the recorder
  with `setRecorder` if the key is exposed. Everything it posts is on-chain and auditable
  against the public record pointed to by each job's `record` field.
- **Methodology.** The footprint factor is an estimate, applied uniformly. Changing it does not
  re-estimate earlier records; publish the methodology and the date of each change. Changing the
  contribution rate changes coverage for everyone retroactively, since coverage is computed live.
- **Beneficiary.** Make sure the beneficiary address can receive and use ERC-20s before setting it.
  Funds already sent cannot be recalled by the registry.
- **Seat NFT.** The registry reads `ownerOf` from the configured NFT at each record and fund. If
  the NFT is replaced, old attribution stays under the old seat ids.
- **No custody, no pause.** The registry never holds OFFSETS and has no pause. There is nothing to
  rescue and nothing an operator can freeze.

## Assumptions

- The seat NFT is an ERC-721 whose `ownerOf` reverts for nonexistent ids (OpenZeppelin behaviour).
  An NFT that returns the zero address instead is handled too: the registry refuses to attribute
  to it.
- OFFSETS has no transfer hook, so `fund` cannot be re-entered through it. The registry still
  carries a reentrancy guard, and a test drives a hooked mock token through it.
- Measures fit in `uint128`; footprints that would exceed `uint128` revert rather than truncate.
- Job ids are the network's public job identifiers, unique per job, chosen off-chain.
- Timestamps are informational only (`recordedAt`); nothing depends on them.
- Nothing here needs randomness, oracles or price feeds.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, sets `bytecode_hash = "none"` for reproducible launch
bytecode, disables `ffi` and grants no filesystem permissions. Dependencies are vendored as plain
files under `lib/` (forge-std 1.9.7 and OpenZeppelin Contracts 5.1.0, source directories and
licences only; no submodules).

Tests never read or set environment variables and do not depend on the calling address, so they
pass in any order and in parallel.

## Security notes

Reviewed against the pinned ethskills security checklist. Tools run: `forge build`, `forge test`
(including fuzz tests at 256 runs), `forge fmt --check`, and the compiler's lints. Slither and
Mythril were not available in this environment and did not run. Tests passing are not an audit;
an independent adversarial review before release is recommended, especially of the recorder
trust model.

Items on the checklist that are open by design: there is no pause (a censorship vector avoided);
there are no swaps, oracles, proxies or signatures. Explorer verification after deployment belongs
to the network's deployer.
