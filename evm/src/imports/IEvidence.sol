// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IArbitrator.sol";

/// @title IEvidence - ERC-1497: Evidence Standard
/// @dev Interface for evidence submission as per ERC-1497
interface IEvidence {
    /// @dev To be emitted when meta-evidence is submitted.
    /// @param _metaEvidenceID Unique identifier of meta-evidence.
    /// @param _evidence IPFS path to metaevidence, example: '/ipfs/Qmarwkf7C9RuzDEJNnarT3WZ7kem5bk8DZAzx78acJjMFH/metaevidence.json'
    event MetaEvidence(uint indexed _metaEvidenceID, string _evidence);

    /// @dev To be raised when evidence is submitted. Should point to the resource (evidences are not to be stored on chain due to gas considerations).
    /// @param _arbitrator The arbitrator of the contract.
    /// @param _evidenceGroupID Unique identifier of the evidence group the evidence belongs to.
    /// @param _party The address of the party submitting the evidence. Note that 0x0 refers to evidence not submitted by any party.
    /// @param _evidence IPFS path to evidence, example: '/ipfs/Qmarwkf7C9RuzDEJNnarT3WZ7kem5bk8DZAzx78acJjMFH/evidence.json'
    event Evidence(IArbitrator indexed _arbitrator, uint indexed _evidenceGroupID, address indexed _party, string _evidence);

    /// @dev To be emitted when a dispute is created to link the correct meta-evidence to the disputeID.
    /// @param _arbitrator The arbitrator of the contract.
    /// @param _disputeID ID of the dispute in the Arbitrator contract.
    /// @param _metaEvidenceID The meta-evidence specified by the arbitrable contract.
    /// @param _evidenceGroupID Unique identifier of the evidence group that is linked to this dispute.
    event DisputeEvent(IArbitrator indexed _arbitrator, uint indexed _disputeID, uint _metaEvidenceID, uint _evidenceGroupID);
}