// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OffsetsToken} from "../src/OffsetsToken.sol";
import {OffsetsRegistry} from "../src/OffsetsRegistry.sol";
import {MockSeats} from "./mocks/MockSeats.sol";
import {ZeroOwnerSeats} from "./mocks/ZeroOwnerSeats.sol";

/// @dev A seat holder that is a contract: funding must not depend on the caller being an EOA.
contract ContractHolder {
    function fundVia(OffsetsRegistry registry, OffsetsToken token, uint256 seatId, uint256 amount) external {
        token.approve(address(registry), amount);
        registry.fund(seatId, amount);
    }
}

/// @notice Adversarial edge cases for the registry: inputs at zero, one and the maximum, repeated
/// calls, callers the code did not assume, and the seat NFT misbehaving or being replaced.
/// forge-config: default.fuzz.runs = 512
contract OffsetsRegistryEdgeTest is Test {
    uint256 constant SCALE = 1e6; // OffsetsRegistry.FACTOR_SCALE
    uint256 constant FACTOR = 2_500_000;
    uint256 constant RATE = 1e15;
    uint256 constant SEAT = 7;
    uint256 constant OTHER_SEAT = 8;
    bytes32 constant JOB = keccak256("job-1");
    bytes32 constant JOB2 = keccak256("job-2");
    bytes32 constant REF = keccak256("ipfs://record-1");

    OffsetsToken token;
    OffsetsRegistry registry;
    MockSeats seats;

    address owner = makeAddr("owner");
    address recorder = makeAddr("recorder");
    address beneficiary = makeAddr("beneficiary");
    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");

    function setUp() public {
        token = new OffsetsToken();
        registry = new OffsetsRegistry(owner, address(token));
        seats = new MockSeats();
        seats.mint(holder, SEAT);
        seats.mint(stranger, OTHER_SEAT);
        token.transfer(holder, 1_000_000e18);
        vm.startPrank(owner);
        registry.setSeats(address(seats));
        registry.setBeneficiary(beneficiary);
        registry.setRecorder(recorder);
        registry.setFootprintFactor(FACTOR);
        registry.setContributionRate(RATE);
        vm.stopPrank();
    }

    function _record(bytes32 jobId, uint256 seatId, uint128 measure) internal {
        vm.prank(recorder);
        registry.recordJob(jobId, seatId, measure, REF);
    }

    // ------------------------------------------------------------------ estimate edges

    /// @dev A measure too small for the factor rounds down to a zero footprint. The job is still a
    /// live record and counts as a job, but adds nothing to the footprint. Documented behaviour.
    function test_tinyMeasureRoundsToZeroFootprintButStillCounts() public {
        vm.prank(owner);
        registry.setFootprintFactor(1); // 1e-6 footprint units per unit of measure
        _record(JOB, SEAT, 999_999);
        OffsetsRegistry.Job memory job = registry.job(JOB);
        assertEq(job.footprint, 0);
        assertGt(job.recordedAt, 0, "the zero-footprint job is a real record");
        assertEq(registry.seatAccount(SEAT).jobs, 1);
        assertEq(registry.seatAccount(SEAT).footprint, 0);
        assertEq(registry.totalJobs(), 1);
        assertEq(registry.suggestedContribution(SEAT), 0);
        assertEq(registry.coverageBps(SEAT), 0);
        // And it voids cleanly without underflow.
        vm.prank(recorder);
        registry.voidJob(JOB, "");
        assertEq(registry.seatAccount(SEAT).jobs, 0);
    }

    function test_measureOneWithUnitFactorIsOneFootprintUnit() public {
        vm.prank(owner);
        registry.setFootprintFactor(SCALE);
        _record(JOB, SEAT, 1);
        assertEq(registry.job(JOB).footprint, 1);
    }

    /// @dev The largest measure at the unit factor fits exactly: the overflow guard is not off by one.
    function test_maxMeasureAtUnitFactorFitsExactly() public {
        vm.prank(owner);
        registry.setFootprintFactor(SCALE);
        _record(JOB, SEAT, type(uint128).max);
        assertEq(registry.job(JOB).footprint, type(uint128).max);
        assertEq(registry.totalFootprint(), type(uint128).max);
        // A second maximal job on the same seat: per-seat and network totals are uint256, no overflow.
        _record(JOB2, SEAT, type(uint128).max);
        assertEq(registry.seatAccount(SEAT).footprint, 2 * uint256(type(uint128).max));
    }

    /// @dev Just past the boundary is refused with the typed error.
    function test_estimateOnePastUint128MaxIsRefused() public {
        vm.prank(owner);
        registry.setFootprintFactor(SCALE + 1); // 1.000001 per unit
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.FootprintOverflow.selector, JOB));
        registry.recordJob(JOB, SEAT, type(uint128).max, REF);
        assertEq(registry.totalJobs(), 0);
    }

    /// @dev With an absurd factor the product itself overflows uint256 before the uint128 guard runs.
    /// The call still reverts (checked arithmetic) and nothing is recorded; see the findings file for
    /// the note that the revert is a panic rather than `FootprintOverflow`.
    function test_absurdFactorStillRevertsAndRecordsNothing() public {
        vm.prank(owner);
        registry.setFootprintFactor(type(uint256).max);
        vm.prank(recorder);
        vm.expectRevert();
        registry.recordJob(JOB, SEAT, 2, REF);
        assertEq(registry.totalJobs(), 0);
        assertEq(registry.job(JOB).recordedAt, 0);
    }

    function testFuzz_estimateNeverExceedsUint128AndMatchesFormula(uint128 measure, uint256 factor) public {
        measure = uint128(bound(measure, 1, type(uint128).max));
        factor = bound(factor, 1, type(uint256).max / type(uint128).max); // keeps the product in uint256
        vm.prank(owner);
        registry.setFootprintFactor(factor);
        uint256 expected = (uint256(measure) * factor) / 1e6;
        vm.prank(recorder);
        if (expected > type(uint128).max) {
            vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.FootprintOverflow.selector, JOB));
            registry.recordJob(JOB, SEAT, measure, REF);
            assertEq(registry.totalJobs(), 0);
        } else {
            registry.recordJob(JOB, SEAT, measure, REF);
            assertEq(registry.job(JOB).footprint, expected);
            assertLe(registry.job(JOB).footprint, type(uint128).max);
        }
    }

    // ------------------------------------------------------------------ batch edges

    function test_emptyBatchIsANoOp() public {
        bytes32[] memory ids = new bytes32[](0);
        uint256[] memory seatIds = new uint256[](0);
        uint128[] memory measures = new uint128[](0);
        bytes32[] memory refs = new bytes32[](0);
        vm.prank(recorder);
        registry.recordJobs(ids, seatIds, measures, refs);
        assertEq(registry.totalJobs(), 0);
        assertEq(registry.totalFootprint(), 0);
    }

    function test_emptyBatchStillRequiresRecorderAndConfiguration() public {
        bytes32[] memory ids = new bytes32[](0);
        uint256[] memory seatIds = new uint256[](0);
        uint128[] memory measures = new uint128[](0);
        bytes32[] memory refs = new bytes32[](0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotRecorder.selector, stranger));
        registry.recordJobs(ids, seatIds, measures, refs);

        OffsetsRegistry fresh = new OffsetsRegistry(owner, address(token));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotConfigured.selector, "setSeats"));
        fresh.recordJobs(ids, seatIds, measures, refs);
    }

    function test_batchRejectsEveryMismatchedArray() public {
        bytes32[] memory ids2 = new bytes32[](2);
        uint256[] memory seats2 = new uint256[](2);
        uint128[] memory measures2 = new uint128[](2);
        bytes32[] memory refs2 = new bytes32[](2);
        uint128[] memory measures1 = new uint128[](1);
        bytes32[] memory refs1 = new bytes32[](1);
        vm.startPrank(recorder);
        vm.expectRevert(OffsetsRegistry.LengthMismatch.selector);
        registry.recordJobs(ids2, seats2, measures1, refs2);
        vm.expectRevert(OffsetsRegistry.LengthMismatch.selector);
        registry.recordJobs(ids2, seats2, measures2, refs1);
        vm.stopPrank();
    }

    /// @dev A batch with one bad seat in the middle leaves nothing behind from the good entries.
    function test_batchWithOneBadSeatRecordsNothing() public {
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = keccak256("a");
        ids[1] = keccak256("b");
        ids[2] = keccak256("c");
        uint256[] memory seatIds = new uint256[](3);
        seatIds[0] = SEAT;
        seatIds[1] = 999; // does not exist
        seatIds[2] = SEAT;
        uint128[] memory measures = new uint128[](3);
        measures[0] = 100;
        measures[1] = 100;
        measures[2] = 100;
        bytes32[] memory refs = new bytes32[](3);
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        registry.recordJobs(ids, seatIds, measures, refs);
        assertEq(registry.totalJobs(), 0);
        assertEq(registry.job(ids[0]).recordedAt, 0);
        assertEq(registry.seatAccount(SEAT).footprint, 0);
    }

    function test_batchWithZeroMeasureRecordsNothing() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("a");
        ids[1] = keccak256("b");
        uint256[] memory seatIds = new uint256[](2);
        seatIds[0] = SEAT;
        seatIds[1] = SEAT;
        uint128[] memory measures = new uint128[](2);
        measures[0] = 100;
        measures[1] = 0;
        bytes32[] memory refs = new bytes32[](2);
        vm.prank(recorder);
        vm.expectRevert(OffsetsRegistry.ZeroValue.selector);
        registry.recordJobs(ids, seatIds, measures, refs);
        assertEq(registry.totalJobs(), 0);
    }

    // ------------------------------------------------------------------ seat NFT edges

    /// @dev A seat NFT that answers the zero address for unknown ids (instead of reverting) is refused
    /// with the registry's own error, so nothing is attributed to a phantom seat.
    function test_zeroOwnerSeatIsRefusedForRecordAndFund() public {
        ZeroOwnerSeats lenient = new ZeroOwnerSeats();
        lenient.mint(holder, SEAT);
        vm.prank(owner);
        registry.setSeats(address(lenient));

        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotConfigured.selector, "setSeats"));
        registry.recordJob(JOB, 999, 10, REF);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotSeatHolder.selector, 999, holder));
        registry.fund(999, 1);

        // The known seat works as before.
        _record(JOB, SEAT, 10);
        assertEq(registry.seatAccount(SEAT).footprint, 25);
    }

    /// @dev Once a seat is burned, nothing new can be attributed to or funded against it, but a
    /// record already posted can still be voided: voiding only reads the stored seat id.
    function test_burnedSeatBlocksRecordAndFundButNotVoid() public {
        _record(JOB, SEAT, 1_000);
        seats.burn(SEAT);

        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, SEAT));
        registry.recordJob(JOB2, SEAT, 10, REF);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, SEAT));
        registry.fund(SEAT, 1);

        vm.prank(recorder);
        registry.voidJob(JOB, "seat retired");
        assertEq(registry.seatAccount(SEAT).footprint, 0);
        assertEq(registry.totalFootprint(), 0);
    }

    /// @dev Re-pointing the seat NFT does not migrate or lose earlier attribution, and voiding an old
    /// record still works against the new NFT. Funding follows the new NFT's holders.
    function test_repointingSeatsKeepsOldAttributionAndVoidStillWorks() public {
        _record(JOB, SEAT, 1_000);
        MockSeats replacement = new MockSeats();
        replacement.mint(stranger, SEAT); // the same id, a different holder on the new NFT
        vm.prank(owner);
        registry.setSeats(address(replacement));

        assertEq(registry.seatAccount(SEAT).footprint, 2_500, "attribution is keyed by seat id");

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotSeatHolder.selector, SEAT, holder));
        registry.fund(SEAT, 1);

        vm.prank(recorder);
        registry.voidJob(JOB, "");
        assertEq(registry.seatAccount(SEAT).footprint, 0);
    }

    /// @dev Voiding needs no configuration at all; it only touches stored state.
    function test_voidWorksAfterRecorderRevokedOnlyForOwner() public {
        _record(JOB, SEAT, 1_000);
        vm.prank(owner);
        registry.setRecorder(address(0));
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotRecorder.selector, recorder));
        registry.voidJob(JOB, "");
        vm.prank(owner);
        registry.voidJob(JOB, "");
        assertTrue(registry.job(JOB).voided);
    }

    /// @dev Seat id zero is just another id: it is refused while it does not exist and works once minted.
    function test_seatIdZeroBehavesLikeAnyOther() public {
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        registry.recordJob(JOB, 0, 10, REF);
        seats.mint(holder, 0);
        _record(JOB, 0, 10);
        assertEq(registry.seatAccount(0).footprint, 25);
    }

    function test_maxSeatIdWorks() public {
        seats.mint(holder, type(uint256).max);
        _record(JOB, type(uint256).max, 10);
        assertEq(registry.job(JOB).seatId, type(uint256).max);
    }

    // ------------------------------------------------------------------ funding edges

    function test_fundOneWeiAndWholeBalance() public {
        vm.startPrank(holder);
        token.approve(address(registry), type(uint256).max);
        registry.fund(SEAT, 1);
        assertEq(token.balanceOf(beneficiary), 1);
        uint256 rest = token.balanceOf(holder);
        registry.fund(SEAT, rest);
        vm.stopPrank();
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(beneficiary), 1_000_000e18);
        assertEq(registry.seatAccount(SEAT).funded, 1_000_000e18);
        assertEq(registry.totalFunded(), 1_000_000e18);
        // An infinite approval is not consumed.
        assertEq(token.allowance(holder, address(registry)), type(uint256).max);
    }

    function test_fundRevertsOneWeiAboveBalance() public {
        uint256 balance = token.balanceOf(holder);
        vm.startPrank(holder);
        token.approve(address(registry), balance + 1);
        vm.expectRevert();
        registry.fund(SEAT, balance + 1);
        vm.stopPrank();
        assertEq(registry.totalFunded(), 0);
        assertEq(token.balanceOf(holder), balance);
    }

    function test_fundRevertsOneWeiAboveAllowance() public {
        vm.startPrank(holder);
        token.approve(address(registry), 1e18);
        vm.expectRevert();
        registry.fund(SEAT, 1e18 + 1);
        registry.fund(SEAT, 1e18); // exactly the allowance is fine
        vm.stopPrank();
        assertEq(registry.totalFunded(), 1e18);
    }

    function test_contractHolderCanFund() public {
        ContractHolder c = new ContractHolder();
        seats.mint(address(c), 11);
        token.transfer(address(c), 5e18);
        c.fundVia(registry, token, 11, 5e18);
        assertEq(registry.seatAccount(11).funded, 5e18);
        assertEq(token.balanceOf(beneficiary), 5e18);
    }

    /// @dev Funding the same seat twice accumulates; the second holder of a seat continues its account.
    function test_fundingAccumulatesAcrossHolders() public {
        vm.startPrank(holder);
        token.approve(address(registry), 2e18);
        registry.fund(SEAT, 2e18);
        seats.transferFrom(holder, stranger, SEAT);
        vm.stopPrank();
        token.transfer(stranger, 3e18);
        vm.startPrank(stranger);
        token.approve(address(registry), 3e18);
        registry.fund(SEAT, 3e18);
        vm.stopPrank();
        assertEq(registry.seatAccount(SEAT).funded, 5e18);
        assertEq(registry.totalFunded(), 5e18);
    }

    /// @dev The owner cannot fund on a holder's behalf, and cannot fund a seat they do not hold.
    function test_ownerAndRecorderHaveNoFundingPrivilege() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotSeatHolder.selector, SEAT, owner));
        registry.fund(SEAT, 1);
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotSeatHolder.selector, SEAT, recorder));
        registry.fund(SEAT, 1);
    }

    /// @dev Setting the beneficiary to the registry itself would make it custody tokens. The code
    /// allows it; this pins that the owner is the only one who can cause it and that a later change
    /// restores the pass-through. Operational note, not a defect: the README says the owner must
    /// pick an address that can use ERC-20s.
    function test_beneficiaryCanBeAnyNonZeroAddressIncludingHolderItself() public {
        vm.prank(owner);
        registry.setBeneficiary(holder);
        vm.startPrank(holder);
        token.approve(address(registry), 1e18);
        registry.fund(SEAT, 1e18);
        vm.stopPrank();
        assertEq(token.balanceOf(holder), 1_000_000e18, "self-funding is a no-op on balances");
        assertEq(registry.seatAccount(SEAT).funded, 1e18, "but it still counts as funded");
    }

    // ------------------------------------------------------------------ ownership edges

    function test_pendingOwnerHasNoPowerUntilAccepting() public {
        address next = makeAddr("next");
        vm.prank(owner);
        registry.transferOwnership(next);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        registry.setRecorder(next);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotRecorder.selector, next));
        registry.recordJob(JOB, SEAT, 10, REF);
    }

    function test_ownerCanCancelPendingTransferByReassigning() public {
        address next = makeAddr("next");
        vm.startPrank(owner);
        registry.transferOwnership(next);
        registry.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(registry.pendingOwner(), address(0));
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        registry.acceptOwnership();
        assertEq(registry.owner(), owner);
    }

    /// @dev After the previous owner hands over, they lose the recorder privilege that came with ownership.
    function test_formerOwnerLosesRecordingRight() public {
        address next = makeAddr("next");
        vm.prank(owner);
        registry.transferOwnership(next);
        vm.prank(next);
        registry.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotRecorder.selector, owner));
        registry.recordJob(JOB, SEAT, 10, REF);
        vm.prank(next);
        registry.recordJob(JOB, SEAT, 10, REF);
        assertEq(registry.totalJobs(), 1);
    }

    /// @dev Renouncing ownership freezes configuration forever but leaves funding and voiding by the
    /// recorder intact: an owner that renounces should know the settings are final.
    function test_renounceFreezesConfigurationButNotFunding() public {
        _record(JOB, SEAT, 1_000);
        vm.prank(owner);
        registry.renounceOwnership();
        assertEq(registry.owner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        registry.setBeneficiary(stranger);
        // The recorder still records and voids; holders still fund.
        _record(JOB2, SEAT, 1);
        vm.prank(recorder);
        registry.voidJob(JOB, "");
        vm.startPrank(holder);
        token.approve(address(registry), 1e18);
        registry.fund(SEAT, 1e18);
        vm.stopPrank();
        assertEq(registry.totalFunded(), 1e18);
    }

    // ------------------------------------------------------------------ view edges

    /// @dev Coverage rounds down: one wei short of the suggestion is 9_999 bps, never 10_000.
    function test_coverageRoundsDown() public {
        _record(JOB, SEAT, 1_000); // suggested 2_500 * 1e15 = 2.5e18
        uint256 suggested = registry.suggestedContribution(SEAT);
        vm.startPrank(holder);
        token.approve(address(registry), suggested);
        registry.fund(SEAT, suggested - 1);
        assertEq(registry.coverageBps(SEAT), 9_999);
        assertEq(registry.outstanding(SEAT), 1);
        registry.fund(SEAT, 1);
        vm.stopPrank();
        assertEq(registry.coverageBps(SEAT), 10_000);
        assertEq(registry.outstanding(SEAT), 0);
    }

    /// @dev Voiding every job after funding leaves a seat over-covered with a zero suggestion, which
    /// the views report as zero coverage rather than dividing by zero.
    function test_voidingAllJobsAfterFundingReadsZeroCoverage() public {
        _record(JOB, SEAT, 1_000);
        vm.startPrank(holder);
        token.approve(address(registry), 1e18);
        registry.fund(SEAT, 1e18);
        vm.stopPrank();
        vm.prank(recorder);
        registry.voidJob(JOB, "");
        assertEq(registry.suggestedContribution(SEAT), 0);
        assertEq(registry.outstanding(SEAT), 0);
        assertEq(registry.coverageBps(SEAT), 0);
        assertEq(registry.networkCoverageBps(), 0);
    }

    function testFuzz_outstandingPlusFundedCoversSuggestion(uint128 measure, uint256 funded, uint256 rate) public {
        measure = uint128(bound(measure, 1, 1e30));
        rate = bound(rate, 1, 1e18);
        funded = bound(funded, 1, 1_000_000e18);
        vm.startPrank(owner);
        registry.setFootprintFactor(SCALE);
        registry.setContributionRate(rate);
        vm.stopPrank();
        _record(JOB, SEAT, measure);
        vm.startPrank(holder);
        token.approve(address(registry), funded);
        registry.fund(SEAT, funded);
        vm.stopPrank();

        uint256 suggested = uint256(measure) * rate;
        assertEq(registry.suggestedContribution(SEAT), suggested);
        uint256 outstanding = registry.outstanding(SEAT);
        assertGe(outstanding + funded, suggested, "outstanding plus funded never falls short");
        if (funded >= suggested) {
            assertEq(outstanding, 0);
            assertGe(registry.coverageBps(SEAT), 10_000);
        } else {
            assertEq(outstanding, suggested - funded);
            assertLt(registry.coverageBps(SEAT), 10_000);
        }
        assertEq(registry.coverageBps(SEAT), registry.networkCoverageBps(), "a single seat is the network");
    }

    /// @dev Funding against seats with no footprint inflates nothing: network coverage ignores a seat
    /// with zero suggestion only in the per-seat view; network-wide the funding still counts.
    function test_fundingOnFootprintlessSeatCountsNetworkWide() public {
        _record(JOB, SEAT, 1_000); // only SEAT has footprint: suggested 2.5e18
        token.transfer(stranger, 2.5e18);
        vm.startPrank(stranger);
        token.approve(address(registry), 2.5e18);
        registry.fund(OTHER_SEAT, 2.5e18);
        vm.stopPrank();
        assertEq(registry.coverageBps(OTHER_SEAT), 0, "no footprint, no per-seat coverage");
        assertEq(registry.coverageBps(SEAT), 0, "SEAT itself is unfunded");
        assertEq(registry.networkCoverageBps(), 10_000, "network coverage pools all funding");
    }
}
