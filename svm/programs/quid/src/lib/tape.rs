use anchor_lang::prelude::*;
use std::collections::HashMap;

#[account]
#[derive(InitSpace)]
pub struct EvidenceVault {
    pub evidence_id: u64,
    pub case_id: u64,              // Battle or appeal ID
    pub submitter: Pubkey,
    pub evidence_type: EvidenceType,
    pub admissibility_status: AdmissibilityStatus,
    
    // Digital forensics
    pub file_hash: [u8; 32],       // SHA-256 of original file
    pub ipfs_hash: String,         // Decentralized storage
    pub metadata_hash: [u8; 32],   // Metadata fingerprint
    pub timestamp_proof: i64,      // When evidence was created
    pub chain_of_custody: Vec<CustodyTransfer>,
    
    // Authentication
    pub digital_signature: [u8; 64], // Cryptographic signature
    pub signing_key: Pubkey,       // Who signed the evidence
    pub witness_attestations: Vec<WitnessAttestation>,
    pub authenticity_score: u8,    // 0-100 confidence in authenticity
    
    // Content analysis
    pub ai_analysis_results: AIAnalysisReport,
    pub human_verification: HumanVerification,
    pub forensic_report: ForensicReport,
    
    // Legal classification
    pub relevance_score: u8,       // How relevant to the case
    pub materiality: MaterialityLevel,
    pub privilege_claimed: Option<PrivilegeType>,
    pub redaction_required: bool,
    
    // Access control
    pub public_access: bool,
    pub authorized_viewers: Vec<Pubkey>,
    pub sealed_until: i64,         // Court-ordered sealing
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum EvidenceType {
    AudioRecording,      // Battle verses/responses
    VideoRecording,      // Visual battle evidence
    TextDocument,        // Written statements, briefs
    DigitalArtifact,     // Screenshots, social media
    ExpertTestimony,     // Professional analysis
    WitnessStatement,    // Third-party accounts
    TechnicalLogs,       // System records, blockchain data
    BiometricData,       // Voice prints, etc.
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum AdmissibilityStatus {
    Pending,            // Under review
    Admitted,           // Accepted as evidence
    Excluded,           // Rejected
    ConditionallyAdmitted, // Admitted with restrictions
    UnderSeal,          // Confidential/protected
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct CustodyTransfer {
    pub from_party: Pubkey,
    pub to_party: Pubkey,
    pub transfer_time: i64,
    pub transfer_method: String,
    pub integrity_verified: bool,
    pub transfer_signature: [u8; 64],
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct WitnessAttestation {
    pub witness: Pubkey,
    pub attestation_type: AttestationType,
    pub confidence_level: u8,      // 0-100
    pub sworn_statement: String,
    pub attestation_time: i64,
    pub witness_signature: [u8; 64],
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum AttestationType {
    IdentityVerification,   // Confirms who created evidence
    ContentAuthenticity,    // Confirms evidence is unaltered
    TimestampVerification,  // Confirms when evidence was created
    LocationVerification,   // Confirms where evidence originated
    ProcessWitness,         // Witnessed the evidence creation
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct AIAnalysisReport {
    pub deepfake_probability: u8,    // 0-100% chance of being AI-generated
    pub voice_match_confidence: u8,  // For audio, match to known voice
    pub content_analysis: ContentAnalysis,
    pub technical_anomalies: Vec<String>,
    pub ai_model_used: String,
    pub analysis_timestamp: i64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct ContentAnalysis {
    pub sentiment_score: i8,         // -100 to +100
    pub toxicity_score: u8,          // 0-100
    pub authenticity_markers: Vec<String>,
    pub linguistic_patterns: Vec<String>,
    pub suspicious_elements: Vec<String>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct HumanVerification {
    pub expert_verifier: Pubkey,
    pub verification_method: String,
    pub confidence_assessment: u8,
    pub verification_report: String,
    pub verification_timestamp: i64,
    pub expert_credentials: ExpertCredentials,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct ExpertCredentials {
    pub certification_body: String,
    pub specialization: String,
    pub years_experience: u8,
    pub previous_cases: u16,
    pub accuracy_rating: u8,        // Historical accuracy of expert
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct ForensicReport {
    pub file_integrity_verified: bool,
    pub metadata_analysis: MetadataAnalysis,
    pub temporal_analysis: TemporalAnalysis,
    pub compression_artifacts: Vec<String>,
    pub editing_evidence: Vec<String>,
    pub source_device_analysis: DeviceAnalysis,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct MetadataAnalysis {
    pub creation_software: String,
    pub camera_model: String,
    pub gps_coordinates: Option<[f64; 2]>,
    pub creation_timestamp: i64,
    pub modification_history: Vec<String>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct TemporalAnalysis {
    pub timestamp_consistency: bool,
    pub sequence_analysis: String,
    pub gap_detection: Vec<String>,
    pub synchronization_check: bool,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct DeviceAnalysis {
    pub device_fingerprint: String,
    pub device_type: String,
    pub operating_system: String,
    pub sensor_data: Vec<String>,
    pub unique_identifiers: Vec<String>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum MaterialityLevel {
    HighlyMaterial,     // Central to the case
    Material,           // Important to case outcome
    SomewhatMaterial,   // Relevant but not decisive
    Immaterial,         // Not relevant to case
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum PrivilegeType {
    AttorneyClient,     // Legal advice privilege
    WorkProduct,        // Litigation preparation
    TradeSecret,        // Commercial confidentiality
    PersonalPrivacy,    // Individual privacy rights
    NationalSecurity,   // Security concerns
}

/// Evidence validation and authentication system
impl EvidenceVault {
    /// Comprehensive evidence authentication
    pub fn authenticate_evidence(&mut self) -> Result<AuthenticationResult> {
        let mut result = AuthenticationResult {
            is_authentic: true,
            confidence_score: 100,
            authentication_flags: Vec::new(),
            required_disclosures: Vec::new(),
        };
        
        // 1. Digital Signature Verification
        if !self.verify_digital_signature() {
            result.authentication_flags.push(AuthenticationFlag::InvalidSignature);
            result.confidence_score -= 30;
        }
        
        // 2. Chain of Custody Verification
        if !self.verify_chain_of_custody() {
            result.authentication_flags.push(AuthenticationFlag::BrokenChainOfCustody);
            result.confidence_score -= 25;
        }
        
        // 3. AI Analysis Check
        if self.ai_analysis_results.deepfake_probability > 70 {
            result.authentication_flags.push(AuthenticationFlag::PossibleDeepfake);
            result.confidence_score -= 40;
        }
        
        // 4. Timestamp Verification
        if !self.verify_timestamp_integrity() {
            result.authentication_flags.push(AuthenticationFlag::TimestampInconsistency);
            result.confidence_score -= 20;
        }
        
        // 5. Content Integrity Check
        if !self.verify_content_integrity() {
            result.authentication_flags.push(AuthenticationFlag::ContentAltered);
            result.confidence_score -= 50;
        }
        
        // Final authentication decision
        result.is_authentic = result.confidence_score >= 60; // 60% threshold
        self.authenticity_score = result.confidence_score;
        
        Ok(result)
    }
    
    /// Check admissibility under evidence rules
    pub fn check_admissibility(&self, evidence_rules: &EvidenceRules) -> Result<AdmissibilityDecision> {
        let mut decision = AdmissibilityDecision {
            is_admissible: true,
            conditional_requirements: Vec::new(),
            exclusion_reasons: Vec::new(),
        };
        
        // Relevance test
        if self.relevance_score < evidence_rules.minimum_relevance_threshold {
            decision.exclusion_reasons.push(ExclusionReason::NotRelevant);
            decision.is_admissible = false;
        }
        
        // Authentication test
        if self.authenticity_score < evidence_rules.minimum_authenticity_threshold {
            decision.exclusion_reasons.push(ExclusionReason::NotAuthenticated);
            decision.is_admissible = false;
        }
        
        // Hearsay analysis
        if self.evidence_type == EvidenceType::WitnessStatement && !self.has_hearsay_exception() {
            decision.exclusion_reasons.push(ExclusionReason::Hearsay);
            decision.is_admissible = false;
        }
        
        // Privilege check
        if let Some(privilege) = &self.privilege_claimed {
            if !evidence_rules.privilege_waived(privilege) {
                decision.exclusion_reasons.push(ExclusionReason::Privileged);
                decision.is_admissible = false;
            }
        }
        
        // Best evidence rule (for documents)
        if self.evidence_type == EvidenceType::TextDocument && !self.is_original() {
            decision.conditional_requirements.push(AdmissibilityCondition::ExplainAbsenceOfOriginal);
        }
        
        Ok(decision)
    }
    
    // Helper methods for authentication
    fn verify_digital_signature(&self) -> bool {
        // Cryptographic signature verification
        true // Simplified
    }
    
    fn verify_chain_of_custody(&self) -> bool {
        // Check all custody transfers are valid
        self.chain_of_custody.iter().all(|transfer| transfer.integrity_verified)
    }
    
    fn verify_timestamp_integrity(&self) -> bool {
        // Cross-reference timestamps for consistency
        self.forensic_report.temporal_analysis.timestamp_consistency
    }
    
    fn verify_content_integrity(&self) -> bool {
        // Check if content has been altered
        self.forensic_report.file_integrity_verified
    }
    
    fn has_hearsay_exception(&self) -> bool {
        // Check if statement falls under hearsay exception
        true // Simplified
    }
    
    fn is_original(&self) -> bool {
        // Check if this is the original document
        self.chain_of_custody.is_empty() // No transfers means original
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct AuthenticationResult {
    pub is_authentic: bool,
    pub confidence_score: u8,
    pub authentication_flags: Vec<AuthenticationFlag>,
    pub required_disclosures: Vec<String>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct AdmissibilityDecision {
    pub is_admissible: bool,
    pub conditional_requirements: Vec<AdmissibilityCondition>,
    pub exclusion_reasons: Vec<ExclusionReason>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq)]
pub enum AuthenticationFlag {
    InvalidSignature,
    BrokenChainOfCustody,
    PossibleDeepfake,
    TimestampInconsistency,
    ContentAltered,
    InsufficientWitnesses,
    UnverifiedSource,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq)]
pub enum ExclusionReason {
    NotRelevant,
    NotAuthenticated,
    Hearsay,
    Privileged,
    Prejudicial,
    BestEvidenceViolation,
    IllegallyObtained,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq)]
pub enum AdmissibilityCondition {
    ExplainAbsenceOfOriginal,
    ProvideAuthenticatingWitness,
    RedactPrivilegedPortions,
    LimitedPurposeOnly,
    UnderSeal,
}

pub struct EvidenceRules {
    pub minimum_relevance_threshold: u8,
    pub minimum_authenticity_threshold: u8,
}

impl EvidenceRules {
    fn privilege_waived(&self, _privilege: &PrivilegeType) -> bool {
        false // Default: privilege not waived
    }
}