use anchor_lang::prelude::*;
use std::collections::HashMap;

#[derive(Clone)]
pub struct SICBattleCategory {
    pub sic_code: String,
    pub industry_description: String,
}

impl SICBattleCategory {
    pub fn new(sic_code: &str, industry_description: &str) -> Self {
        Self {
            sic_code: sic_code.to_string(),
            industry_description: industry_description.to_string(),
        }
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct StandardizedBattleDescription {
    #[max_len(10)]
    pub primary_sic_code: String,
    #[max_len(100)]
    pub primary_industry: String,
    #[max_len(5)]
    pub secondary_sic_codes: Vec<String>,
    #[max_len(200)]
    pub standardized_description: String,
    #[max_len(10)]
    pub recognized_hashtags: Vec<String>,
    #[max_len(10)]
    pub unrecognized_hashtags: Vec<String>,
    pub battle_category: BattleCategoryType,
    pub difficulty_tier: DifficultyTier,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum BattleCategoryType {
    Musical,
    Media,
    Gaming,
    Technology,
    Sports,
    Educational,
    Professional,
    Creative,
    General,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum DifficultyTier {
    Beginner,
    Intermediate,
    Advanced,
    Professional,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum BattleStatus {
    PendingAcceptance,
    Matched,
    Active,
    VotingPhase,
    Completed,
    Cancelled,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq, InitSpace)]
pub enum BattleVote {
    Challenger,
    Defender,
    Tie,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct BattleChallengeData {
    #[max_len(100)]
    pub twitter_challenge_url: String,
    #[max_len(50)]
    pub challenger_username: String,
    #[max_len(50)]
    pub challenged_username: String,
    #[max_len(200)]
    pub defender_response_url: String,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct BattleVerse {
    pub verse_number: u8,
    #[max_len(140)]
    pub lyrics: String,
    pub start_time: u64,
    pub end_time: u64,
    pub confidence_score: u8,
}

#[account]
#[derive(InitSpace)]
pub struct BattleConfig {
    pub bump: u8,
    pub authority: Pubkey,
    pub battle_window_start: u64,
    pub battle_window_end: u64,
    pub min_stake_amount: u64,
    pub organizer_fee_bps: u16,
    pub randomness_account: Pubkey,
    pub battle_count: u64,
    pub total_volume: u64,
}

#[account]
#[derive(InitSpace)]
pub struct Battle {
    pub battle_id: u64,
    pub challenger: Pubkey,
    #[max_len(50)]
    pub challenged_user: String,
    pub defender: Pubkey,
    pub stake_amount: u64,
    pub total_pot: u64,
    pub status: BattleStatus,
    pub challenge_data: BattleChallengeData,
    pub standardized_description: StandardizedBattleDescription,
    pub challenger_commit_hash: [u8; 32],
    pub defender_commit_hash: [u8; 32],
    pub created_at: i64,
    pub acceptance_deadline: i64,
    pub matched_at: i64,
    pub battle_start_time: i64,
    pub edit_window_end: i64,
    pub voting_start_time: i64,
    pub voting_end_time: i64,
    pub completed_at: i64,
    pub winner: Pubkey,
    pub randomness_account: Pubkey,
    pub turn_order_revealed: bool,
    pub challenger_goes_first: bool,
    pub challenger_revealed: bool,
    pub defender_revealed: bool,
    #[max_len(4)]
    pub challenger_verses: Vec<BattleVerse>,
    #[max_len(4)]
    pub defender_verses: Vec<BattleVerse>,
    #[max_len(200)]
    pub challenger_recording_uri: String,
    #[max_len(200)]
    pub defender_recording_uri: String,
}

#[account]
#[derive(InitSpace)]
pub struct CommunityVoterRecord {
    pub voter: Pubkey,
    pub battle_id: u64,
    pub vote: BattleVote,
    pub stake_amount: u64,
    pub voted_at: i64,
    pub has_voted: bool,
}

// Hashtag to SIC Code Translation Library
pub struct HashtagSICTranslator {
    hashtag_mappings: HashMap<&'static str, SICBattleCategory>,
}

impl HashtagSICTranslator {
    pub fn new() -> Self {
        let mut mappings = HashMap::new();
        
        // Music & Entertainment Industry (SIC 7929, 7922)
        mappings.insert("rapbattle", SICBattleCategory::new("7929", "Band and Orchestra"));
        mappings.insert("hiphop", SICBattleCategory::new("7929", "Musical Entertainment"));
        mappings.insert("freestyle", SICBattleCategory::new("7929", "Live Music Performance"));
        mappings.insert("cypher", SICBattleCategory::new("7929", "Musical Competition"));
        mappings.insert("bars", SICBattleCategory::new("7929", "Lyrical Performance"));
        mappings.insert("spitfire", SICBattleCategory::new("7929", "Competitive Music"));
        mappings.insert("beatbattle", SICBattleCategory::new("7929", "Musical Production"));
        
        // Broadcasting & Media (SIC 4833, 7812)
        mappings.insert("viral", SICBattleCategory::new("4833", "Television Broadcasting"));
        mappings.insert("trending", SICBattleCategory::new("4833", "Media Distribution"));
        mappings.insert("content", SICBattleCategory::new("7812", "Motion Picture Production"));
        mappings.insert("social", SICBattleCategory::new("4833", "Social Media Broadcasting"));
        mappings.insert("livestream", SICBattleCategory::new("4833", "Live Broadcasting"));
        
        // Gaming & Competition (SIC 7993, 7999)
        mappings.insert("battle", SICBattleCategory::new("7993", "Coin-Operated Amusement"));
        mappings.insert("competition", SICBattleCategory::new("7999", "Competitive Entertainment"));
        mappings.insert("tournament", SICBattleCategory::new("7999", "Tournament Organization"));
        mappings.insert("esports", SICBattleCategory::new("7993", "Electronic Sports"));
        mappings.insert("challenge", SICBattleCategory::new("7999", "Challenge Entertainment"));
        
        // Technology & Web3 (SIC 7372, 6099)
        mappings.insert("web3", SICBattleCategory::new("7372", "Prepackaged Software"));
        mappings.insert("crypto", SICBattleCategory::new("6099", "Functions Related to Depository Banking"));
        mappings.insert("nft", SICBattleCategory::new("7372", "Digital Asset Management"));
        mappings.insert("blockchain", SICBattleCategory::new("7372", "Distributed Ledger Technology"));
        mappings.insert("defi", SICBattleCategory::new("6099", "Decentralized Finance"));
        
        // Sports & Athletics (SIC 7941, 7991)
        mappings.insert("basketball", SICBattleCategory::new("7941", "Professional Sports Clubs"));
        mappings.insert("athlete", SICBattleCategory::new("7941", "Athletic Competition"));
        mappings.insert("training", SICBattleCategory::new("7991", "Physical Fitness Facilities"));
        
        // Education & Skills (SIC 8299, 8243)
        mappings.insert("skills", SICBattleCategory::new("8299", "Schools and Educational Services"));
        mappings.insert("learning", SICBattleCategory::new("8243", "Data Processing Schools"));
        mappings.insert("workshop", SICBattleCategory::new("8299", "Vocational Schools"));
        
        // Business & Professional (SIC 8999, 7389)
        mappings.insert("entrepreneur", SICBattleCategory::new("8999", "Services, Not Elsewhere Classified"));
        mappings.insert("business", SICBattleCategory::new("7389", "Business Services"));
        mappings.insert("professional", SICBattleCategory::new("8999", "Professional Services"));
        
        // Art & Creative (SIC 8999, 5999)
        mappings.insert("art", SICBattleCategory::new("8999", "Artists and Performers"));
        mappings.insert("creative", SICBattleCategory::new("8999", "Creative Services"));
        mappings.insert("design", SICBattleCategory::new("7336", "Commercial Art and Graphic Design"));
        
        Self { hashtag_mappings: mappings }
    }
    
    pub fn translate_hashtags_to_description(&self, hashtags: &[String]) -> StandardizedBattleDescription {
        let mut primary_category: Option<SICBattleCategory> = None;
        let mut secondary_categories: Vec<SICBattleCategory> = Vec::new();
        let mut recognized_hashtags: Vec<String> = Vec::new();
        let mut unrecognized_hashtags: Vec<String> = Vec::new();
        
        for hashtag in hashtags {
            let clean_tag = hashtag.trim_start_matches('#').to_lowercase();
            
            if let Some(category) = self.hashtag_mappings.get(clean_tag.as_str()) {
                recognized_hashtags.push(clean_tag.clone());
                
                if primary_category.is_none() {
                    primary_category = Some(category.clone());
                } else {
                    secondary_categories.push(category.clone());
                }
            } else {
                unrecognized_hashtags.push(clean_tag);
            }
        }
        
        let primary = primary_category.unwrap_or_else(|| {
            SICBattleCategory::new("7929", "Musical Entertainment")
        });
        
        let description = self.generate_battle_description(&primary, &secondary_categories, &recognized_hashtags);
        
        StandardizedBattleDescription {
            primary_sic_code: primary.sic_code.clone(),
            primary_industry: primary.industry_description.clone(),
            secondary_sic_codes: secondary_categories.iter().map(|c| c.sic_code.clone()).collect(),
            standardized_description: description,
            recognized_hashtags,
            unrecognized_hashtags,
            battle_category: self.determine_battle_category(&primary),
            difficulty_tier: self.calculate_difficulty_tier(&recognized_hashtags),
        }
    }
    
    fn generate_battle_description(&self, primary: &SICBattleCategory, secondary: &[SICBattleCategory], hashtags: &[String]) -> String {
        let category_name = self.determine_battle_category(primary);
        let complexity = if secondary.is_empty() { "Standard" } else { "Multi-Category" };
        let skill_indicators = hashtags.iter()
            .filter(|&tag| ["freestyle", "professional", "expert", "advanced"].contains(&tag.as_str()))
            .collect::<Vec<_>>();
        
        let skill_level = if skill_indicators.is_empty() {
            "Open Division"
        } else {
            "Professional Division"
        };
        
        format!(
            "{} {} Battle - {} (SIC: {}) - {}",
            complexity,
            match category_name {
                BattleCategoryType::Musical => "Musical",
                BattleCategoryType::Media => "Media",
                BattleCategoryType::Gaming => "Gaming",
                BattleCategoryType::Technology => "Technology",
                BattleCategoryType::Sports => "Sports",
                BattleCategoryType::Educational => "Educational",
                BattleCategoryType::Professional => "Professional",
                BattleCategoryType::Creative => "Creative",
                BattleCategoryType::General => "General",
            },
            skill_level,
            primary.sic_code,
            primary.industry_description
        )
    }
    
    fn determine_battle_category(&self, sic_category: &SICBattleCategory) -> BattleCategoryType {
        match sic_category.sic_code.as_str() {
            "7929" => BattleCategoryType::Musical,
            "4833" | "7812" => BattleCategoryType::Media,
            "7993" | "7999" => BattleCategoryType::Gaming,
            "7372" | "6099" => BattleCategoryType::Technology,
            "7941" | "7991" => BattleCategoryType::Sports,
            "8299" | "8243" => BattleCategoryType::Educational,
            "8999" | "7389" => BattleCategoryType::Professional,
            "7336" => BattleCategoryType::Creative,
            _ => BattleCategoryType::General,
        }
    }
    
    fn calculate_difficulty_tier(&self, hashtags: &[String]) -> DifficultyTier {
        let professional_indicators = ["professional", "expert", "master", "champion"];
        let advanced_indicators = ["advanced", "skilled", "experienced", "veteran"];
        let beginner_indicators = ["beginner", "newbie", "learning", "practice"];
        
        let has_professional = hashtags.iter().any(|tag| professional_indicators.contains(&tag.as_str()));
        let has_advanced = hashtags.iter().any(|tag| advanced_indicators.contains(&tag.as_str()));
        let has_beginner = hashtags.iter().any(|tag| beginner_indicators.contains(&tag.as_str()));
        
        if has_professional {
            DifficultyTier::Professional
        } else if has_advanced {
            DifficultyTier::Advanced
        } else if has_beginner {
            DifficultyTier::Beginner
        } else {
            DifficultyTier::Intermediate
        }
    }
}

// Helper function for commit-reveal
pub fn create_commit_hash(verses: &[BattleVerse], recording_uri: &str, nonce: u64) -> [u8; 32] {
    use anchor_lang::solana_program::hash::{hash, Hash};
    
    let mut data = Vec::new();
    for verse in verses {
        data.extend_from_slice(verse.lyrics.as_bytes());
        data.extend_from_slice(&verse.start_time.to_le_bytes());
        data.extend_from_slice(&verse.end_time.to_le_bytes());
    }
    data.extend_from_slice(recording_uri.as_bytes());
    data.extend_from_slice(&nonce.to_le_bytes());
    
    hash(&data).to_bytes()
}