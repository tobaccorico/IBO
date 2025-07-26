use anchor_lang::prelude::*;

// Error codes
#[error_code]
pub enum BattleError {
    #[msg("Battle window is currently closed")]
    BattleWindowClosed,
    #[msg("Insufficient stake amount")]
    InsufficientStake,
    #[msg("Invalid challenge data")]
    InvalidChallengeData,
    #[msg("Invalid battle state for this operation")]
    InvalidBattleState,
    #[msg("Acceptance deadline has passed")]
    AcceptanceDeadlinePassed,
    #[msg("Cannot challenge yourself")]
    CannotChallengeSelf,
    #[msg("Unauthorized randomness commit")]
    UnauthorizedRandomnessCommit,
    #[msg("Invalid randomness slot")]
    InvalidRandomnessSlot,
    #[msg("Incorrect randomness account")]
    IncorrectRandomnessAccount,
    #[msg("Randomness not resolved")]
    RandomnessNotResolved,
    #[msg("Unauthorized participant")]
    UnauthorizedParticipant,
    #[msg("Invalid commit-reveal data")]
    InvalidCommitReveal,
    #[msg("Voting window is closed")]
    VotingWindowClosed,
    #[msg("Already voted in this battle")]
    AlreadyVoted,
    #[msg("Invalid vote")]
    InvalidVote,
    #[msg("Voting is still active")]
    VotingStillActive,
    #[msg("Unauthorized finalization")]
    UnauthorizedFinalization,
    #[msg("Unauthorized cancellation")]
    UnauthorizedCancellation,
    #[msg("Cannot cancel active battle")]
    CannotCancelActiveBattle,
    #[msg("Excessive organizer fee")]
    ExcessiveOrganizerFee,
    #[msg("Insufficient categorization hashtags")]
    InsufficientCategorization,
    #[msg("Invalid time window")]
    InvalidTimeWindow,
}