// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OffsetsToken} from "../src/OffsetsToken.sol";
import {OffsetsRegistry} from "../src/OffsetsRegistry.sol";
import {MockSeats} from "./mocks/MockSeats.sol";
import {HookedToken, ITokenReceiver} from "./mocks/HookedToken.sol";

/// @dev A beneficiary that owns a seat and re-enters `fund` from inside the token transfer that pays
/// it. OFFSETS has no transfer hook, so the attempt is driven through `HookedToken`, which models a
/// token that does; the guard must hold regardless of the token.
contract ReentrantBeneficiary is ITokenReceiver {
    OffsetsRegistry public immutable registry;
    uint256 public immutable seatId;
    bool public attempted;
    bool public reentered;
    bytes public innerRevert;

    constructor(OffsetsRegistry registry_, uint256 seatId_) {
        registry = registry_;
        seatId = seatId_;
    }

    function onTokenReceived(address, uint256) external override {
        if (attempted) return;
        attempted = true;
        try registry.fund(seatId, 1) {
            reentered = true;
        } catch (bytes memory reason) {
            innerRevert = reason;
        }
    }
}

contract OffsetsRegistryTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant FACTOR = 2_500_000; // 2.5 footprint units per unit of measure
    uint256 constant RATE = 1e15; // 0.001 OFFSETS per footprint unit

    OffsetsToken token;
    OffsetsRegistry registry;
    MockSeats seats;

    address owner = makeAddr("owner");
    address recorder = makeAddr("recorder");
    address beneficiary = makeAddr("beneficiary");
    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");

    uint256 constant SEAT = 7;
    uint256 constant OTHER_SEAT = 8;
    bytes32 constant JOB = keccak256("job-1");
    bytes32 constant JOB2 = keccak256("job-2");
    bytes32 constant REF = keccak256("ipfs://record-1");

    event SeatsSet(address indexed seats);
    event BeneficiarySet(address indexed beneficiary);
    event RecorderSet(address indexed recorder);
    event FootprintFactorSet(uint256 footprintFactor);
    event ContributionRateSet(uint256 contributionRate);
    event JobRecorded(
        bytes32 indexed jobId, uint256 indexed seatId, uint128 measure, uint128 footprint, bytes32 record
    );
    event JobVoided(bytes32 indexed jobId, uint256 indexed seatId, uint128 footprint, bytes32 reason);
    event ContributionFunded(
        uint256 indexed seatId, address indexed funder, address indexed beneficiary, uint256 amount
    );

    function setUp() public {
        token = new OffsetsToken();
        registry = new OffsetsRegistry(owner, address(token));
        seats = new MockSeats();
        seats.mint(holder, SEAT);
        seats.mint(stranger, OTHER_SEAT);
        token.transfer(holder, 1_000_000e18);
    }

    function _configure() internal {
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

    // ------------------------------------------------------------------ construction

    function test_constructorSetsOwnerAndToken() public view {
        assertEq(registry.owner(), owner);
        assertEq(address(registry.OFFSETS()), address(token));
        assertEq(address(registry.seats()), address(0));
        assertEq(registry.beneficiary(), address(0));
        assertEq(registry.recorder(), address(0));
        assertEq(registry.footprintFactor(), 0);
        assertEq(registry.contributionRate(), 0);
        assertFalse(registry.isConfigured());
    }

    function test_constructorRejectsZeroOwnerAndZeroToken() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new OffsetsRegistry(address(0), address(token));
        vm.expectRevert(OffsetsRegistry.ZeroAddress.selector);
        new OffsetsRegistry(owner, address(0));
    }

    function test_constructorDoesNotRequireTokenCode() public {
        // The launch deploys on an empty chain; the token address is only used on first fund.
        OffsetsRegistry fresh = new OffsetsRegistry(owner, address(0x1234));
        assertEq(address(fresh.OFFSETS()), address(0x1234));
    }

    // ------------------------------------------------------------------ configuration

    function test_ownerSetsEverythingWithEvents() public {
        vm.startPrank(owner);
        vm.expectEmit(address(registry));
        emit SeatsSet(address(seats));
        registry.setSeats(address(seats));
        vm.expectEmit(address(registry));
        emit BeneficiarySet(beneficiary);
        registry.setBeneficiary(beneficiary);
        vm.expectEmit(address(registry));
        emit RecorderSet(recorder);
        registry.setRecorder(recorder);
        vm.expectEmit(address(registry));
        emit FootprintFactorSet(FACTOR);
        registry.setFootprintFactor(FACTOR);
        vm.expectEmit(address(registry));
        emit ContributionRateSet(RATE);
        registry.setContributionRate(RATE);
        vm.stopPrank();

        assertEq(address(registry.seats()), address(seats));
        assertEq(registry.beneficiary(), beneficiary);
        assertEq(registry.recorder(), recorder);
        assertEq(registry.footprintFactor(), FACTOR);
        assertEq(registry.contributionRate(), RATE);
        assertTrue(registry.isConfigured());
    }

    function test_settersRejectNonOwner() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(unauthorized);
        registry.setSeats(address(seats));
        vm.expectRevert(unauthorized);
        registry.setBeneficiary(beneficiary);
        vm.expectRevert(unauthorized);
        registry.setRecorder(recorder);
        vm.expectRevert(unauthorized);
        registry.setFootprintFactor(FACTOR);
        vm.expectRevert(unauthorized);
        registry.setContributionRate(RATE);
        vm.stopPrank();
    }

    function test_settersRejectZeroValues() public {
        vm.startPrank(owner);
        vm.expectRevert(OffsetsRegistry.ZeroAddress.selector);
        registry.setSeats(address(0));
        vm.expectRevert(OffsetsRegistry.ZeroAddress.selector);
        registry.setBeneficiary(address(0));
        vm.expectRevert(OffsetsRegistry.ZeroValue.selector);
        registry.setFootprintFactor(0);
        vm.expectRevert(OffsetsRegistry.ZeroValue.selector);
        registry.setContributionRate(0);
        // Revoking the recorder with zero is allowed.
        registry.setRecorder(recorder);
        registry.setRecorder(address(0));
        assertEq(registry.recorder(), address(0));
        vm.stopPrank();
    }

    function test_ownershipTransferIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(owner);
        registry.transferOwnership(next);
        assertEq(registry.owner(), owner, "owner unchanged until accepted");
        assertEq(registry.pendingOwner(), next);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.acceptOwnership();
        vm.prank(next);
        registry.acceptOwnership();
        assertEq(registry.owner(), next);
    }

    // ------------------------------------------------------------------ recording: failures

    function test_recordRevertsUntilSeatsConfigured() public {
        vm.startPrank(owner);
        registry.setFootprintFactor(FACTOR);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotConfigured.selector, "setSeats"));
        registry.recordJob(JOB, SEAT, 10, REF);
        vm.stopPrank();
    }

    function test_recordRevertsUntilFactorConfigured() public {
        vm.startPrank(owner);
        registry.setSeats(address(seats));
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotConfigured.selector, "setFootprintFactor"));
        registry.recordJob(JOB, SEAT, 10, REF);
        vm.stopPrank();
    }

    function test_recordRejectsStrangers() public {
        _configure();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotRecorder.selector, stranger));
        registry.recordJob(JOB, SEAT, 10, REF);
    }

    function test_recordRejectsRevokedRecorder() public {
        _configure();
        vm.prank(owner);
        registry.setRecorder(address(0));
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotRecorder.selector, recorder));
        registry.recordJob(JOB, SEAT, 10, REF);
    }

    function test_recordRejectsZeroMeasure() public {
        _configure();
        vm.prank(recorder);
        vm.expectRevert(OffsetsRegistry.ZeroValue.selector);
        registry.recordJob(JOB, SEAT, 0, REF);
    }

    function test_recordRejectsDuplicateJobId() public {
        _configure();
        _record(JOB, SEAT, 10);
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.JobAlreadyRecorded.selector, JOB));
        registry.recordJob(JOB, OTHER_SEAT, 10, REF);
    }

    function test_recordRejectsNonexistentSeat() public {
        _configure();
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        registry.recordJob(JOB, 999, 10, REF);
    }

    function test_recordRejectsFootprintOverflow() public {
        _configure();
        vm.prank(owner);
        registry.setFootprintFactor(type(uint256).max / type(uint128).max); // ~3.4e32 per measure
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.FootprintOverflow.selector, JOB));
        registry.recordJob(JOB, SEAT, type(uint128).max, REF);
    }

    function test_batchRecordRejectsLengthMismatch() public {
        _configure();
        bytes32[] memory ids = new bytes32[](2);
        uint256[] memory seatIds = new uint256[](1);
        uint128[] memory measures = new uint128[](2);
        bytes32[] memory refs = new bytes32[](2);
        vm.prank(recorder);
        vm.expectRevert(OffsetsRegistry.LengthMismatch.selector);
        registry.recordJobs(ids, seatIds, measures, refs);
    }

    function test_batchRecordIsAtomic() public {
        _configure();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = JOB;
        ids[1] = JOB; // duplicate inside the batch
        uint256[] memory seatIds = new uint256[](2);
        seatIds[0] = SEAT;
        seatIds[1] = SEAT;
        uint128[] memory measures = new uint128[](2);
        measures[0] = 10;
        measures[1] = 10;
        bytes32[] memory refs = new bytes32[](2);
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.JobAlreadyRecorded.selector, JOB));
        registry.recordJobs(ids, seatIds, measures, refs);
        assertEq(registry.totalJobs(), 0);
        assertEq(registry.job(JOB).recordedAt, 0);
    }

    // ------------------------------------------------------------------ recording: success

    function test_recordEstimatesAndAttributes() public {
        _configure();
        vm.warp(1_700_000_000);
        uint128 measure = 1_000;
        uint128 expected = uint128((uint256(measure) * FACTOR) / registry.FACTOR_SCALE()); // 2_500

        vm.expectEmit(address(registry));
        emit JobRecorded(JOB, SEAT, measure, expected, REF);
        _record(JOB, SEAT, measure);

        OffsetsRegistry.Job memory job = registry.job(JOB);
        assertEq(job.seatId, SEAT);
        assertEq(job.measure, measure);
        assertEq(job.footprint, 2_500);
        assertEq(job.recordedAt, 1_700_000_000);
        assertFalse(job.voided);
        assertEq(job.record, REF);

        OffsetsRegistry.SeatAccount memory seat = registry.seatAccount(SEAT);
        assertEq(seat.jobs, 1);
        assertEq(seat.footprint, 2_500);
        assertEq(seat.funded, 0);
        assertEq(registry.totalJobs(), 1);
        assertEq(registry.totalFootprint(), 2_500);
    }

    function test_ownerMayRecordWithoutBeingRecorder() public {
        _configure();
        vm.prank(owner);
        registry.recordJob(JOB, SEAT, 10, REF);
        assertEq(registry.seatAccount(SEAT).footprint, 25);
    }

    function test_recordUsesFactorInForceAtRecording() public {
        _configure();
        _record(JOB, SEAT, 1_000); // 2_500
        vm.prank(owner);
        registry.setFootprintFactor(FACTOR * 2);
        _record(JOB2, SEAT, 1_000); // 5_000
        assertEq(registry.job(JOB).footprint, 2_500, "earlier record is not re-estimated");
        assertEq(registry.job(JOB2).footprint, 5_000);
        assertEq(registry.seatAccount(SEAT).footprint, 7_500);
    }

    function test_batchRecordAttributesAcrossSeats() public {
        _configure();
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = keccak256("a");
        ids[1] = keccak256("b");
        ids[2] = keccak256("c");
        uint256[] memory seatIds = new uint256[](3);
        seatIds[0] = SEAT;
        seatIds[1] = OTHER_SEAT;
        seatIds[2] = SEAT;
        uint128[] memory measures = new uint128[](3);
        measures[0] = 100;
        measures[1] = 200;
        measures[2] = 300;
        bytes32[] memory refs = new bytes32[](3);
        vm.prank(recorder);
        registry.recordJobs(ids, seatIds, measures, refs);

        assertEq(registry.seatAccount(SEAT).jobs, 2);
        assertEq(registry.seatAccount(SEAT).footprint, 250 + 750);
        assertEq(registry.seatAccount(OTHER_SEAT).jobs, 1);
        assertEq(registry.seatAccount(OTHER_SEAT).footprint, 500);
        assertEq(registry.totalJobs(), 3);
        assertEq(registry.totalFootprint(), 1_500);
    }

    function test_recordAttributesToCurrentSeatEvenAfterTransfer() public {
        _configure();
        vm.prank(holder);
        seats.transferFrom(holder, stranger, SEAT);
        _record(JOB, SEAT, 10);
        assertEq(registry.seatAccount(SEAT).footprint, 25, "footprint follows the seat, not the holder");
    }

    // ------------------------------------------------------------------ voiding

    function test_voidBacksOutFootprint() public {
        _configure();
        _record(JOB, SEAT, 1_000);
        _record(JOB2, SEAT, 400);
        assertEq(registry.totalFootprint(), 3_500);

        vm.expectEmit(address(registry));
        emit JobVoided(JOB, SEAT, 2_500, "mis-posted");
        vm.prank(recorder);
        registry.voidJob(JOB, "mis-posted");

        assertTrue(registry.job(JOB).voided);
        assertEq(registry.seatAccount(SEAT).jobs, 1);
        assertEq(registry.seatAccount(SEAT).footprint, 1_000);
        assertEq(registry.totalFootprint(), 1_000);
        assertEq(registry.totalJobs(), 2, "the posted count is historical");
    }

    function test_voidRejectsUnknownAndRepeatedJobs() public {
        _configure();
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.UnknownJob.selector, JOB));
        registry.voidJob(JOB, "");

        _record(JOB, SEAT, 10);
        vm.prank(recorder);
        registry.voidJob(JOB, "");
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.JobAlreadyVoided.selector, JOB));
        registry.voidJob(JOB, "");
    }

    function test_voidRejectsStrangers() public {
        _configure();
        _record(JOB, SEAT, 10);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotRecorder.selector, stranger));
        registry.voidJob(JOB, "");
    }

    function test_voidedJobIdCannotBeReused() public {
        _configure();
        _record(JOB, SEAT, 10);
        vm.prank(recorder);
        registry.voidJob(JOB, "");
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.JobAlreadyRecorded.selector, JOB));
        registry.recordJob(JOB, SEAT, 10, REF);
    }

    function test_voidLeavesFundingUntouched() public {
        _configure();
        _record(JOB, SEAT, 1_000);
        vm.startPrank(holder);
        token.approve(address(registry), 1e18);
        registry.fund(SEAT, 1e18);
        vm.stopPrank();
        vm.prank(recorder);
        registry.voidJob(JOB, "");
        assertEq(registry.seatAccount(SEAT).funded, 1e18);
        assertEq(registry.totalFunded(), 1e18);
        assertEq(token.balanceOf(beneficiary), 1e18, "funds already sent stay sent");
    }

    // ------------------------------------------------------------------ funding: failures

    function test_fundRevertsUntilSeatsConfigured() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotConfigured.selector, "setSeats"));
        registry.fund(SEAT, 1);
    }

    function test_fundRevertsUntilBeneficiaryConfigured() public {
        vm.prank(owner);
        registry.setSeats(address(seats));
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotConfigured.selector, "setBeneficiary"));
        registry.fund(SEAT, 1);
    }

    function test_fundRejectsZeroAmount() public {
        _configure();
        vm.prank(holder);
        vm.expectRevert(OffsetsRegistry.ZeroValue.selector);
        registry.fund(SEAT, 0);
    }

    function test_fundRejectsNonHolder() public {
        _configure();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotSeatHolder.selector, SEAT, stranger));
        registry.fund(SEAT, 1);
    }

    function test_fundRejectsNonexistentSeat() public {
        _configure();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        registry.fund(999, 1);
    }

    function test_fundRejectsFormerHolder() public {
        _configure();
        vm.prank(holder);
        seats.transferFrom(holder, stranger, SEAT);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotSeatHolder.selector, SEAT, holder));
        registry.fund(SEAT, 1);
    }

    function test_fundRevertsWithoutAllowance() public {
        _configure();
        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(registry), 0, 1e18)
        );
        registry.fund(SEAT, 1e18);
        assertEq(registry.seatAccount(SEAT).funded, 0, "nothing recorded on a failed transfer");
        assertEq(registry.totalFunded(), 0);
    }

    function test_fundRevertsWithoutBalance() public {
        _configure();
        seats.mint(stranger, 9);
        vm.startPrank(stranger);
        token.approve(address(registry), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, 1e18));
        registry.fund(9, 1e18);
        vm.stopPrank();
    }

    function test_fundRevertsWhenTokenHasNoCode() public {
        OffsetsRegistry fresh = new OffsetsRegistry(owner, address(0x1234));
        vm.startPrank(owner);
        fresh.setSeats(address(seats));
        fresh.setBeneficiary(beneficiary);
        vm.stopPrank();
        vm.prank(holder);
        vm.expectRevert();
        fresh.fund(SEAT, 1);
    }

    // ------------------------------------------------------------------ funding: success

    function test_fundMovesTokensToBeneficiaryAndRecords() public {
        _configure();
        _record(JOB, SEAT, 1_000); // footprint 2_500 -> suggested 2_500 * 1e15 = 2.5 OFFSETS
        uint256 amount = 1e18;

        vm.startPrank(holder);
        token.approve(address(registry), amount);
        vm.expectEmit(address(registry));
        emit ContributionFunded(SEAT, holder, beneficiary, amount);
        registry.fund(SEAT, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(beneficiary), amount);
        assertEq(token.balanceOf(holder), 1_000_000e18 - amount);
        assertEq(token.balanceOf(address(registry)), 0, "the registry never custodies tokens");
        assertEq(token.allowance(holder, address(registry)), 0);
        assertEq(registry.seatAccount(SEAT).funded, amount);
        assertEq(registry.totalFunded(), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_fundAcceptsAmountsAboveSuggestionAndWithoutRate() public {
        vm.startPrank(owner);
        registry.setSeats(address(seats));
        registry.setBeneficiary(beneficiary);
        vm.stopPrank();
        // No footprint recorded and no rate set: funding is still a seat holder's prerogative.
        vm.startPrank(holder);
        token.approve(address(registry), 5e18);
        registry.fund(SEAT, 5e18);
        vm.stopPrank();
        assertEq(registry.seatAccount(SEAT).funded, 5e18);
        assertEq(token.balanceOf(beneficiary), 5e18);
    }

    function test_fundGoesToBeneficiaryInForceAtCallTime() public {
        _configure();
        address later = makeAddr("later");
        vm.startPrank(holder);
        token.approve(address(registry), 2e18);
        registry.fund(SEAT, 1e18);
        vm.stopPrank();
        vm.prank(owner);
        registry.setBeneficiary(later);
        vm.prank(holder);
        registry.fund(SEAT, 1e18);
        assertEq(token.balanceOf(beneficiary), 1e18);
        assertEq(token.balanceOf(later), 1e18);
    }

    function test_fundReentrancyIsBlocked() public {
        HookedToken hooked = new HookedToken();
        OffsetsRegistry guarded = new OffsetsRegistry(owner, address(hooked));
        uint256 evilSeat = 42;
        ReentrantBeneficiary evil = new ReentrantBeneficiary(guarded, evilSeat);
        seats.mint(address(evil), evilSeat);
        hooked.mint(holder, 10e18);
        vm.startPrank(owner);
        guarded.setSeats(address(seats));
        guarded.setBeneficiary(address(evil));
        vm.stopPrank();

        vm.startPrank(holder);
        hooked.approve(address(guarded), 1e18);
        guarded.fund(SEAT, 1e18);
        vm.stopPrank();

        assertTrue(evil.attempted(), "the hook fired");
        assertFalse(evil.reentered(), "the nested fund went through");
        assertEq(bytes4(evil.innerRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(guarded.seatAccount(SEAT).funded, 1e18);
        assertEq(guarded.seatAccount(evilSeat).funded, 0);
        assertEq(guarded.totalFunded(), 1e18);
        assertEq(hooked.balanceOf(address(evil)), 1e18);
    }

    // ------------------------------------------------------------------ views

    function test_suggestionViewsRevertUntilRateConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotConfigured.selector, "setContributionRate"));
        registry.suggestedContribution(SEAT);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotConfigured.selector, "setContributionRate"));
        registry.outstanding(SEAT);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotConfigured.selector, "setContributionRate"));
        registry.coverageBps(SEAT);
        vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.NotConfigured.selector, "setContributionRate"));
        registry.networkCoverageBps();
    }

    function test_suggestionOutstandingAndCoverage() public {
        _configure();
        _record(JOB, SEAT, 1_000); // footprint 2_500
        uint256 suggested = 2_500 * RATE; // 2.5 OFFSETS
        assertEq(registry.suggestedContribution(SEAT), suggested);
        assertEq(registry.outstanding(SEAT), suggested);
        assertEq(registry.coverageBps(SEAT), 0);
        assertEq(registry.networkCoverageBps(), 0);

        vm.startPrank(holder);
        token.approve(address(registry), 10e18);
        registry.fund(SEAT, 1e18); // 40%
        vm.stopPrank();
        assertEq(registry.outstanding(SEAT), suggested - 1e18);
        assertEq(registry.coverageBps(SEAT), 4_000);
        assertEq(registry.networkCoverageBps(), 4_000);

        vm.prank(holder);
        registry.fund(SEAT, 4e18); // 200%
        assertEq(registry.outstanding(SEAT), 0, "floored at zero");
        assertEq(registry.coverageBps(SEAT), 20_000);

        // Seats with no footprint read as zero coverage even when funded.
        assertEq(registry.coverageBps(OTHER_SEAT), 0);
        assertEq(registry.suggestedContribution(OTHER_SEAT), 0);
    }

    function test_coverageTracksRateChanges() public {
        _configure();
        _record(JOB, SEAT, 1_000);
        vm.startPrank(holder);
        token.approve(address(registry), 2.5e18);
        registry.fund(SEAT, 2.5e18);
        vm.stopPrank();
        assertEq(registry.coverageBps(SEAT), 10_000);
        vm.prank(owner);
        registry.setContributionRate(RATE * 2);
        assertEq(registry.coverageBps(SEAT), 5_000, "a higher rate lowers coverage retroactively");
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_estimateIsMeasureTimesFactor(uint128 measure, uint256 factor) public {
        measure = uint128(bound(measure, 1, type(uint128).max));
        factor = bound(factor, 1, 1e12);
        _configure();
        vm.prank(owner);
        registry.setFootprintFactor(factor);
        uint256 expected = (uint256(measure) * factor) / 1e6;
        vm.prank(recorder);
        if (expected > type(uint128).max) {
            vm.expectRevert(abi.encodeWithSelector(OffsetsRegistry.FootprintOverflow.selector, JOB));
            registry.recordJob(JOB, SEAT, measure, REF);
        } else {
            registry.recordJob(JOB, SEAT, measure, REF);
            assertEq(registry.job(JOB).footprint, expected);
            assertEq(registry.totalFootprint(), expected);
        }
    }

    function testFuzz_fundConservesTokens(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        _configure();
        vm.startPrank(holder);
        token.approve(address(registry), amount);
        registry.fund(SEAT, amount);
        vm.stopPrank();
        assertEq(token.balanceOf(holder) + token.balanceOf(beneficiary), 1_000_000e18);
        assertEq(registry.totalFunded(), amount);
    }

    function testFuzz_recordAndVoidReturnsToZero(uint8 count, uint128 measure) public {
        count = uint8(bound(count, 1, 20));
        measure = uint128(bound(measure, 1, 1e30));
        _configure();
        bytes32[] memory ids = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = keccak256(abi.encode("job", i));
            _record(ids[i], SEAT, measure);
        }
        assertEq(registry.seatAccount(SEAT).jobs, count);
        for (uint256 i; i < count; ++i) {
            vm.prank(recorder);
            registry.voidJob(ids[i], "");
        }
        assertEq(registry.seatAccount(SEAT).jobs, 0);
        assertEq(registry.seatAccount(SEAT).footprint, 0);
        assertEq(registry.totalFootprint(), 0);
        assertEq(registry.totalJobs(), count);
    }
}
