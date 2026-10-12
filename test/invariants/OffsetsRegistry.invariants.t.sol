// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OffsetsToken} from "../../src/OffsetsToken.sol";
import {OffsetsRegistry} from "../../src/OffsetsRegistry.sol";
import {MockSeats} from "../mocks/MockSeats.sol";
import {OffsetsRegistryHandler} from "./OffsetsRegistryHandler.sol";

/// @notice Invariants of the registry under random sequences of records, voids, funding, seat
/// transfers, re-configuration and token movements by several actors.
/// @dev The handler asserts per-call postconditions (who may do what, exact token movement); these
/// functions check the aggregate accounting after every call against the handler's ghost model.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract OffsetsRegistryInvariantTest is Test {
    OffsetsRegistryHandler handler;
    OffsetsToken token;
    OffsetsRegistry registry;
    MockSeats seats;

    function setUp() public {
        handler = new OffsetsRegistryHandler();
        token = handler.token();
        registry = handler.registry();
        seats = handler.seats();
        targetContract(address(handler));
    }

    /// @dev Nothing in the registry's life changes the token supply.
    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), handler.SUPPLY());
    }

    /// @dev Every token is in a known hand: the supply is conserved across the harness's holders.
    function invariant_everyTokenIsAccountedFor() public view {
        address[] memory all = handler.allTokenHolders();
        uint256 sum;
        for (uint256 i; i < all.length; ++i) {
            sum += token.balanceOf(all[i]);
        }
        assertEq(sum, handler.SUPPLY(), "tokens leaked out of the harness");
    }

    /// @dev The registry never custodies OFFSETS: funding goes straight to the beneficiary.
    function invariant_registryHoldsNothing() public view {
        assertEq(token.balanceOf(address(registry)), 0);
    }

    /// @dev Live footprint network-wide equals the ghost model and equals the sum over seats.
    function invariant_totalFootprintMatchesSeatsAndModel() public view {
        assertEq(registry.totalFootprint(), handler.ghostLiveFootprint(), "totalFootprint drifted from the model");
        uint256 sum;
        uint256 jobsSum;
        for (uint256 seatId; seatId <= handler.SEAT_COUNT() + 1; ++seatId) {
            OffsetsRegistry.SeatAccount memory acct = registry.seatAccount(seatId);
            assertEq(acct.footprint, handler.ghostSeatFootprint(seatId), "a seat's footprint drifted");
            assertEq(acct.jobs, handler.ghostSeatJobs(seatId), "a seat's live job count drifted");
            sum += acct.footprint;
            jobsSum += acct.jobs;
        }
        assertEq(sum, registry.totalFootprint(), "seat footprints do not add up to the total");
        assertEq(jobsSum, handler.ghostLiveJobs(), "seat job counts do not add up to the live count");
    }

    /// @dev totalJobs counts every record ever posted; voiding never lowers it.
    function invariant_totalJobsIsHistorical() public view {
        assertEq(registry.totalJobs(), handler.ghostRecordedCount());
        assertGe(registry.totalJobs(), handler.ghostLiveJobs());
    }

    /// @dev Funding totals equal the sum over seats and equal what the beneficiaries received.
    function invariant_fundingMatchesBeneficiaries() public view {
        assertEq(registry.totalFunded(), handler.ghostTotalFunded(), "totalFunded drifted from the model");
        uint256 sum;
        for (uint256 seatId; seatId <= handler.SEAT_COUNT() + 1; ++seatId) {
            uint256 funded = registry.seatAccount(seatId).funded;
            assertEq(funded, handler.ghostSeatFunded(seatId), "a seat's funding drifted");
            sum += funded;
        }
        assertEq(sum, registry.totalFunded(), "seat funding does not add up to the total");

        uint256 received;
        uint256 n = handler.beneficiariesLength();
        for (uint256 i; i < n; ++i) {
            address b = handler.beneficiaries(i);
            assertEq(token.balanceOf(b), handler.ghostBeneficiaryReceived(b), "a beneficiary's balance drifted");
            received += token.balanceOf(b);
        }
        assertEq(received, registry.totalFunded(), "beneficiaries hold something other than the funded total");
    }

    /// @dev A record, once posted, is immutable except for its voided flag, and that flag never clears.
    function invariant_recordsAreImmutableAndVoidIsFinal() public view {
        uint256 n = handler.jobIdsLength();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.jobIds(i);
            OffsetsRegistry.Job memory job = registry.job(id);
            (uint256 seatId, uint128 measure, uint128 footprint, uint64 recordedAt, bytes32 record) =
                handler.ghostSnapshot(id);
            assertEq(job.seatId, seatId, "seatId changed after recording");
            assertEq(job.measure, measure, "measure changed after recording");
            assertEq(job.footprint, footprint, "footprint changed after recording");
            assertEq(job.recordedAt, recordedAt, "recordedAt changed after recording");
            assertEq(job.record, record, "record pointer changed after recording");
            assertGt(job.recordedAt, 0, "a recorded job reads as unknown");
            assertEq(job.voided, handler.ghostVoided(id), "voided flag disagrees with the model");
        }
    }

    /// @dev A job id never recorded reads as unknown, so nothing phantom accrues.
    function invariant_unrecordedIdsStayUnknown() public view {
        for (uint256 s; s < handler.JOB_ID_SPACE(); ++s) {
            bytes32 id = keccak256(abi.encode("job", s));
            if (!handler.ghostRecorded(id)) {
                assertEq(registry.job(id).recordedAt, 0, "an unrecorded id has a record");
            }
        }
    }

    /// @dev The derived views agree with the stored accounting at the current rate.
    function invariant_viewsAgreeWithAccounting() public view {
        uint256 rate = registry.contributionRate();
        assertEq(rate, handler.ghostRate());
        assertEq(registry.footprintFactor(), handler.ghostFactor());
        assertEq(registry.beneficiary(), handler.ghostBeneficiary());
        assertEq(registry.recorder(), handler.ghostRecorder());
        assertEq(registry.owner(), handler.owner(), "ownership moved");
        for (uint256 seatId; seatId <= handler.SEAT_COUNT() + 1; ++seatId) {
            OffsetsRegistry.SeatAccount memory acct = registry.seatAccount(seatId);
            uint256 suggested = acct.footprint * rate;
            assertEq(registry.suggestedContribution(seatId), suggested);
            uint256 outstanding = registry.outstanding(seatId);
            assertEq(outstanding, acct.funded >= suggested ? 0 : suggested - acct.funded);
            uint256 coverage = registry.coverageBps(seatId);
            if (suggested == 0) {
                assertEq(coverage, 0, "a seat with no footprint must read zero coverage");
            } else {
                assertEq(coverage, (acct.funded * registry.BPS()) / suggested);
                // Fully covered exactly when nothing is outstanding.
                assertEq(coverage >= registry.BPS(), outstanding == 0, "coverage and outstanding disagree");
            }
        }
        uint256 networkSuggested = registry.totalFootprint() * rate;
        assertEq(
            registry.networkCoverageBps(),
            networkSuggested == 0 ? 0 : (registry.totalFunded() * registry.BPS()) / networkSuggested
        );
    }

    /// @dev Configuration that was complete stays complete: no action in the handler can unset the
    /// seat NFT, the factor or the rate, and the beneficiary is only ever replaced by another.
    function invariant_staysConfigured() public view {
        assertTrue(registry.isConfigured());
        assertEq(address(registry.seats()), address(seats));
    }
}
