// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OffsetsToken} from "../../src/OffsetsToken.sol";
import {OffsetsRegistry} from "../../src/OffsetsRegistry.sol";
import {MockSeats} from "../mocks/MockSeats.sol";

/// @dev Drives the registry with several actors and bounded inputs in random order. Every action
/// computes, from the handler's own ghost model, whether the call should succeed, performs it, and
/// asserts that the outcome matched. Ghost variables mirror what the registry should be holding so
/// the invariant functions can compare the two views after every call.
///
/// Actors: an owner, a recorder, four seat holders, a stranger with no role, and three candidate
/// beneficiaries that never spend. Seats 1..6 exist at the start; seats 7 and 8 never exist unless
/// minted by the handler; any seat may be transferred, burned and re-minted.
contract OffsetsRegistryHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant SEAT_COUNT = 8;
    uint256 public constant JOB_ID_SPACE = 64;

    OffsetsToken public immutable token;
    OffsetsRegistry public immutable registry;
    MockSeats public immutable seats;

    address public immutable owner;
    address public immutable recorder;
    address public immutable stranger;
    address[] public holders;
    address[] public beneficiaries;

    // ----------------------------------------------------------------- ghost state
    struct Snapshot {
        uint256 seatId;
        uint128 measure;
        uint128 footprint;
        uint64 recordedAt;
        bytes32 record;
    }

    bytes32[] public jobIds; // every job id ever recorded, in order
    mapping(bytes32 => bool) public ghostRecorded;
    mapping(bytes32 => bool) public ghostVoided;
    mapping(bytes32 => Snapshot) public ghostSnapshot;

    uint256 public ghostRecordedCount;
    uint256 public ghostLiveJobs;
    uint256 public ghostLiveFootprint;
    mapping(uint256 => uint256) public ghostSeatJobs;
    mapping(uint256 => uint256) public ghostSeatFootprint;

    uint256 public ghostTotalFunded;
    mapping(uint256 => uint256) public ghostSeatFunded;
    mapping(address => uint256) public ghostBeneficiaryReceived;

    address public ghostRecorder;
    address public ghostBeneficiary;
    uint256 public ghostFactor;
    uint256 public ghostRate;

    // call accounting, so a run that never reaches an action is visible
    mapping(string => uint256) public calls;
    mapping(string => uint256) public successes;

    constructor() {
        owner = makeAddr("owner");
        recorder = makeAddr("recorder");
        stranger = makeAddr("stranger");
        for (uint256 i; i < 4; ++i) {
            holders.push(makeAddr(string.concat("holder", vm.toString(i))));
        }
        for (uint256 i; i < 3; ++i) {
            beneficiaries.push(makeAddr(string.concat("beneficiary", vm.toString(i))));
        }

        token = new OffsetsToken(); // the handler plays the factory: it holds the supply
        registry = new OffsetsRegistry(owner, address(token));
        seats = new MockSeats();

        // Seats 1..6 exist, spread over the holders; 7 and 8 do not.
        for (uint256 id = 1; id <= 6; ++id) {
            seats.mint(holders[(id - 1) % holders.length], id);
        }
        // Each holder gets a slice of the supply; the handler keeps the rest.
        for (uint256 i; i < holders.length; ++i) {
            token.transfer(holders[i], 10_000_000e18);
        }

        vm.startPrank(owner);
        registry.setSeats(address(seats));
        registry.setBeneficiary(beneficiaries[0]);
        registry.setRecorder(recorder);
        registry.setFootprintFactor(2_500_000);
        registry.setContributionRate(1e15);
        vm.stopPrank();
        ghostRecorder = recorder;
        ghostBeneficiary = beneficiaries[0];
        ghostFactor = 2_500_000;
        ghostRate = 1e15;
    }

    // ----------------------------------------------------------------- helpers

    function holdersLength() external view returns (uint256) {
        return holders.length;
    }

    function beneficiariesLength() external view returns (uint256) {
        return beneficiaries.length;
    }

    function jobIdsLength() external view returns (uint256) {
        return jobIds.length;
    }

    /// @dev Everyone who can ever hold OFFSETS in this harness.
    function allTokenHolders() external view returns (address[] memory out) {
        out = new address[](holders.length + beneficiaries.length + 3);
        uint256 k;
        for (uint256 i; i < holders.length; ++i) {
            out[k++] = holders[i];
        }
        for (uint256 i; i < beneficiaries.length; ++i) {
            out[k++] = beneficiaries[i];
        }
        out[k++] = address(this);
        out[k++] = stranger;
        out[k++] = address(registry);
    }

    function _seatOwner(uint256 seatId) internal view returns (address) {
        try seats.ownerOf(seatId) returns (address who) {
            return who;
        } catch {
            return address(0);
        }
    }

    function _pickCaller(uint256 seed) internal view returns (address) {
        // Mostly the recorder, sometimes the owner, sometimes people who must be refused.
        uint256 r = seed % 10;
        if (r < 6) return recorder;
        if (r < 8) return owner;
        if (r == 8) return stranger;
        return holders[seed % holders.length];
    }

    function _authorized(address caller) internal view returns (bool) {
        return caller == ghostRecorder || caller == owner;
    }

    function _pickMeasure(uint256 seed) internal pure returns (uint128) {
        uint256 r = seed % 16;
        if (r == 0) return 0; // must be refused
        if (r == 1) return 1; // rounds to zero footprint at small factors
        if (r == 2) return type(uint128).max; // may overflow the estimate
        if (r < 6) return uint128(bound(seed, 1, 1_000));
        return uint128(bound(seed, 1, 1e30));
    }

    function _jobId(uint256 seed) internal pure returns (bytes32) {
        return keccak256(abi.encode("job", seed % JOB_ID_SPACE));
    }

    function _expectRecord(address caller, bytes32 jobId, uint256 seatId, uint128 measure)
        internal
        view
        returns (bool ok, uint128 footprint)
    {
        uint256 estimate = (uint256(measure) * ghostFactor) / registry.FACTOR_SCALE();
        ok = _authorized(caller) && measure != 0 && !ghostRecorded[jobId] && _seatOwner(seatId) != address(0)
            && estimate <= type(uint128).max;
        if (ok) footprint = uint128(estimate);
    }

    function _noteRecorded(bytes32 jobId, uint256 seatId, uint128 measure, uint128 footprint, bytes32 record) internal {
        jobIds.push(jobId);
        ghostRecorded[jobId] = true;
        ghostSnapshot[jobId] = Snapshot({
            seatId: seatId, measure: measure, footprint: footprint, recordedAt: uint64(block.timestamp), record: record
        });
        ghostRecordedCount += 1;
        ghostLiveJobs += 1;
        ghostLiveFootprint += footprint;
        ghostSeatJobs[seatId] += 1;
        ghostSeatFootprint[seatId] += footprint;
    }

    // ----------------------------------------------------------------- actions: records

    function recordJob(uint256 callerSeed, uint256 jobSeed, uint256 seatSeed, uint256 measureSeed, bytes32 record)
        external
    {
        calls["recordJob"]++;
        address caller = _pickCaller(callerSeed);
        bytes32 jobId = _jobId(jobSeed);
        uint256 seatId = bound(seatSeed, 0, SEAT_COUNT + 1); // 0 and 9 never exist
        uint128 measure = _pickMeasure(measureSeed);
        (bool expectOk, uint128 footprint) = _expectRecord(caller, jobId, seatId, measure);

        vm.prank(caller);
        try registry.recordJob(jobId, seatId, measure, record) {
            assertTrue(expectOk, "recordJob succeeded when the model said it must be refused");
            _noteRecorded(jobId, seatId, measure, footprint, record);
            successes["recordJob"]++;
        } catch {
            assertFalse(expectOk, "recordJob reverted when the model said it must succeed");
        }
    }

    function recordJobs(
        uint256 callerSeed,
        uint256 n,
        uint256[4] calldata jobSeeds,
        uint256[4] calldata seatSeeds,
        uint256[4] calldata measureSeeds
    ) external {
        calls["recordJobs"]++;
        n = bound(n, 0, 4);
        address caller = _pickCaller(callerSeed);

        bytes32[] memory ids = new bytes32[](n);
        uint256[] memory seatIds = new uint256[](n);
        uint128[] memory measures = new uint128[](n);
        bytes32[] memory records = new bytes32[](n);
        uint128[] memory footprints = new uint128[](n);

        bool expectOk = _authorized(caller);
        for (uint256 i; i < n; ++i) {
            ids[i] = _jobId(jobSeeds[i]);
            seatIds[i] = bound(seatSeeds[i], 1, SEAT_COUNT);
            measures[i] = _pickMeasure(measureSeeds[i]);
            records[i] = keccak256(abi.encode(jobSeeds[i], i));
            // A duplicate inside the batch is refused too.
            bool dupInBatch;
            for (uint256 j; j < i; ++j) {
                if (ids[j] == ids[i]) dupInBatch = true;
            }
            (bool okI, uint128 fp) = _expectRecord(caller, ids[i], seatIds[i], measures[i]);
            footprints[i] = fp;
            if (!okI || dupInBatch) expectOk = false;
        }

        vm.prank(caller);
        try registry.recordJobs(ids, seatIds, measures, records) {
            assertTrue(expectOk, "recordJobs succeeded when the model said it must be refused");
            for (uint256 i; i < n; ++i) {
                _noteRecorded(ids[i], seatIds[i], measures[i], footprints[i], records[i]);
            }
            successes["recordJobs"]++;
        } catch {
            assertFalse(expectOk, "recordJobs reverted when the model said it must succeed");
        }
    }

    function recordJobsMismatched(uint256 callerSeed) external {
        calls["recordJobsMismatched"]++;
        address caller = _pickCaller(callerSeed);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("mismatch-a");
        ids[1] = keccak256("mismatch-b");
        uint256[] memory seatIds = new uint256[](1);
        seatIds[0] = 1;
        uint128[] memory measures = new uint128[](2);
        measures[0] = 1;
        measures[1] = 1;
        bytes32[] memory records = new bytes32[](2);
        vm.prank(caller);
        bool accepted;
        try registry.recordJobs(ids, seatIds, measures, records) {
            accepted = true;
        } catch {}
        assertFalse(accepted, "a length-mismatched batch was accepted");
    }

    function voidJob(uint256 callerSeed, uint256 jobSeed, bytes32 reason) external {
        calls["voidJob"]++;
        address caller = _pickCaller(callerSeed);
        // Mostly a known job, sometimes an unknown id.
        bytes32 jobId = jobIds.length > 0 && jobSeed % 8 != 0 ? jobIds[jobSeed % jobIds.length] : _jobId(jobSeed);
        bool expectOk = _authorized(caller) && ghostRecorded[jobId] && !ghostVoided[jobId];
        Snapshot memory snap = ghostSnapshot[jobId];

        vm.prank(caller);
        try registry.voidJob(jobId, reason) {
            assertTrue(expectOk, "voidJob succeeded when the model said it must be refused");
            ghostVoided[jobId] = true;
            ghostLiveJobs -= 1;
            ghostLiveFootprint -= snap.footprint;
            ghostSeatJobs[snap.seatId] -= 1;
            ghostSeatFootprint[snap.seatId] -= snap.footprint;
            successes["voidJob"]++;
        } catch {
            assertFalse(expectOk, "voidJob reverted when the model said it must succeed");
        }
    }

    // ----------------------------------------------------------------- actions: funding

    function fund(uint256 callerSeed, uint256 seatSeed, uint256 amountSeed, bool approveFirst) external {
        calls["fund"]++;
        address caller = callerSeed % 7 == 0 ? stranger : holders[callerSeed % holders.length];
        // Mostly a seat the caller holds (so funding actually happens); sometimes any id at all.
        uint256 seatId;
        if (seatSeed % 4 != 0) {
            for (uint256 i; i < SEAT_COUNT; ++i) {
                uint256 candidate = 1 + (((seatSeed % SEAT_COUNT) + i) % SEAT_COUNT);
                if (_seatOwner(candidate) == caller) {
                    seatId = candidate;
                    break;
                }
            }
        }
        if (seatId == 0) seatId = bound(seatSeed, 0, SEAT_COUNT + 1);
        uint256 balance = token.balanceOf(caller);
        uint256 amount;
        uint256 r = amountSeed % 8;
        if (r == 0) amount = 0;
        else if (r == 1) amount = balance; // everything
        else if (r == 2) amount = balance + 1; // one more than held
        else amount = bound(amountSeed, 1, balance == 0 ? 1 : balance);

        if (approveFirst) {
            vm.prank(caller);
            token.approve(address(registry), amount);
        } else {
            vm.prank(caller);
            token.approve(address(registry), 0);
        }

        bool expectOk = ghostBeneficiary != address(0) && amount != 0 && _seatOwner(seatId) == caller && approveFirst
            && amount <= balance;
        address to = ghostBeneficiary;
        uint256 toBefore = token.balanceOf(to);

        vm.prank(caller);
        try registry.fund(seatId, amount) {
            assertTrue(expectOk, "fund succeeded when the model said it must be refused");
            assertEq(token.balanceOf(to) - toBefore, amount, "the beneficiary received a different amount");
            assertEq(token.balanceOf(caller), balance - amount, "the funder paid a different amount");
            ghostTotalFunded += amount;
            ghostSeatFunded[seatId] += amount;
            ghostBeneficiaryReceived[to] += amount;
            successes["fund"]++;
        } catch {
            assertFalse(expectOk, "fund reverted when the model said it must succeed");
            assertEq(token.balanceOf(to), toBefore, "a failed fund still moved tokens");
        }
    }

    // ----------------------------------------------------------------- actions: configuration

    function setFootprintFactor(uint256 callerSeed, uint256 factorSeed) external {
        calls["setFootprintFactor"]++;
        address caller = callerSeed % 5 == 0 ? stranger : owner;
        uint256 r = factorSeed % 6;
        uint256 factor = r == 0 ? 0 : r == 1 ? 1 : r == 2 ? 1e6 : bound(factorSeed, 1, 1e12);
        bool expectOk = caller == owner && factor != 0;
        vm.prank(caller);
        try registry.setFootprintFactor(factor) {
            assertTrue(expectOk, "setFootprintFactor succeeded unexpectedly");
            ghostFactor = factor;
        } catch {
            assertFalse(expectOk, "setFootprintFactor reverted unexpectedly");
        }
    }

    function setContributionRate(uint256 callerSeed, uint256 rateSeed) external {
        calls["setContributionRate"]++;
        address caller = callerSeed % 5 == 0 ? stranger : owner;
        uint256 rate = rateSeed % 4 == 0 ? 0 : bound(rateSeed, 1, 1e18);
        bool expectOk = caller == owner && rate != 0;
        vm.prank(caller);
        try registry.setContributionRate(rate) {
            assertTrue(expectOk, "setContributionRate succeeded unexpectedly");
            ghostRate = rate;
        } catch {
            assertFalse(expectOk, "setContributionRate reverted unexpectedly");
        }
    }

    function setBeneficiary(uint256 callerSeed, uint256 whichSeed) external {
        calls["setBeneficiary"]++;
        address caller = callerSeed % 5 == 0 ? stranger : owner;
        address next = whichSeed % 5 == 0 ? address(0) : beneficiaries[whichSeed % beneficiaries.length];
        bool expectOk = caller == owner && next != address(0);
        vm.prank(caller);
        try registry.setBeneficiary(next) {
            assertTrue(expectOk, "setBeneficiary succeeded unexpectedly");
            ghostBeneficiary = next;
        } catch {
            assertFalse(expectOk, "setBeneficiary reverted unexpectedly");
        }
    }

    function setRecorder(uint256 callerSeed, uint256 whichSeed) external {
        calls["setRecorder"]++;
        address caller = callerSeed % 5 == 0 ? stranger : owner;
        address next = whichSeed % 3 == 0 ? address(0) : recorder;
        bool expectOk = caller == owner;
        vm.prank(caller);
        try registry.setRecorder(next) {
            assertTrue(expectOk, "setRecorder succeeded unexpectedly");
            ghostRecorder = next;
        } catch {
            assertFalse(expectOk, "setRecorder reverted unexpectedly");
        }
    }

    // ----------------------------------------------------------------- actions: seats and tokens

    function transferSeat(uint256 seatSeed, uint256 toSeed) external {
        calls["transferSeat"]++;
        uint256 seatId = bound(seatSeed, 1, SEAT_COUNT);
        address from = _seatOwner(seatId);
        if (from == address(0)) return;
        address to = holders[toSeed % holders.length];
        vm.prank(from);
        seats.transferFrom(from, to, seatId);
    }

    function burnSeat(uint256 seatSeed) external {
        calls["burnSeat"]++;
        uint256 seatId = bound(seatSeed, 1, SEAT_COUNT);
        if (_seatOwner(seatId) == address(0)) return;
        seats.burn(seatId);
    }

    function mintSeat(uint256 seatSeed, uint256 toSeed) external {
        calls["mintSeat"]++;
        uint256 seatId = bound(seatSeed, 1, SEAT_COUNT);
        if (_seatOwner(seatId) != address(0)) return;
        seats.mint(holders[toSeed % holders.length], seatId);
    }

    function moveTokens(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        calls["moveTokens"]++;
        address from = holders[fromSeed % holders.length];
        address to = holders[toSeed % holders.length];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function warp(uint256 by) external {
        calls["warp"]++;
        vm.warp(block.timestamp + bound(by, 0, 30 days));
    }
}
