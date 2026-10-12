// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title OffsetsRegistry
/// @notice Estimates the footprint of the network's own public job records, attributes each
/// estimate to the NFT seat that did the work, and lets the seat's holder fund a regenerative
/// contribution in OFFSETS against it.
///
/// How it fits together:
///  - A job record is posted by the recorder (or the owner) with the job's public identifier, the
///    seat that ran it, and a measured amount of work (`measure`, e.g. compute-seconds). The
///    registry turns the measure into a footprint estimate with the owner-set footprint factor:
///    `footprint = measure * footprintFactor / FACTOR_SCALE`.
///  - Footprint accrues per seat and network-wide. A mis-posted record can be voided by the
///    recorder, which backs its footprint out again.
///  - The owner sets a contribution rate (OFFSETS minor units per footprint unit). A seat's
///    suggested contribution is its live footprint times that rate, and its coverage is what its
///    holders have funded against that suggestion.
///  - A seat's current holder (per the configured seat NFT) funds any amount of OFFSETS, which goes
///    straight to the owner-set beneficiary: the regenerative project receiving the contributions.
///    The registry never custodies tokens.
///
/// Trust assumptions: the owner configures the seat NFT, the beneficiary, the recorder and the two
/// rates; the recorder is trusted to post honest measures. Neither can touch a holder's OFFSETS
/// balance or redirect funds already sent. See the README for the operational responsibilities.
contract OffsetsRegistry is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /// @notice One public job record and the estimate derived from it.
    struct Job {
        /// @dev The seat the job is attributed to.
        uint256 seatId;
        /// @dev The measured work the estimate was derived from (recorder's units, e.g. compute-seconds).
        uint128 measure;
        /// @dev The footprint estimate, in footprint units (e.g. grams CO2e), at the factor in force when recorded.
        uint128 footprint;
        /// @dev Block timestamp of recording.
        uint64 recordedAt;
        /// @dev True once voided; a voided job no longer counts toward its seat.
        bool voided;
        /// @dev Opaque pointer to the public record (content hash, URI hash, ...).
        bytes32 record;
    }

    /// @notice Running totals for one seat.
    struct SeatAccount {
        /// @dev Live (not voided) jobs attributed to the seat.
        uint256 jobs;
        /// @dev Live footprint attributed to the seat, in footprint units.
        uint256 footprint;
        /// @dev OFFSETS minor units funded against the seat so far.
        uint256 funded;
    }

    // ---------------------------------------------------------------------------------------------
    // Constants and immutables
    // ---------------------------------------------------------------------------------------------

    /// @notice Fixed-point scale of `footprintFactor`: a factor of `FACTOR_SCALE` means one footprint
    /// unit per unit of measure.
    uint256 public constant FACTOR_SCALE = 1e6;

    /// @notice Basis-point denominator used by the coverage views.
    uint256 public constant BPS = 10_000;

    /// @notice The OFFSETS token contributions are paid in.
    IERC20 public immutable OFFSETS;

    // ---------------------------------------------------------------------------------------------
    // Owner-set configuration
    // ---------------------------------------------------------------------------------------------

    /// @notice The NFT whose token ids are the network's seats. Unset until the owner configures it.
    IERC721 public seats;

    /// @notice Where funded contributions are sent. Unset until the owner configures it.
    address public beneficiary;

    /// @notice The account allowed to post and void job records besides the owner. May be zero.
    address public recorder;

    /// @notice Footprint units per unit of measure, scaled by `FACTOR_SCALE`. Zero means unset.
    uint256 public footprintFactor;

    /// @notice OFFSETS minor units suggested per footprint unit. Zero means unset.
    uint256 public contributionRate;

    // ---------------------------------------------------------------------------------------------
    // Records
    // ---------------------------------------------------------------------------------------------

    mapping(bytes32 jobId => Job) private _jobs;
    mapping(uint256 seatId => SeatAccount) private _seats;

    /// @notice Number of job records ever posted (voided ones included).
    uint256 public totalJobs;

    /// @notice Live footprint across all seats, in footprint units.
    uint256 public totalFootprint;

    /// @notice OFFSETS minor units funded across all seats.
    uint256 public totalFunded;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

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

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @dev A setting the call needs has not been configured yet; `setting` names its setter.
    error NotConfigured(string setting);
    error ZeroAddress();
    error ZeroValue();
    error NotRecorder(address caller);
    error JobAlreadyRecorded(bytes32 jobId);
    error UnknownJob(bytes32 jobId);
    error JobAlreadyVoided(bytes32 jobId);
    error FootprintOverflow(bytes32 jobId);
    error LengthMismatch();
    error NotSeatHolder(uint256 seatId, address caller);

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    /// @param owner_ The owner of this registry: the launch's owner, never the factory.
    /// @param offsets The OFFSETS token address. Not called here; checked on first use.
    constructor(address owner_, address offsets) Ownable(owner_) {
        if (offsets == address(0)) revert ZeroAddress();
        OFFSETS = IERC20(offsets);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the seat NFT. Required before recording and funding.
    function setSeats(address seats_) external onlyOwner {
        if (seats_ == address(0)) revert ZeroAddress();
        seats = IERC721(seats_);
        emit SeatsSet(seats_);
    }

    /// @notice Sets the recipient of funded contributions. Required before funding.
    function setBeneficiary(address beneficiary_) external onlyOwner {
        if (beneficiary_ == address(0)) revert ZeroAddress();
        beneficiary = beneficiary_;
        emit BeneficiarySet(beneficiary_);
    }

    /// @notice Sets the recorder. Zero revokes it; the owner can always record.
    function setRecorder(address recorder_) external onlyOwner {
        recorder = recorder_;
        emit RecorderSet(recorder_);
    }

    /// @notice Sets the footprint factor (footprint units per unit of measure, scaled by `FACTOR_SCALE`).
    /// Required before recording. Only affects records posted afterwards.
    function setFootprintFactor(uint256 footprintFactor_) external onlyOwner {
        if (footprintFactor_ == 0) revert ZeroValue();
        footprintFactor = footprintFactor_;
        emit FootprintFactorSet(footprintFactor_);
    }

    /// @notice Sets the contribution rate (OFFSETS minor units per footprint unit). Required by the
    /// suggestion and coverage views; funding itself never depends on it.
    function setContributionRate(uint256 contributionRate_) external onlyOwner {
        if (contributionRate_ == 0) revert ZeroValue();
        contributionRate = contributionRate_;
        emit ContributionRateSet(contributionRate_);
    }

    // ---------------------------------------------------------------------------------------------
    // Job records
    // ---------------------------------------------------------------------------------------------

    modifier onlyRecorder() {
        if (msg.sender != recorder && msg.sender != owner()) revert NotRecorder(msg.sender);
        _;
    }

    /// @notice Posts one public job record and attributes its estimated footprint to a seat.
    /// @param jobId The job's public identifier; each may be recorded once.
    /// @param seatId The seat that did the work; must exist on the configured seat NFT.
    /// @param measure The measured work, in the recorder's units; must be non-zero.
    /// @param record Opaque pointer to the public record.
    function recordJob(bytes32 jobId, uint256 seatId, uint128 measure, bytes32 record) external onlyRecorder {
        _requireSeatsConfigured();
        if (footprintFactor == 0) revert NotConfigured("setFootprintFactor");
        _recordJob(jobId, seatId, measure, record);
    }

    /// @notice Posts several job records in one call. Arrays are parallel and must match in length.
    function recordJobs(
        bytes32[] calldata jobIds,
        uint256[] calldata seatIds,
        uint128[] calldata measures,
        bytes32[] calldata records
    ) external onlyRecorder {
        _requireSeatsConfigured();
        if (footprintFactor == 0) revert NotConfigured("setFootprintFactor");
        uint256 n = jobIds.length;
        if (seatIds.length != n || measures.length != n || records.length != n) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            _recordJob(jobIds[i], seatIds[i], measures[i], records[i]);
        }
    }

    /// @notice Voids a mis-posted record, backing its footprint out of its seat and the totals.
    /// Funding already made against the seat is untouched.
    function voidJob(bytes32 jobId, bytes32 reason) external onlyRecorder {
        Job storage job = _jobs[jobId];
        if (job.recordedAt == 0) revert UnknownJob(jobId);
        if (job.voided) revert JobAlreadyVoided(jobId);
        job.voided = true;

        SeatAccount storage seat = _seats[job.seatId];
        seat.jobs -= 1;
        seat.footprint -= job.footprint;
        totalFootprint -= job.footprint;

        emit JobVoided(jobId, job.seatId, job.footprint, reason);
    }

    function _recordJob(bytes32 jobId, uint256 seatId, uint128 measure, bytes32 record) private {
        if (measure == 0) revert ZeroValue();
        if (_jobs[jobId].recordedAt != 0) revert JobAlreadyRecorded(jobId);
        // Reverts for a seat that does not exist, so nothing is attributed to a phantom seat.
        if (seats.ownerOf(seatId) == address(0)) revert NotConfigured("setSeats");

        uint256 estimate = (uint256(measure) * footprintFactor) / FACTOR_SCALE;
        if (estimate > type(uint128).max) revert FootprintOverflow(jobId);
        // Safe: bounded by the check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 footprint = uint128(estimate);

        _jobs[jobId] = Job({
            seatId: seatId,
            measure: measure,
            footprint: footprint,
            // Safe: a uint64 timestamp overflows in the year 584 billion.
            // forge-lint: disable-next-line(unsafe-typecast)
            recordedAt: uint64(block.timestamp),
            voided: false,
            record: record
        });

        SeatAccount storage seat = _seats[seatId];
        seat.jobs += 1;
        seat.footprint += footprint;
        totalFootprint += footprint;
        totalJobs += 1;

        emit JobRecorded(jobId, seatId, measure, footprint, record);
    }

    // ---------------------------------------------------------------------------------------------
    // Regenerative contributions
    // ---------------------------------------------------------------------------------------------

    /// @notice Funds a regenerative contribution against a seat. Only the seat's current holder may
    /// call, and the OFFSETS go straight from the caller to the beneficiary. Any amount is accepted,
    /// above or below the seat's suggested contribution; the caller must have approved it first.
    function fund(uint256 seatId, uint256 amount) external nonReentrant {
        _requireSeatsConfigured();
        address to = beneficiary;
        if (to == address(0)) revert NotConfigured("setBeneficiary");
        if (amount == 0) revert ZeroValue();
        if (seats.ownerOf(seatId) != msg.sender) revert NotSeatHolder(seatId, msg.sender);

        _seats[seatId].funded += amount;
        totalFunded += amount;

        OFFSETS.safeTransferFrom(msg.sender, to, amount);
        emit ContributionFunded(seatId, msg.sender, to, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The stored record for a job id. `recordedAt == 0` means no such record.
    function job(bytes32 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    /// @notice A seat's live job count, footprint and funding so far.
    function seatAccount(uint256 seatId) external view returns (SeatAccount memory) {
        return _seats[seatId];
    }

    /// @notice The OFFSETS minor units suggested for a seat: its live footprint at the current rate.
    function suggestedContribution(uint256 seatId) public view returns (uint256) {
        uint256 rate = contributionRate;
        if (rate == 0) revert NotConfigured("setContributionRate");
        return _seats[seatId].footprint * rate;
    }

    /// @notice What a seat still owes against its suggestion, floored at zero.
    function outstanding(uint256 seatId) external view returns (uint256) {
        uint256 suggested = suggestedContribution(seatId);
        uint256 funded = _seats[seatId].funded;
        return funded >= suggested ? 0 : suggested - funded;
    }

    /// @notice A seat's funding as basis points of its suggestion. 10_000 is fully covered; more is
    /// over-funded. A seat with no footprint reads as zero.
    function coverageBps(uint256 seatId) external view returns (uint256) {
        uint256 suggested = suggestedContribution(seatId);
        if (suggested == 0) return 0;
        return (_seats[seatId].funded * BPS) / suggested;
    }

    /// @notice Network-wide funding as basis points of the network-wide suggestion.
    function networkCoverageBps() external view returns (uint256) {
        uint256 rate = contributionRate;
        if (rate == 0) revert NotConfigured("setContributionRate");
        uint256 suggested = totalFootprint * rate;
        if (suggested == 0) return 0;
        return (totalFunded * BPS) / suggested;
    }

    /// @notice True once every setting recording and funding need is in place.
    function isConfigured() external view returns (bool) {
        return
            address(seats) != address(0) && beneficiary != address(0) && footprintFactor != 0 && contributionRate != 0;
    }

    function _requireSeatsConfigured() private view {
        if (address(seats) == address(0)) revert NotConfigured("setSeats");
    }
}
