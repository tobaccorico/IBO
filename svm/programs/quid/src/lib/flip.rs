use anchor_lang::prelude::*;
use crate::lib::battle_state::*;

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum AppealGrounds {
    ProceduralViolation,     // Improper battle procedure followed
    EvidenceDispute,         // Challenge to verse authenticity
    JurisdictionalError,     // Wrong battle category/type
    ManifestInjustice,       // Clearly erroneous outcome
    ConstitutionalViolation, // Violation of battle rules/constitution
    FraudAllegation,         // Claims of vote manipulation
    TechnicalError,          // Blockchain/system malfunction
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum AppealStatus {
    Filed,
    UnderReview,
    AwaitingResponse,
    ScheduledForHearing,
    Decided,
    Dismissed,
    Remanded,        // Send back to lower court (community vote)
    Reversed,        // Overturn original decision
    Affirmed,        // Uphold original decision
}

#[account]
#[derive(InitSpace)]
pub struct AppealRecord {
    pub appeal_id: u64,
    pub battle_id: u64,
    pub appellant: Pubkey,           // Who is appealing
    pub respondent: Pubkey,          // Other party
    pub grounds: AppealGrounds,
    pub status: AppealStatus,
    pub filing_fee: u64,             // Fee to file appeal
    pub appeal_stake: u64,           // Additional stake required
    
    // Procedural timing
    pub filed_at: i64,
    pub response_deadline: i64,
    pub hearing_scheduled: i64,
    pub decision_deadline: i64,
    pub final_decision_at: i64,
    
    // Evidence and documentation
    #[max_len(500)]
    pub appellant_brief: String,     // Legal brief explaining grounds
    #[max_len(500)]
    pub respondent_brief: String,    // Response brief
    #[max_len(100)]
    pub evidence_hashes: Vec<[u8; 32]>, // IPFS hashes of evidence
    
    // Review panel
    pub assigned_judges: Vec<Pubkey>, // Multi-sig appeal panel
    pub votes_for_reversal: u8,
    pub votes_for_affirmation: u8,
    pub recusal_count: u8,
    
    // Outcomes
    pub original_winner: Pubkey,
    pub final_winner: Pubkey,        // After appeal
    pub damages_awarded: u64,        // Compensation for wrongful decisions
    pub sanctions_imposed: u64,      // Penalties for frivolous appeals
}

#[account]
#[derive(InitSpace)]
pub struct CassationCourt {
    pub chief_justice: Pubkey,
    pub active_judges: Vec<Pubkey>,  // Pool of qualified judges
    pub retired_judges: Vec<Pubkey>, // Former judges (still eligible for complex cases)
    
    // Court administration
    pub court_treasury: u64,         // Funds for operations
    pub appeal_fee_rate: u64,        // Base fee for appeals
    pub judge_compensation: u64,     // Payment per case reviewed
    
    // Precedent system
    pub landmark_cases: Vec<u64>,    // Important precedent-setting appeals
    pub constitutional_amendments: u8, // Version of battle constitution
    
    // Performance metrics
    pub total_appeals_filed: u64,
    pub appeals_granted: u64,
    pub appeals_dismissed: u64,
    pub average_review_time: u64,    // Days
    
    // Jurisdiction limits
    pub minimum_stake_for_appeal: u64,
    pub maximum_appeal_window: i64,   // Time limit to file
    pub mandatory_review_threshold: u64, // Auto-review for high-stakes
}

impl CassationCourt {
    /// Check if appeal meets procedural requirements
    pub fn validate_appeal_eligibility(
        &self,
        battle: &Battle,
        grounds: &AppealGrounds,
        current_time: i64
    ) -> Result<bool> {
        // Time limits
        let appeal_window = current_time - battle.completed_at;
        require!(appeal_window <= self.maximum_appeal_window, AppealError::AppealWindowExpired);
        
        // Stake requirements
        require!(battle.stake_amount >= self.minimum_stake_for_appeal, AppealError::InsufficientStakeForAppeal);
        
        // Ground-specific validation
        match grounds {
            AppealGrounds::ProceduralViolation => {
                // Must show specific procedural step was violated
                Ok(true)
            },
            AppealGrounds::ManifestInjustice => {
                // Requires supermajority vote threshold
                require!(battle.total_pot >= self.mandatory_review_threshold * 10, AppealError::InsufficientGroundsForInjustice);
                Ok(true)
            },
            _ => Ok(true)
        }
    }
    
    /// Assign panel of judges for appeal review
    pub fn assign_review_panel(&self, appeal_complexity: AppealComplexity) -> Vec<Pubkey> {
        match appeal_complexity {
            AppealComplexity::Simple => {
                // Single judge for procedural matters
                vec![self.active_judges[0]] // Simplified selection
            },
            AppealComplexity::Standard => {
                // 3-judge panel for standard appeals
                self.active_judges[0..3].to_vec()
            },
            AppealComplexity::Constitutional => {
                // Full court for constitutional questions
                self.active_judges.clone()
            },
            AppealComplexity::HighStakes => {
                // 5-judge panel + chief justice for major cases
                let mut panel = self.active_judges[0..5].to_vec();
                panel.push(self.chief_justice);
                panel
            }
        }
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq)]
pub enum AppealComplexity {
    Simple,          // Clear procedural issues
    Standard,        // Typical evidence disputes
    Constitutional,  // Fundamental rule questions
    HighStakes,      // Large financial impact
}

// Appeal-specific errors
#[error_code]
pub enum AppealError {
    #[msg("Appeal window has expired")]
    AppealWindowExpired,
    #[msg("Insufficient stake amount to qualify for appeal")]
    InsufficientStakeForAppeal,
    #[msg("Grounds insufficient for manifest injustice claim")]
    InsufficientGroundsForInjustice,
    #[msg("Judge has conflict of interest and must recuse")]
    JudgeConflictOfInterest,
    #[msg("Appeal brief exceeds maximum length")]
    BriefTooLong,
    #[msg("Required evidence not provided")]
    MissingEvidence,
    #[msg("Frivolous appeal - sanctions imposed")]
    FrivolousAppeal,
    #[msg("Appeal decision is final and cannot be further appealed")]
    FinalDecision,
}