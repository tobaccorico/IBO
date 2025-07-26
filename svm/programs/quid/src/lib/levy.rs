use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct EnforcementRegistry {
    pub total_violations: u64,
    pub total_sanctions_imposed: u64,
    pub total_fines_collected: u64,
    pub enforcement_treasury: u64,
    
    // Enforcement officers
    pub authorized_enforcers: Vec<Pubkey>,
    pub enforcement_authority: Pubkey,
    
    // Violation tracking
    pub violation_types: Vec<ViolationType>,
    pub repeat_offender_multiplier: u16,  // e.g., 150% = 1.5x penalty
    pub statute_of_limitations: i64,       // Time limit to prosecute
    
    // Compliance monitoring
    pub compliance_rate: u8,               // Overall system compliance %
    pub monitoring_algorithms: Vec<MonitoringAlgorithm>,
}

#[account]
#[derive(InitSpace)]
pub struct ViolationRecord {
    pub violation_id: u64,
    pub violator: Pubkey,
    pub violation_type: ViolationType,
    pub severity: ViolationSeverity,
    pub battle_id: Option<u64>,           // Which battle (if applicable)
    
    // Incident details
    pub detected_at: i64,
    pub reported_by: Pubkey,              // Who reported the violation
    pub evidence_provided: Vec<u64>,      // Evidence IDs
    pub automated_detection: bool,        // Found by AI vs human report
    
    // Investigation
    pub investigation_status: InvestigationStatus,
    pub investigating_officer: Pubkey,
    pub investigation_findings: String,
    pub witness_statements: Vec<u64>,
    
    // Sanctions imposed
    pub sanctions: Vec<Sanction>,
    pub total_penalty_amount: u64,
    pub payment_deadline: i64,
    pub payment_status: PaymentStatus,
    
    // Appeals and resolution
    pub appeal_filed: bool,
    pub appeal_id: Option<u64>,
    pub final_resolution: Option<FinalResolution>,
    pub compliance_deadline: i64,
    pub compliance_verified: bool,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum ViolationType {
    // Battle conduct violations
    FraudulentVoting,             // Vote manipulation
    FakeEvidence,                 // Submitting false evidence
    Impersonation,                // Pretending to be someone else
    ContentViolation,             // Inappropriate/illegal content
    TimingViolation,              // Missing deadlines, improper timing
    
    // Market manipulation
    StakeManipulation,            // Artificial stake inflation
    WashTrading,                  // Fake volume/activity
    InsiderTrading,               // Using non-public information
    PriceManipulation,            // Artificial price movement
    
    // System abuse
    SpamAttack,                   // Flooding system with requests
    SybilAttack,                  // Multiple fake identities
    ExploitAttempt,               // Trying to exploit vulnerabilities
    UnauthorizedAccess,           // Accessing restricted data
    
    // Procedural violations
    ContemptOfCourt,              // Ignoring court orders
    ObstructionOfJustice,         // Interfering with proceedings
    PerjuryEquivalent,            // False sworn statements
    BriberyAttempt,               // Attempting to corrupt officials
    
    // Technical violations
    SmartContractViolation,       // Breaking contract terms
    OracleManipulation,           // Manipulating price feeds
    ConsensusAttack,              // Attacking blockchain consensus
    DataBreach,                   // Unauthorized data access
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum ViolationSeverity {
    Minor,          // Warning or small fine
    Moderate,       // Significant penalty
    Serious,        // Major sanctions
    Severe,         // Account suspension/ban
    Critical,       // Criminal referral
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum InvestigationStatus {
    Reported,       // Initial report filed
    UnderInvestigation, // Active investigation
    EvidenceGathering,  // Collecting evidence
    AwaitingDecision,   // Investigation complete, pending decision
    Concluded,      // Investigation finished
    Dismissed,      // No violation found
    ReferredToCriminal, // Serious enough for criminal prosecution
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct Sanction {
    pub sanction_type: SanctionType,
    pub amount: u64,                      // Fine amount or duration
    pub effective_date: i64,
    pub expiration_date: Option<i64>,     // When sanction ends
    pub compliance_required: bool,
    pub compliance_description: String,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum SanctionType {
    // Financial penalties
    MonetaryFine(u64),                    // Direct fine
    StakeForfeiture(u64),                 // Lose staked tokens
    RestitutionOrder(u64),                // Pay damages to victim
    
    // Participation restrictions
    BattleSuspension(u64),                // Can't participate for X days
    VotingRestriction(u64),               // Can't vote for X days
    StakingProhibition(u64),              // Can't stake for X days
    
    // Account sanctions
    AccountSuspension(u64),               // Account frozen for X days
    AccountBan,                           // Permanent account termination
    FeatureRestriction(Vec<String>),      // Specific features disabled
    
    // Compliance requirements
    ComplianceTraining,                   // Must complete training
    CommunityService(u64),                // Hours of community service
    PublicApology,                        // Public acknowledgment of wrongdoing
    
    // Monitoring and supervision
    EnhancedMonitoring(u64),              // Increased oversight for X days
    ProbationaryStatus(u64),              // Special status with restrictions
    ComplianceReporting(u64),             // Regular compliance reports
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum PaymentStatus {
    Pending,
    PaidInFull,
    PartiallyPaid,
    InDefault,
    UnderPaymentPlan,
    Forgiven,
    InDispute,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct FinalResolution {
    pub resolution_type: ResolutionType,
    pub final_penalty: u64,
    pub conditions_met: bool,
    pub rehabilitation_complete: bool,
    pub record_sealed: bool,               // Hide from public view
    pub expungement_eligible: bool,        // where's the list...
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum ResolutionType {
    SanctionsUpheld,      // Original penalties stand
    SanctionsReduced,     // Penalties lowered on appeal
    SanctionsDismissed,   // No penalties (violation dismissed)
    AlternativeResolution, // Community service, mediation, etc.
    CriminalReferral,     // Referred to law enforcement
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct MonitoringAlgorithm {
    pub algorithm_name: String,
    pub target_violations: Vec<ViolationType>,
    pub detection_accuracy: u8,           // Historical accuracy %
    pub false_positive_rate: u8,          // % of false alarms
    pub last_updated: i64,
    pub active: bool,
}

/// Enforcement and compliance system
impl EnforcementRegistry {
    /// Automatically detect potential violations
    pub fn scan_for_violations(&self, battle: &Battle) -> Vec<PotentialViolation> {
        let mut violations = Vec::new();
        
        // Check for timing violations
        if battle.status == BattleStatus::Completed {
            let decision_time = battle.completed_at - battle.voting_end_time;
            if decision_time > 86400 { // More than 24 hours
                violations.push(PotentialViolation {
                    violation_type: ViolationType::TimingViolation,
                    confidence: 95,
                    evidence: "Decision took longer than 24 hours".to_string(),
                });
            }
        }
        
        // Check for suspicious voting patterns
        if self.detect_vote_manipulation(battle) {
            violations.push(PotentialViolation {
                violation_type: ViolationType::FraudulentVoting,
                confidence: 80,
                evidence: "Unusual voting patterns detected".to_string(),
            });
        }
        
        // Check for stake manipulation
        if battle.stake_amount > battle.total_pot / 10 {
            violations.push(PotentialViolation {
                violation_type: ViolationType::StakeManipulation,
                confidence: 70,
                evidence: "Unusual stake-to-pot ratio".to_string(),
            });
        }
        
        violations
    }
    
    /// Issue sanctions for confirmed violations
    pub fn impose_sanctions(
        &mut self,
        violation: &ViolationRecord,
        authority: &Pubkey
    ) -> Result<Vec<Sanction>> {
        require!(
            self.authorized_enforcers.contains(authority),
            EnforcementError::UnauthorizedEnforcer
        );
        
        let mut sanctions = Vec::new();
        
        match violation.violation_type {
            ViolationType::FraudulentVoting => {
                match violation.severity {
                    ViolationSeverity::Minor => {
                        sanctions.push(Sanction {
                            sanction_type: SanctionType::MonetaryFine(1000000), // 1 USD*
                            amount: 1000000,
                            effective_date: Clock::get()?.unix_timestamp,
                            expiration_date: None,
                            compliance_required: false,
                            compliance_description: "".to_string(),
                        });
                    },
                    ViolationSeverity::Moderate => {
                        sanctions.push(Sanction {
                            sanction_type: SanctionType::VotingRestriction(604800), // 7 days
                            amount: 604800,
                            effective_date: Clock::get()?.unix_timestamp,
                            expiration_date: Some(Clock::get()?.unix_timestamp + 604800),
                            compliance_required: true,
                            compliance_description: "Complete voter education course".to_string(),
                        });
                    },
                    ViolationSeverity::Serious => {
                        sanctions.push(Sanction {
                            sanction_type: SanctionType::AccountSuspension(2592000), // 30 days
                            amount: 2592000,
                            effective_date: Clock::get()?.unix_timestamp,
                            expiration_date: Some(Clock::get()?.unix_timestamp + 2592000),
                            compliance_required: true,
                            compliance_description: "Demonstrate understanding of voting rules".to_string(),
                        });
                    },
                    ViolationSeverity::Severe => {
                        sanctions.push(Sanction {
                            sanction_type: SanctionType::AccountBan,
                            amount: 0,
                            effective_date: Clock::get()?.unix_timestamp,
                            expiration_date: None,
                            compliance_required: false,
                            compliance_description: "Permanent ban from platform".to_string(),
                        });
                    },
                    ViolationSeverity::Critical => {
                        // Criminal referral - handled externally
                        sanctions.push(Sanction {
                            sanction_type: SanctionType::AccountBan,
                            amount: 0,
                            effective_date: Clock::get()?.unix_timestamp,
                            expiration_date: None,
                            compliance_required: false,
                            compliance_description: "Referred to law enforcement".to_string(),
                        });
                    }
                }
            },
            
            ViolationType::FakeEvidence => {
                // Severe penalties for evidence tampering
                sanctions.push(Sanction {
                    sanction_type: SanctionType::StakeForfeiture(violation.total_penalty_amount),
                    amount: violation.total_penalty_amount,
                    effective_date: Clock::get()?.unix_timestamp,
                    expiration_date: None,
                    compliance_required: true,
                    compliance_description: "Public apology and evidence authenticity training".to_string(),
                });
            },
            
            _ => {
                // Default penalties based on severity
                let fine_amount = match violation.severity {
                    ViolationSeverity::Minor => 500000,      // 0.5 USD*
                    ViolationSeverity::Moderate => 2000000,  // 2 USD*
                    ViolationSeverity::Serious => 10000000,  // 10 USD*
                    ViolationSeverity::Severe => 50000000,   // 50 USD*
                    ViolationSeverity::Critical => 100000000, // 100 USD*
                };
                
                sanctions.push(Sanction {
                    sanction_type: SanctionType::MonetaryFine(fine_amount),
                    amount: fine_amount,
                    effective_date: Clock::get()?.unix_timestamp,
                    expiration_date: None,
                    compliance_required: false,
                    compliance_description: "".to_string(),
                });
            }
        }
        
        self.total_sanctions_imposed += sanctions.len() as u64;
        Ok(sanctions)
    }
    
    // Helper methods
    fn detect_vote_manipulation(&self, battle: &Battle) -> bool {
        // Simplified detection logic
        // In practice, would analyze voting patterns, timing, etc.
        battle.total_pot > 100000000 && battle.voting_end_time - battle.voting_start_time < 3600
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct PotentialViolation {
    pub violation_type: ViolationType,
    pub confidence: u8,              // 0-100% confidence
    pub evidence: String,
}

#[error_code]
pub enum EnforcementError {
    #[msg("Unauthorized to perform enforcement action")]
    UnauthorizedEnforcer,
    #[msg("Violation statute of limitations has expired")]
    StatuteOfLimitationsExpired,
    #[msg("Insufficient evidence to support violation")]
    InsufficientEvidence,
    #[msg("Sanctions already imposed for this violation")]
    DuplicateSanctions,
    #[msg("Payment required before appeal can be processed")]
    PaymentRequired,
}