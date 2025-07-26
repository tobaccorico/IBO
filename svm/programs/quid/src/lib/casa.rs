use anchor_lang::prelude::*;
use std::collections::HashMap;

#[account]
#[derive(InitSpace)]
pub struct BattleConstitution {
    pub version: u8,
    pub ratified_at: i64,
    pub ratification_vote_count: u64,
    
    // Fundamental Rights
    pub guarantees_due_process: bool,
    pub guarantees_equal_protection: bool,
    pub guarantees_free_expression: bool,
    pub prohibits_cruel_punishment: bool,
    
    // Procedural Requirements
    pub minimum_evidence_standard: EvidenceStandard,
    pub burden_of_proof: BurdenOfProof,
    pub statute_of_limitations: i64,    // Time to file claims
    
    // Voting Rights
    pub universal_suffrage: bool,        // All token holders can vote
    pub weighted_voting_allowed: bool,   // Stake-weighted votes
    pub minimum_voting_age: u64,         // Account age requirement
    pub voter_privacy_protected: bool,   // Anonymous voting
    
    // Appeal Rights
    pub right_to_appeal: bool,
    pub maximum_appeal_levels: u8,       // Usually 2-3 levels
    pub automatic_appeal_triggers: Vec<AutoAppealTrigger>,
    
    // Amendment Process
    pub amendment_threshold: u16,        // Percentage required (e.g., 67%)
    pub amendment_proposal_fee: u64,
    pub amendment_voting_period: i64,
    
    // Emergency Powers
    pub emergency_suspension_allowed: bool,
    pub emergency_authority: Pubkey,
    pub emergency_time_limit: i64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum EvidenceStandard {
    PrepondereranceOfEvidence,  // 49% certainty (civil standard)
    ClearAndConvincing,         // 72% certainty
    BeyondReasonableDoubt,      // 96% certainty (criminal standard)
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum BurdenOfProof {
    Challenger,     // Challenger must prove their case
    Defender,       // Defender must prove innocence
    Preponderance,  // Whoever has more evidence wins
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum AutoAppealTrigger {
    StakeExceedsThreshold(u64),     // Automatic review for high stakes
    VoteMarginTooClose(u8),         // Review if vote within X%
    TechnicalFailure,               // System errors trigger review
    FraudAllegation,                // Automatic investigation
    ConstitutionalChallenge,        // Direct constitutional questions
}

#[account]
#[derive(InitSpace)]
pub struct PrecedentRegistry {
    pub precedent_id: u64,
    pub establishing_case: u64,        // Battle/appeal that set precedent
    pub legal_principle: LegalPrinciple,
    pub binding_authority: BindingLevel,
    
    // Citation and application
    pub times_cited: u64,
    pub times_distinguished: u64,      // Cases that found exceptions
    pub times_overruled: u64,
    
    // Precedent details
    #[max_len(1000)]
    pub holding: String,               // Core legal rule established
    #[max_len(500)]
    pub reasoning: String,             // Why this rule exists
    #[max_len(200)]
    pub keywords: Vec<String>,         // Searchable terms
    
    // Temporal scope
    pub effective_from: i64,
    pub superseded_at: i64,            // When overruled (0 if still active)
    pub superseding_precedent: u64,    // What replaced it
    
    // Jurisdictional scope
    pub applies_to_categories: Vec<BattleCategoryType>,
    pub minimum_stake_application: u64, // Only applies to battles above this stake
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum LegalPrinciple {
    ProceduralDueProcess,      // Fair process requirements
    SubstantiveDueProcess,     // Fundamental fairness in outcomes
    EqualProtection,           // Same rules for all participants
    FreedomOfExpression,       // Protection of battle content
    ProportionalityPrinciple,  // Punishment fits the violation
    ResPudicata,              // Finality of judgments
    CollateralEstoppel,       // Issue preclusion
    StatuteOfLimitations,     // Time limits on claims
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum BindingLevel {
    SupremePrecedent,         // Binding on all lower decisions
    StronglyPersuasive,       // Usually followed
    Persuasive,              // Sometimes followed
    Informational,           // Reference only
}

/// Constitutional review and precedent application
impl BattleConstitution {
    /// Check if a proposed battle rule violates constitution
    pub fn constitutional_review(&self, proposed_rule: &ProposedRule) -> Result<ConstitutionalReview> {
        let mut review = ConstitutionalReview {
            is_constitutional: true,
            violations: Vec::new(),
            required_amendments: Vec::new(),
        };
        
        // Due Process Check
        if proposed_rule.affects_existing_rights && !self.guarantees_due_process {
            review.violations.push(ConstitutionalViolation::DueProcessViolation);
            review.is_constitutional = false;
        }
        
        // Equal Protection Check
        if proposed_rule.creates_different_treatment && !self.guarantees_equal_protection {
            review.violations.push(ConstitutionalViolation::EqualProtectionViolation);
            review.is_constitutional = false;
        }
        
        // Free Expression Check
        if proposed_rule.restricts_battle_content && !proposed_rule.has_compelling_interest {
            review.violations.push(ConstitutionalViolation::FreeExpressionViolation);
            review.is_constitutional = false;
        }
        
        Ok(review)
    }
    
    /// Apply constitutional amendments
    pub fn amend_constitution(&mut self, amendment: ConstitutionalAmendment, vote_count: u64) -> Result<()> {
        // Check if amendment has sufficient support
        let required_votes = (self.ratification_vote_count * self.amendment_threshold as u64) / 100;
        require!(vote_count >= required_votes, ConstitutionalError::InsufficientVotes);
        
        // Apply the amendment
        match amendment.amendment_type {
            AmendmentType::AddRight(right) => {
                match right {
                    FundamentalRight::DueProcess => self.guarantees_due_process = true,
                    FundamentalRight::EqualProtection => self.guarantees_equal_protection = true,
                    FundamentalRight::FreeExpression => self.guarantees_free_expression = true,
                    FundamentalRight::NocruelPunishment => self.prohibits_cruel_punishment = true,
                }
            },
            AmendmentType::ModifyProcedure(procedure) => {
                // Update procedural requirements
                self.minimum_evidence_standard = procedure.evidence_standard;
                self.burden_of_proof = procedure.burden_of_proof;
            },
            AmendmentType::ChangeVotingRules(voting_rules) => {
                self.weighted_voting_allowed = voting_rules.allow_weighted_voting;
                self.minimum_voting_age = voting_rules.minimum_age;
            }
        }
        
        self.version += 1;
        Ok(())
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct ConstitutionalReview {
    pub is_constitutional: bool,
    pub violations: Vec<ConstitutionalViolation>,
    pub required_amendments: Vec<String>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq)]
pub enum ConstitutionalViolation {
    DueProcessViolation,
    EqualProtectionViolation,
    FreeExpressionViolation,
    CruelPunishmentViolation,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct ProposedRule {
    pub affects_existing_rights: bool,
    pub creates_different_treatment: bool,
    pub restricts_battle_content: bool,
    pub has_compelling_interest: bool,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct ConstitutionalAmendment {
    pub amendment_type: AmendmentType,
    pub rationale: String,
    pub effective_date: i64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub enum AmendmentType {
    AddRight(FundamentalRight),
    ModifyProcedure(ProceduralChange),
    ChangeVotingRules(VotingRuleChange),
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub enum FundamentalRight {
    DueProcess,
    EqualProtection,
    FreeExpression,
    NocruelPunishment,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct ProceduralChange {
    pub evidence_standard: EvidenceStandard,
    pub burden_of_proof: BurdenOfProof,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct VotingRuleChange {
    pub allow_weighted_voting: bool,
    pub minimum_age: u64,
}

#[error_code]
pub enum ConstitutionalError {
    #[msg("Insufficient votes to ratify amendment")]
    InsufficientVotes,
    #[msg("Proposed rule violates constitutional principles")]
    ConstitutionalViolation,
    #[msg("Amendment process not followed correctly")]
    InvalidAmendmentProcess,
}