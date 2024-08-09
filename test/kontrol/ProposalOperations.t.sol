pragma solidity 0.8.23;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import "contracts/Configuration.sol";
import "contracts/DualGovernance.sol";
import "contracts/EmergencyProtectedTimelock.sol";
import "contracts/Escrow.sol";

import {Status, Proposal} from "contracts/libraries/Proposals.sol";
import {State} from "contracts/libraries/DualGovernanceState.sol";
import {addTo, Duration, Durations} from "contracts/types/Duration.sol";
import {Timestamp, Timestamps} from "contracts/types/Timestamp.sol";

import {ProposalOperationsSetup} from "test/kontrol/ProposalOperationsSetup.sol";

contract ProposalOperationsTest is ProposalOperationsSetup {
    function _proposalOperationsInitializeStorage(
        DualGovernance _dualGovernance,
        EmergencyProtectedTimelock _timelock,
        uint256 _proposalId
    ) public {
        _timelockStorageSetup(_dualGovernance, _timelock);
        _proposalStorageSetup(_timelock, _proposalId);
        uint256 baseSlot = _getProposalsSlot(_proposalId);
        uint256 numCalls = _getCallsCount(_timelock, _proposalId);
        _storeExecutorCalls(_timelock, baseSlot, numCalls);
    }

    struct ProposalRecord {
        State state;
        uint256 id;
        uint256 lastCancelledProposalId;
        Timestamp submittedAt;
        Timestamp scheduledAt;
        Timestamp executedAt;
        Timestamp vetoSignallingActivationTime;
    }

    // Record a proposal's details with the current governance state.
    function _recordProposal(
        DualGovernance _dualGovernance,
        EmergencyProtectedTimelock _timelock,
        uint256 proposalId
    ) internal returns (ProposalRecord memory pr) {
        uint256 baseSlot = _getProposalsSlot(proposalId);
        pr.id = proposalId;
        pr.state = _dualGovernance.getCurrentState();
        pr.lastCancelledProposalId = _getLastCancelledProposalId(timelock);
        pr.submittedAt = Timestamp.wrap(_getSubmittedAt(_timelock, baseSlot));
        pr.scheduledAt = Timestamp.wrap(_getScheduledAt(_timelock, baseSlot));
        pr.executedAt = Timestamp.wrap(_getExecutedAt(_timelock, baseSlot));
        (,, pr.vetoSignallingActivationTime,) = _dualGovernance.getVetoSignallingState();
    }

    // Validate that a pending proposal meets the criteria.
    function _validPendingProposal(Mode mode, ProposalRecord memory pr) internal pure {
        _establish(mode, pr.lastCancelledProposalId < pr.id);
        _establish(mode, pr.submittedAt != Timestamp.wrap(0));
        _establish(mode, pr.scheduledAt == Timestamp.wrap(0));
        _establish(mode, pr.executedAt == Timestamp.wrap(0));
    }

    // Validate that a scheduled proposal meets the criteria.
    function _validScheduledProposal(Mode mode, ProposalRecord memory pr) internal {
        _establish(mode, pr.lastCancelledProposalId < pr.id);
        _establish(mode, pr.submittedAt != Timestamp.wrap(0));
        _establish(mode, pr.scheduledAt != Timestamp.wrap(0));
        _establish(mode, pr.executedAt == Timestamp.wrap(0));
        _assumeNoOverflow(config.AFTER_SUBMIT_DELAY().toSeconds(), pr.submittedAt.toSeconds());
        _establish(mode, config.AFTER_SUBMIT_DELAY().toSeconds() + pr.submittedAt.toSeconds() <= type(uint40).max);
        _establish(mode, config.AFTER_SUBMIT_DELAY().addTo(pr.submittedAt) <= Timestamps.now());
    }

    function _validExecutedProposal(Mode mode, ProposalRecord memory pr) internal {
        _establish(mode, pr.lastCancelledProposalId < pr.id);
        _establish(mode, pr.submittedAt != Timestamp.wrap(0));
        _establish(mode, pr.scheduledAt != Timestamp.wrap(0));
        _establish(mode, pr.executedAt != Timestamp.wrap(0));
        _assumeNoOverflow(config.AFTER_SUBMIT_DELAY().toSeconds(), pr.submittedAt.toSeconds());
        _assumeNoOverflow(config.AFTER_SCHEDULE_DELAY().toSeconds(), pr.scheduledAt.toSeconds());
        _establish(mode, config.AFTER_SUBMIT_DELAY().addTo(pr.submittedAt) <= Timestamps.now());
        _establish(mode, config.AFTER_SCHEDULE_DELAY().addTo(pr.scheduledAt) <= Timestamps.now());
    }

    function _validCanceledProposal(Mode mode, ProposalRecord memory pr) internal pure {
        _establish(mode, pr.id <= pr.lastCancelledProposalId);
        _establish(mode, pr.submittedAt != Timestamp.wrap(0));
        _establish(mode, pr.executedAt == Timestamp.wrap(0));
    }

    function _isExecuted(ProposalRecord memory pr) internal pure returns (bool) {
        return pr.executedAt != Timestamp.wrap(0);
    }

    function _isCancelled(ProposalRecord memory pr) internal pure returns (bool) {
        return pr.lastCancelledProposalId >= pr.id;
    }

    function testCannotProposeInInvalidState() external {
        _timelockStorageSetup(dualGovernance, timelock);
        uint256 newProposalIndex = timelock.getProposalsCount();

        vm.assume(
            dualGovernance.getCurrentState() == State.VetoSignallingDeactivation
                || dualGovernance.getCurrentState() == State.VetoCooldown
        );

        address proposer = address(uint160(uint256(keccak256("proposer"))));
        vm.assume(dualGovernance.isProposer(proposer));

        vm.prank(proposer);
        vm.expectRevert(DualGovernanceState.ProposalsCreationSuspended.selector);
        dualGovernance.submitProposal(new ExecutorCall[](1));

        assert(timelock.getProposalsCount() == newProposalIndex);
    }

    /**
     * Test that a proposal cannot be scheduled for execution if the Dual Governance state is not Normal or VetoCooldown.
     */
    function testCannotScheduleInInvalidStates(uint256 proposalId) external {
        _timelockStorageSetup(dualGovernance, timelock);
        _proposalIdAssumeBound(proposalId);
        _proposalStorageSetup(timelock, proposalId);

        ProposalRecord memory pre = _recordProposal(dualGovernance, timelock, proposalId);
        _validPendingProposal(Mode.Assume, pre);
        vm.assume(timelock.canSchedule(proposalId));
        vm.assume(!dualGovernance.isSchedulingEnabled());

        vm.expectRevert(DualGovernanceState.ProposalsAdoptionSuspended.selector);
        dualGovernance.scheduleProposal(proposalId);

        ProposalRecord memory post = _recordProposal(dualGovernance, timelock, proposalId);
        _validPendingProposal(Mode.Assert, post);
    }

    /**
     * Test that a proposal cannot be scheduled for execution if it was submitted after the last time the VetoSignalling state was entered.
     */
    function testCannotScheduleSubmissionAfterLastVetoSignalling(uint256 proposalId) external {
        _timelockStorageSetup(dualGovernance, timelock);
        _proposalOperationsInitializeStorage(dualGovernance, timelock, proposalId);

        ProposalRecord memory pre = _recordProposal(dualGovernance, timelock, proposalId);
        _validPendingProposal(Mode.Assume, pre);
        vm.assume(pre.state == State.VetoCooldown);
        vm.assume(pre.submittedAt > pre.vetoSignallingActivationTime);

        vm.expectRevert(DualGovernanceState.ProposalsAdoptionSuspended.selector);
        dualGovernance.scheduleProposal(proposalId);

        ProposalRecord memory post = _recordProposal(dualGovernance, timelock, proposalId);
        _validPendingProposal(Mode.Assert, post);
    }

    // Test that actions that are canceled or executed cannot be rescheduled
    function testCanceledOrExecutedActionsCannotBeRescheduled(uint256 proposalId) external {
        _proposalIdAssumeBound(proposalId);
        _proposalOperationsInitializeStorage(dualGovernance, timelock, proposalId);

        ProposalRecord memory pre = _recordProposal(dualGovernance, timelock, proposalId);
        vm.assume(pre.submittedAt != Timestamp.wrap(0));
        vm.assume(dualGovernance.isSchedulingEnabled());
        if (pre.state == State.VetoCooldown) {
            vm.assume(pre.submittedAt <= pre.vetoSignallingActivationTime);
        }

        // Check if the proposal has been executed
        if (pre.executedAt != Timestamp.wrap(0)) {
            _validExecutedProposal(Mode.Assume, pre);

            vm.expectRevert(abi.encodeWithSelector(Proposals.ProposalNotSubmitted.selector, proposalId));
            dualGovernance.scheduleProposal(proposalId);

            ProposalRecord memory post = _recordProposal(dualGovernance, timelock, proposalId);
            _validExecutedProposal(Mode.Assert, post);
        } else if (pre.lastCancelledProposalId >= proposalId) {
            // Check if the proposal has been cancelled
            _validCanceledProposal(Mode.Assume, pre);

            vm.expectRevert(abi.encodeWithSelector(Proposals.ProposalNotSubmitted.selector, proposalId));
            dualGovernance.scheduleProposal(proposalId);

            ProposalRecord memory post = _recordProposal(dualGovernance, timelock, proposalId);
            _validCanceledProposal(Mode.Assert, post);
        }
    }

    /**
     * Test that a proposal cannot be scheduled for execution before ProposalExecutionMinTimelock has passed since its submission.
     */
    function testCannotScheduleBeforeMinTimelock(uint256 proposalId) external {
        _proposalIdAssumeBound(proposalId);
        _proposalOperationsInitializeStorage(dualGovernance, timelock, proposalId);

        ProposalRecord memory pre = _recordProposal(dualGovernance, timelock, proposalId);
        _validPendingProposal(Mode.Assume, pre);

        vm.assume(dualGovernance.isSchedulingEnabled());
        if (pre.state == State.VetoCooldown) {
            vm.assume(pre.submittedAt <= pre.vetoSignallingActivationTime);
        }
        vm.assume(Timestamps.now() < addTo(config.AFTER_SUBMIT_DELAY(), pre.submittedAt));

        vm.expectRevert(abi.encodeWithSelector(Proposals.AfterSubmitDelayNotPassed.selector, proposalId));
        dualGovernance.scheduleProposal(proposalId);

        ProposalRecord memory post = _recordProposal(dualGovernance, timelock, proposalId);
        _validPendingProposal(Mode.Assert, post);
    }

    /**
     * Test that a proposal cannot be executed until the emergency protection timelock has passed since it was scheduled.
     */
    function testCannotExecuteBeforeEmergencyProtectionTimelock(uint256 proposalId) external {
        _proposalIdAssumeBound(proposalId);
        _proposalOperationsInitializeStorage(dualGovernance, timelock, proposalId);

        ProposalRecord memory pre = _recordProposal(dualGovernance, timelock, proposalId);
        _validScheduledProposal(Mode.Assume, pre);
        vm.assume(_getEmergencyModeEndsAfter(timelock) == 0);
        vm.assume(Timestamps.now() < addTo(config.AFTER_SCHEDULE_DELAY(), pre.scheduledAt));

        vm.expectRevert(abi.encodeWithSelector(Proposals.AfterScheduleDelayNotPassed.selector, proposalId));
        timelock.execute(proposalId);

        ProposalRecord memory post = _recordProposal(dualGovernance, timelock, proposalId);
        _validScheduledProposal(Mode.Assert, post);
    }

    /**
     * Test that only admin proposers can cancel proposals.
     */
    function testOnlyAdminProposersCanCancelProposals() external {
        _timelockStorageSetup(dualGovernance, timelock);

        // Cancel as a non-admin proposer
        address proposer = address(uint160(uint256(keccak256("proposer"))));
        vm.assume(dualGovernance.isProposer(proposer));
        vm.assume(dualGovernance.getProposer(proposer).executor != config.ADMIN_EXECUTOR());

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(Proposers.NotAdminProposer.selector, proposer));
        dualGovernance.cancelAllPendingProposals();

        // Cancel as an admin proposer
        address adminProposer = address(uint160(uint256(keccak256("adminProposer"))));
        vm.assume(dualGovernance.isProposer(adminProposer));
        vm.assume(dualGovernance.getProposer(adminProposer).executor == config.ADMIN_EXECUTOR());

        vm.prank(adminProposer);
        dualGovernance.cancelAllPendingProposals();
    }
}
