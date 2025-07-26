use anchor_lang::prelude::*;
use anchor_lang::system_program;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_interface::{mint_to, Mint, MintTo, TokenAccount, TokenInterface}
};
use switchboard_on_demand::accounts::RandomnessAccountData;
use anchor_spl::metadata::{
    Metadata,
    MetadataAccount,
    CreateMetadataAccountsV3,
    CreateMasterEditionV3,
    SignMetadata,
    SetAndVerifySizedCollectionItem,
    create_master_edition_v3,
    create_metadata_accounts_v3,
    sign_metadata,
    set_and_verify_sized_collection_item,
    mpl_token_metadata::types::{
        CollectionDetails,
        Creator, 
        DataV2,
    },
};

use crate::lib::battle_state::*;
use crate::lib::battle_events::*;
use crate::lib::battle_errors::*;
use crate::lib::battle_contexts::*;
use crate::lib::{BATTLE_NAME, BATTLE_URI, BATTLE_SYMBOL};

/// Initialize battle configuration with timing and staking parameters
pub fn initialize_battle_config(
    ctx: Context<InitializeBattleConfig>, 
    battle_window_start: u64,
    battle_window_end: u64, 
    min_stake_amount: u64,
    organizer_fee_bps: u16, // basis points (100 = 1%)
) -> Result<()> {
    require!(organizer_fee_bps <= 1000, BattleError::ExcessiveOrganizerFee); // Max 10%
    require!(battle_window_start < battle_window_end, BattleError::InvalidTimeWindow);
    
    let battle_config = &mut ctx.accounts.battle_config;
    battle_config.bump = ctx.bumps.battle_config;
    battle_config.battle_window_start = battle_window_start;
    battle_config.battle_window_end = battle_window_end;
    battle_config.min_stake_amount = min_stake_amount;
    battle_config.organizer_fee_bps = organizer_fee_bps;
    battle_config.authority = ctx.accounts.payer.key();
    battle_config.randomness_account = Pubkey::default();
    battle_config.battle_count = 0;
    battle_config.total_volume = 0;

    emit!(BattleConfigInitialized {
        config: battle_config.key(),
        authority: battle_config.authority,
        min_stake: min_stake_amount,
        organizer_fee: organizer_fee_bps,
    });

    Ok(())
}

/// Initialize Re-Chat battle collection NFT
pub fn initialize_battle_collection(ctx: Context<InitializeBattleCollection>) -> Result<()> {
    let signer_seeds: &[&[&[u8]]] = &[&[
        b"battle_collection".as_ref(),
        &[ctx.bumps.collection_mint],
    ]];

    msg!("Creating battle collection mint");
    mint_to(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            MintTo {
                mint: ctx.accounts.collection_mint.to_account_info(),
                to: ctx.accounts.collection_token_account.to_account_info(),
                authority: ctx.accounts.collection_mint.to_account_info(),
            },
            signer_seeds,
        ),
        1,
    )?;

    msg!("Creating battle collection metadata");
    create_metadata_accounts_v3(
        CpiContext::new_with_signer(
            ctx.accounts.token_metadata_program.to_account_info(),
            CreateMetadataAccountsV3 {
                metadata: ctx.accounts.metadata.to_account_info(),
                mint: ctx.accounts.collection_mint.to_account_info(),
                mint_authority: ctx.accounts.collection_mint.to_account_info(),
                update_authority: ctx.accounts.collection_mint.to_account_info(),
                payer: ctx.accounts.payer.to_account_info(),
                system_program: ctx.accounts.system_program.to_account_info(),
                rent: ctx.accounts.rent.to_account_info(),
            },
            &signer_seeds,
        ),
        DataV2 {
            name: BATTLE_NAME.to_string(),
            symbol: BATTLE_SYMBOL.to_string(),
            uri: BATTLE_URI.to_string(),
            seller_fee_basis_points: 0,
            creators: Some(vec![Creator {
                address: ctx.accounts.collection_mint.key(),
                verified: false,
                share: 100,
            }]),
            collection: None,
            uses: None,
        },
        true,
        true,
        Some(CollectionDetails::V1 { size: 0 }),
    )?;

    msg!("Creating master edition for collection");
    create_master_edition_v3(
        CpiContext::new_with_signer(
            ctx.accounts.token_metadata_program.to_account_info(),
            CreateMasterEditionV3 {
                payer: ctx.accounts.payer.to_account_info(),
                mint: ctx.accounts.collection_mint.to_account_info(),
                edition: ctx.accounts.master_edition.to_account_info(),
                mint_authority: ctx.accounts.collection_mint.to_account_info(),
                update_authority: ctx.accounts.collection_mint.to_account_info(),
                metadata: ctx.accounts.metadata.to_account_info(),
                token_program: ctx.accounts.token_program.to_account_info(),
                system_program: ctx.accounts.system_program.to_account_info(),
                rent: ctx.accounts.rent.to_account_info(),
            },
            &signer_seeds,
        ),
        Some(0),
    )?;

    msg!("Signing collection metadata");
    sign_metadata(CpiContext::new_with_signer(
        ctx.accounts.token_metadata_program.to_account_info(),
        SignMetadata {
            creator: ctx.accounts.collection_mint.to_account_info(),
            metadata: ctx.accounts.metadata.to_account_info(),
        },
        &signer_seeds,
    ))?;

    Ok(())
}

/// Create a new Re-Chat battle challenge with standardized description
pub fn create_battle_challenge(
    ctx: Context<CreateBattleChallenge>,
    challenge_data: BattleChallengeData,
    stake_amount: u64,
    commit_hash: [u8; 32], // Commit hash for verses/recording
    hashtags: Vec<String>, // Twitter hashtags for categorization
) -> Result<()> {
    let clock = Clock::get()?;
    let battle_config = &mut ctx.accounts.battle_config;
    let battle = &mut ctx.accounts.battle;

    // Validate timing
    require!(
        clock.slot >= battle_config.battle_window_start && 
        clock.slot <= battle_config.battle_window_end,
        BattleError::BattleWindowClosed
    );

    // Validate stake amount
    require!(stake_amount >= battle_config.min_stake_amount, BattleError::InsufficientStake);

    // Validate challenge data
    require!(!challenge_data.twitter_challenge_url.is_empty(), BattleError::InvalidChallengeData);
    require!(!challenge_data.challenged_username.is_empty(), BattleError::InvalidChallengeData);
    require!(!challenge_data.challenger_username.is_empty(), BattleError::InvalidChallengeData);

    // Translate hashtags to standardized battle description
    let translator = HashtagSICTranslator::new();
    let standardized_desc = translator.translate_hashtags_to_description(&hashtags);
    
    // Validate that we have at least some categorization
    require!(
        !standardized_desc.recognized_hashtags.is_empty() || !hashtags.is_empty(),
        BattleError::InsufficientCategorization
    );

    // Transfer stake to battle escrow
    system_program::transfer(
        CpiContext::new(
            ctx.accounts.system_program.to_account_info(),
            system_program::Transfer {
                from: ctx.accounts.challenger.to_account_info(),
                to: ctx.accounts.battle.to_account_info(),
            },
        ),
        stake_amount,
    )?;

    // Initialize battle state with standardized description
    battle.battle_id = battle_config.battle_count;
    battle.challenger = ctx.accounts.challenger.key();
    battle.challenged_user = challenge_data.challenged_username.clone();
    battle.defender = Pubkey::default(); // Set when accepted
    battle.stake_amount = stake_amount;
    battle.total_pot = stake_amount;
    battle.status = BattleStatus::PendingAcceptance;
    battle.challenge_data = challenge_data;
    battle.standardized_description = standardized_desc;
    battle.challenger_commit_hash = commit_hash;
    battle.defender_commit_hash = [0; 32]; // Set when defender joins
    battle.created_at = clock.unix_timestamp;
    battle.acceptance_deadline = clock.unix_timestamp + (24 * 60 * 60); // 24 hours
    battle.edit_window_end = 0;
    battle.winner = Pubkey::default();
    battle.randomness_account = Pubkey::default();
    battle.turn_order_revealed = false;
    battle.challenger_goes_first = false;

    // Update config
    battle_config.battle_count += 1;
    battle_config.total_volume += stake_amount;

    emit!(BattleChallengeCreated {
        battle_id: battle.battle_id,
        challenger: battle.challenger,
        challenged_user: battle.challenged_user.clone(),
        stake_amount: stake_amount,
        twitter_url: battle.challenge_data.twitter_challenge_url.clone(),
        sic_code: battle.standardized_description.primary_sic_code.clone(),
        battle_category: battle.standardized_description.battle_category,
        difficulty_tier: battle.standardized_description.difficulty_tier,
    });

    Ok(())
}

/// Accept a battle challenge and match the stake
pub fn accept_battle_challenge(
    ctx: Context<AcceptBattleChallenge>,
    defender_commit_hash: [u8; 32],
    defender_response_url: String,
) -> Result<()> {
    let clock = Clock::get()?;
    let battle = &mut ctx.accounts.battle;

    // Validate battle state
    require!(battle.status == BattleStatus::PendingAcceptance, BattleError::InvalidBattleState);
    require!(clock.unix_timestamp <= battle.acceptance_deadline, BattleError::AcceptanceDeadlinePassed);

    // Verify defender matches challenged user (in real implementation, verify Twitter username)
    // For now, just ensure it's not the challenger
    require!(ctx.accounts.defender.key() != battle.challenger, BattleError::CannotChallengeSelf);

    // Match the stake
    system_program::transfer(
        CpiContext::new(
            ctx.accounts.system_program.to_account_info(),
            system_program::Transfer {
                from: ctx.accounts.defender.to_account_info(),
                to: ctx.accounts.battle.to_account_info(),
            },
        ),
        battle.stake_amount,
    )?;

    // Update battle state
    battle.defender = ctx.accounts.defender.key();
    battle.defender_commit_hash = defender_commit_hash;
    battle.challenge_data.defender_response_url = defender_response_url;
    battle.total_pot = battle.stake_amount * 2;
    battle.status = BattleStatus::Matched;
    battle.matched_at = clock.unix_timestamp;

    emit!(BattleChallengeAccepted {
        battle_id: battle.battle_id,
        defender: battle.defender,
        total_pot: battle.total_pot,
    });

    Ok(())
}

/// Commit randomness account for turn order determination
pub fn commit_battle_randomness(ctx: Context<CommitBattleRandomness>) -> Result<()> {
    let clock = Clock::get()?;
    let battle = &mut ctx.accounts.battle;
    let battle_config = &ctx.accounts.battle_config;

    // Validate authority
    require!(ctx.accounts.authority.key() == battle_config.authority, BattleError::UnauthorizedRandomnessCommit);
    require!(battle.status == BattleStatus::Matched, BattleError::InvalidBattleState);

    // Validate randomness account
    let randomness_data = RandomnessAccountData::parse(ctx.accounts.randomness_account_data.data.borrow()).unwrap();
    require!(randomness_data.seed_slot == clock.slot - 1, BattleError::InvalidRandomnessSlot);

    battle.randomness_account = ctx.accounts.randomness_account_data.key();

    emit!(BattleRandomnessCommitted {
        battle_id: battle.battle_id,
        randomness_account: battle.randomness_account,
    });

    Ok(())
}

/// Reveal turn order and start battle
pub fn reveal_turn_order_and_start(ctx: Context<RevealTurnOrder>) -> Result<()> {
    let clock = Clock::get()?;
    let battle = &mut ctx.accounts.battle;

    // Validate randomness account matches
    require!(ctx.accounts.randomness_account_data.key() == battle.randomness_account, BattleError::IncorrectRandomnessAccount);
    require!(battle.status == BattleStatus::Matched, BattleError::InvalidBattleState);

    // Get randomness value
    let randomness_data = RandomnessAccountData::parse(ctx.accounts.randomness_account_data.data.borrow()).unwrap();
    let revealed_random_value = randomness_data.get_value(&clock)
        .map_err(|_| BattleError::RandomnessNotResolved)?;

    // Determine turn order (true = challenger goes first)
    battle.challenger_goes_first = (revealed_random_value[0] % 2) == 0;
    battle.turn_order_revealed = true;
    battle.status = BattleStatus::Active;
    battle.battle_start_time = clock.unix_timestamp;
    battle.edit_window_end = clock.unix_timestamp + (60 * 60); // 1 hour edit window

    emit!(BattleTurnOrderRevealed {
        battle_id: battle.battle_id,
        challenger_goes_first: battle.challenger_goes_first,
        edit_window_end: battle.edit_window_end,
    });

    Ok(())
}

/// Reveal battle verses and recording (commit-reveal)
pub fn reveal_battle_entry(
    ctx: Context<RevealBattleEntry>,
    verses: Vec<BattleVerse>,
    recording_uri: String,
    nonce: u64,
) -> Result<()> {
    let battle = &mut ctx.accounts.battle;
    let participant = ctx.accounts.participant.key();

    // Validate battle state
    require!(battle.status == BattleStatus::Active, BattleError::InvalidBattleState);

    // Verify commit hash
    let expected_hash = create_commit_hash(&verses, &recording_uri, nonce);
    
    if participant == battle.challenger {
        require!(expected_hash == battle.challenger_commit_hash, BattleError::InvalidCommitReveal);
        battle.challenger_verses = verses;
        battle.challenger_recording_uri = recording_uri;
        battle.challenger_revealed = true;
    } else if participant == battle.defender {
        require!(expected_hash == battle.defender_commit_hash, BattleError::InvalidCommitReveal);
        battle.defender_verses = verses;
        battle.defender_recording_uri = recording_uri;
        battle.defender_revealed = true;
    } else {
        return Err(BattleError::UnauthorizedParticipant.into());
    }

    // Check if both participants have revealed
    if battle.challenger_revealed && battle.defender_revealed {
        battle.status = BattleStatus::VotingPhase;
        battle.voting_start_time = Clock::get()?.unix_timestamp;
        battle.voting_end_time = battle.voting_start_time + (48 * 60 * 60); // 48 hour voting period
    }

    emit!(BattleEntryRevealed {
        battle_id: battle.battle_id,
        participant: participant,
        verse_count: if participant == battle.challenger { battle.challenger_verses.len() } else { battle.defender_verses.len() },
    });

    Ok(())
}

/// Submit community vote on battle outcome
pub fn submit_community_vote(
    ctx: Context<SubmitCommunityVote>,
    vote: BattleVote,
    stake_amount: u64,
) -> Result<()> {
    let battle = &ctx.accounts.battle;
    let voter_record = &mut ctx.accounts.voter_record;
    let clock = Clock::get()?;

    // Validate voting window
    require!(battle.status == BattleStatus::VotingPhase, BattleError::InvalidBattleState);
    require!(clock.unix_timestamp <= battle.voting_end_time, BattleError::VotingWindowClosed);

    // Prevent double voting
    require!(!voter_record.has_voted, BattleError::AlreadyVoted);

    // Validate vote
    require!(vote == BattleVote::Challenger || vote == BattleVote::Defender, BattleError::InvalidVote);

    // Transfer stake for voting
    if stake_amount > 0 {
        system_program::transfer(
            CpiContext::new(
                ctx.accounts.system_program.to_account_info(),
                system_program::Transfer {
                    from: ctx.accounts.voter.to_account_info(),
                    to: ctx.accounts.battle.to_account_info(),
                },
            ),
            stake_amount,
        )?;
    }

    // Record vote
    voter_record.voter = ctx.accounts.voter.key();
    voter_record.battle_id = battle.battle_id;
    voter_record.vote = vote;
    voter_record.stake_amount = stake_amount;
    voter_record.voted_at = clock.unix_timestamp;
    voter_record.has_voted = true;

    emit!(CommunityVoteSubmitted {
        battle_id: battle.battle_id,
        voter: voter_record.voter,
        vote: vote,
        stake_amount: stake_amount,
    });

    Ok(())
}

/// Finalize battle results based on community voting
pub fn finalize_battle_results(ctx: Context<FinalizeBattleResults>) -> Result<()> {
    let battle = &mut ctx.accounts.battle;
    let battle_config = &ctx.accounts.battle_config;
    let clock = Clock::get()?;

    // Validate timing and authority
    require!(battle.status == BattleStatus::VotingPhase, BattleError::InvalidBattleState);
    require!(clock.unix_timestamp > battle.voting_end_time, BattleError::VotingStillActive);
    require!(ctx.accounts.authority.key() == battle_config.authority, BattleError::UnauthorizedFinalization);

    // Calculate vote results (simplified - in practice would aggregate all votes)
    // For now, just random winner selection
    let winner_is_challenger = (clock.unix_timestamp % 2) == 0;
    battle.winner = if winner_is_challenger { battle.challenger } else { battle.defender };
    battle.status = BattleStatus::Completed;
    battle.completed_at = clock.unix_timestamp;

    // Calculate payouts
    let organizer_fee = (battle.total_pot * battle_config.organizer_fee_bps as u64) / 10000;
    let winner_payout = battle.total_pot - organizer_fee;

    // Transfer winnings to winner
    **battle.to_account_info().try_borrow_mut_lamports()? -= winner_payout;
    **ctx.accounts.winner.try_borrow_mut_lamports()? += winner_payout;

    // Transfer organizer fee
    if organizer_fee > 0 {
        **battle.to_account_info().try_borrow_mut_lamports()? -= organizer_fee;
        **ctx.accounts.organizer_fee_account.try_borrow_mut_lamports()? += organizer_fee;
    }

    emit!(BattleFinalized {
        battle_id: battle.battle_id,
        winner: battle.winner,
        winner_payout: winner_payout,
        organizer_fee: organizer_fee,
    });

    Ok(())
}

/// Mint battle entry NFT for participants
pub fn mint_battle_entry_nft(ctx: Context<MintBattleEntryNFT>) -> Result<()> {
    let battle = &ctx.accounts.battle;
    let participant = ctx.accounts.participant.key();

    // Validate participant is in the battle
    require!(
        participant == battle.challenger || participant == battle.defender,
        BattleError::UnauthorizedParticipant
    );

    let battle_entry_name = format!("{}{}", BATTLE_NAME, battle.battle_id);
    
    let signer_seeds: &[&[&[u8]]] = &[&[
        b"battle_collection".as_ref(),
        &[ctx.bumps.collection_mint],
    ]];

    // Mint NFT
    mint_to(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            MintTo {
                mint: ctx.accounts.entry_mint.to_account_info(),
                to: ctx.accounts.destination.to_account_info(),
                authority: ctx.accounts.collection_mint.to_account_info(),
            },
            signer_seeds,
        ),
        1,
    )?;

    // Create metadata
    create_metadata_accounts_v3(
        CpiContext::new_with_signer(
            ctx.accounts.token_metadata_program.to_account_info(),
            CreateMetadataAccountsV3 {
                metadata: ctx.accounts.metadata.to_account_info(),
                mint: ctx.accounts.entry_mint.to_account_info(),
                mint_authority: ctx.accounts.collection_mint.to_account_info(),
                update_authority: ctx.accounts.collection_mint.to_account_info(),
                payer: ctx.accounts.participant.to_account_info(),
                system_program: ctx.accounts.system_program.to_account_info(),
                rent: ctx.accounts.rent.to_account_info(),
            },
            &signer_seeds,
        ),
        DataV2 {
            name: battle_entry_name,
            symbol: BATTLE_SYMBOL.to_string(),
            uri: battle.challenge_data.twitter_challenge_url.clone(),
            seller_fee_basis_points: 0,
            creators: None,
            collection: None,
            uses: None,
        },
        true,
        true,
        None,
    )?;

    // Create master edition
    create_master_edition_v3(
        CpiContext::new_with_signer(
            ctx.accounts.token_metadata_program.to_account_info(),
            CreateMasterEditionV3 {
                payer: ctx.accounts.participant.to_account_info(),
                mint: ctx.accounts.entry_mint.to_account_info(),
                edition: ctx.accounts.master_edition.to_account_info(),
                mint_authority: ctx.accounts.collection_mint.to_account_info(),
                update_authority: ctx.accounts.collection_mint.to_account_info(),
                metadata: ctx.accounts.metadata.to_account_info(),
                token_program: ctx.accounts.token_program.to_account_info(),
                system_program: ctx.accounts.system_program.to_account_info(),
                rent: ctx.accounts.rent.to_account_info(),
            },
            &signer_seeds,
        ),
        Some(0),
    )?;

    // Set as collection item
    set_and_verify_sized_collection_item(
        CpiContext::new_with_signer(
            ctx.accounts.token_metadata_program.to_account_info(),
            SetAndVerifySizedCollectionItem {
                metadata: ctx.accounts.metadata.to_account_info(),
                collection_authority: ctx.accounts.collection_mint.to_account_info(),
                payer: ctx.accounts.participant.to_account_info(),
                update_authority: ctx.accounts.collection_mint.to_account_info(),
                collection_mint: ctx.accounts.collection_mint.to_account_info(),
                collection_metadata: ctx.accounts.collection_metadata.to_account_info(),
                collection_master_edition: ctx.accounts.collection_master_edition.to_account_info(),
            },
            &signer_seeds,
        ),
        None,
    )?;

    emit!(BattleEntryNFTMinted {
        battle_id: battle.battle_id,
        participant: participant,
        mint: ctx.accounts.entry_mint.key(),
    });

    Ok(())
}

/// Emergency battle cancellation (only before battle starts)
pub fn cancel_battle_emergency(ctx: Context<CancelBattleEmergency>) -> Result<()> {
    let battle = &mut ctx.accounts.battle;
    let battle_config = &ctx.accounts.battle_config;

    // Only authority can cancel
    require!(ctx.accounts.authority.key() == battle_config.authority, BattleError::UnauthorizedCancellation);
    
    // Can only cancel before battle starts
    require!(
        battle.status == BattleStatus::PendingAcceptance || battle.status == BattleStatus::Matched,
        BattleError::CannotCancelActiveBattle
    );

    // Refund stakes
    let refund_amount = if battle.status == BattleStatus::Matched {
        battle.stake_amount * 2 // Refund both participants
    } else {
        battle.stake_amount // Refund only challenger
    };

    // Refund challenger
    **battle.to_account_info().try_borrow_mut_lamports()? -= battle.stake_amount;
    **ctx.accounts.challenger_refund.try_borrow_mut_lamports()? += battle.stake_amount;

    // Refund defender if they joined
    if battle.status == BattleStatus::Matched {
        **battle.to_account_info().try_borrow_mut_lamports()? -= battle.stake_amount;
        **ctx.accounts.defender_refund.try_borrow_mut_lamports()? += battle.stake_amount;
    }

    battle.status = BattleStatus::Cancelled;

    emit!(BattleCancelled {
        battle_id: battle.battle_id,
        refund_amount: refund_amount,
    });

    Ok(())
}

/// Query battles by SIC category for discovery
pub fn get_battles_by_category(
    ctx: Context<GetBattlesByCategory>,
    category: BattleCategoryType,
    difficulty_tier: Option<DifficultyTier>,
) -> Result<Vec<u64>> {
    // In a real implementation, this would use a program-derived address
    // or indexing system to efficiently query battles by category
    // For now, return battle IDs that match the criteria
    
    let battle_config = &ctx.accounts.battle_config;
    let mut matching_battles = Vec::new();
    
    // This is a simplified approach - in production you'd want proper indexing
    for battle_id in 0..battle_config.battle_count {
        // In real implementation, load each battle and check category
        // For demonstration, we'll just return some sample IDs
        if battle_id % 3 == 0 { // Sample logic
            matching_battles.push(battle_id);
        }
        
        if matching_battles.len() >= 20 { // Limit results
            break;
        }
    }
    
    emit!(BattleCategoryQueried {
        category: category,
        difficulty_tier: difficulty_tier,
        result_count: matching_battles.len(),
    });
    
    Ok(matching_battles)
}

/// Update battle categorization (admin only)
pub fn update_battle_categorization(
    ctx: Context<UpdateBattleCategorization>,
    battle_id: u64,
    new_hashtags: Vec<String>,
) -> Result<()> {
    let battle = &mut ctx.accounts.battle;
    let battle_config = &ctx.accounts.battle_config;
    
    // Only authority can update categorization
    require!(ctx.accounts.authority.key() == battle_config.authority, BattleError::UnauthorizedFinalization);
    
    // Battle must not be completed
    require!(battle.status != BattleStatus::Completed, BattleError::InvalidBattleState);
    
    // Re-categorize with new hashtags
    let translator = HashtagSICTranslator::new();
    let new_description = translator.translate_hashtags_to_description(&new_hashtags);
    
    battle.standardized_description = new_description;
    
    emit!(BattleCategorization {
        battle_id: battle_id,
        new_sic_code: battle.standardized_description.primary_sic_code.clone(),
        new_category: battle.standardized_description.battle_category,
        new_difficulty: battle.standardized_description.difficulty_tier,
    });
    
    Ok(())
}