
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    self, Mint, TokenAccount,
    TokenInterface, TransferChecked
};
use crate::etc::{PithyQuip,
    is_stablecoin_pyth_account};
use solana_program::keccak::hashv;


fn is_approved_mint(mint: &Pubkey, registered_mints: &[Pubkey]) -> bool {
    registered_mints.contains(mint) || *mint == USD_STAR
}

/// Transfer from multiple vaults using pro-rata distribution.
///
/// Distributes withdrawal proportionally across all vaults with balance.
/// If total available < requested, transfers what's available.
///
/// # Arguments
/// * `primary_vault` - Main vault account (from context)
/// * `primary_mint` - Main mint account (from context)
/// * `primary_user_ata` - User's ATA for primary mint (from context)
/// * `primary_vault_bump` - PDA bump for primary vault
/// * `remaining_accounts` - Additional [mint, vault, user_ata] triplets
/// * `token_program` - SPL Token program
/// * `program_id` - This program's ID (for PDA derivation)
/// * `registered_mints` - Slice of valid basket mints for validation
/// * `requested_amount` - Amount user wants to withdraw
///
/// # Returns
/// Actual amount transferred (may be less than requested)
///
/// # remaining_accounts Layout
/// ```text
/// [alt_mint_0, alt_vault_0, alt_user_ata_0, alt_mint_1, alt_vault_1, alt_user_ata_1, ...]
/// ```
pub fn transfer_from_vaults<'info>(
    primary_vault: &InterfaceAccount<'info, TokenAccount>,
    primary_mint: &InterfaceAccount<'info, Mint>,
    primary_user_ata: &InterfaceAccount<'info, TokenAccount>,
    primary_vault_bump: u8,
    remaining_accounts: &[AccountInfo<'info>],
    token_program: &Interface<'info, TokenInterface>,
    program_id: &Pubkey, registered_mints: &[Pubkey],
    requested_amount: u64) -> Result<u64> {

    // =========================================================================
    // PHASE 1: Collect all vault balances for pro-rata calculation
    // =========================================================================
    struct VaultInfo {
        is_primary: bool,
        idx: usize,         // index into remaining_accounts (ignored for primary)
        balance: u64,
        decimals: u8,
        bump: u8,
    }

    let mut vaults: Vec<VaultInfo> = Vec::new();
    let mut total_available = 0u64;

    // Add primary vault
    let primary_balance = primary_vault.amount;
    if primary_balance > 0 {
        vaults.push(VaultInfo {
            is_primary: true,
            idx: 0,
            balance: primary_balance,
            decimals: primary_mint.decimals,
            bump: primary_vault_bump,
        });
        total_available = total_available.saturating_add(primary_balance);
    }

    // Add alternate vaults from remaining_accounts
    let mut idx = 0;
    while idx + 2 < remaining_accounts.len() {
        let alt_mint_info = &remaining_accounts[idx];
        let alt_vault_info = &remaining_accounts[idx + 1];

        // Validate approved mint (basket or USD*)
        if !is_approved_mint(alt_mint_info.key, registered_mints) {
            idx += 3;
            continue;
        }

        // Validate vault PDA
        let (expected_vault, vault_bump) = Pubkey::find_program_address(
            &[b"vault", alt_mint_info.key.as_ref()], program_id
        );
        if alt_vault_info.key() != expected_vault {
            idx += 3;
            continue;
        }

        // Read balance (TokenAccount.amount at offset 64, 8 bytes)
        let alt_vault_data = alt_vault_info.try_borrow_data()?;
        if alt_vault_data.len() < 72 {
            drop(alt_vault_data);
            idx += 3;
            continue;
        }
        let vault_balance = u64::from_le_bytes(
            alt_vault_data[64..72].try_into().unwrap()
        );
        drop(alt_vault_data);

        if vault_balance == 0 {
            idx += 3;
            continue;
        }

        // Read mint decimals (Mint.decimals at offset 44, 1 byte)
        let alt_mint_data = alt_mint_info.try_borrow_data()?;
        let decimals = if alt_mint_data.len() > 44 {
            alt_mint_data[44]
        } else {
            6 // Default to 6 decimals
        };
        drop(alt_mint_data);

        vaults.push(VaultInfo {
            is_primary: false,
            idx,
            balance: vault_balance,
            decimals,
            bump: vault_bump,
        });
        total_available = total_available.saturating_add(vault_balance);
        idx += 3;
    }

    if total_available == 0 { return Ok(0); }

    // =========================================================================
    // PHASE 2: Pro-rata distribution across all vaults
    // =========================================================================
    let to_transfer = requested_amount.min(total_available);
    let mut total_transferred = 0u64;
    let mut remaining = to_transfer;
    let num_vaults = vaults.len();

    for (i, vault) in vaults.iter().enumerate() {
        if remaining == 0 { break; }

        // Last vault gets remainder to avoid dust from rounding
        let share = if i == num_vaults - 1 {
            remaining
        } else {
            // Pro-rata: (balance / total_available) * to_transfer
            ((vault.balance as u128 * to_transfer as u128) / total_available as u128) as u64
        };

        let take = share.min(vault.balance).min(remaining);
        if take == 0 { continue; }

        if vault.is_primary {
            // Transfer from primary vault
            let mint_key = primary_mint.key();
            let signer_seeds: &[&[&[u8]]] = &[
                &[b"vault", mint_key.as_ref(), &[vault.bump]],
            ];
            let cpi_ctx = CpiContext::new_with_signer(
                token_program.to_account_info(),
                TransferChecked {
                    from: primary_vault.to_account_info(),
                    mint: primary_mint.to_account_info(),
                    to: primary_user_ata.to_account_info(),
                    authority: primary_vault.to_account_info(),
                },
                signer_seeds,
            );
            token_interface::transfer_checked(cpi_ctx, take, vault.decimals)?;
        } else {
            // Transfer from alternate vault
            let alt_mint_info = &remaining_accounts[vault.idx];
            let alt_vault_info = &remaining_accounts[vault.idx + 1];
            let alt_user_ata_info = &remaining_accounts[vault.idx + 2];

            let signer_seeds: &[&[&[u8]]] = &[
                &[b"vault", alt_mint_info.key.as_ref(), &[vault.bump]],
            ];
            let cpi_ctx = CpiContext::new_with_signer(
                token_program.to_account_info(),
                TransferChecked {
                    from: alt_vault_info.clone(),
                    mint: alt_mint_info.clone(),
                    to: alt_user_ata_info.clone(),
                    authority: alt_vault_info.clone(),
                },
                signer_seeds,
            );
            token_interface::transfer_checked(cpi_ctx, take, vault.decimals)?;
        }

        total_transferred = total_transferred.saturating_add(take);
        remaining = remaining.saturating_sub(take);
    }

    Ok(total_transferred)
}

pub const USD_STAR: Pubkey = pubkey!("BenJy1n3WTx9mTjEvy63e8Q1j4RqUc6E4VBMz3ir4Wo6");
// Etymology: name is believed to come from Latin word perennis
// Meaning: perennis translates to "everlasting" or "perennial"
// Possible Application: it could have described a person with
// lasting qualities, involved with nature, gardener or farmer

#[derive(AnchorSerialize,
AnchorDeserialize, Clone)]
pub struct Side {
    pub title: String,
    pub address: Option<Pubkey>,
    // Optional beneficiary (required for fee split)
}

#[derive(AnchorSerialize,
AnchorDeserialize, Clone)]
pub struct OrderParams {
    pub side: u8,
    pub capital: u64,
    pub auto_rollover: bool,
    // ^ if true, re-bet payout on
    // same side after resolution
    // (only if it wasn't a loss)
    pub side_title: Option<String>,
    pub commitment_hash: [u8; 32],
    pub eth_signer: Option<[u8; 20]>,
    pub reveal_delegate: Option<Pubkey>,
    pub side_beneficiary: Option<Pubkey>,
    pub max_deviation_bps: Option<u64>,
    // Max allowed spot/TWAP
    // deviation (300 = 3%)
}

#[derive(AnchorSerialize,
AnchorDeserialize, Clone)]
pub struct RevealEntry {
    pub confidence: u64,
    pub salt: [u8; 32],
}

/// Market Account - Contains market metadata and aggregate statistics
///
/// Position data is stored in SEPARATE Position PDAs!
/// Accuracy data is stored in SEPARATE AccuracyBuckets PDA!
///
/// PDA Seeds: ["market", market_id (6 bytes LE)]
///
#[account]
pub struct Market {
    pub market_id: u64,
    pub creator: Pubkey,
    pub creator_bond: u64,

    pub question: String,
    pub num_sides: u8,
    pub sides: Vec<Side>,

    pub num_winners: u8,
    pub start_time: i64,
    pub resolution_time: i64,

    pub resolution_requester: Option<Pubkey>,

    // LMSR parameters
    pub liquidity: u64,
    pub tokens_sold_per_side: Vec<u64>,
    pub positions_processed: u64,

    // Capital tracking
    pub total_capital: u64,
    pub total_capital_per_side: Vec<u64>,
    pub fees_collected: u64,

    pub minimum_proceeds: u64,

    // Jury settings
    pub requires_unanimous: bool,
    pub resolve_whenever: bool,
    pub requires_app_signature: bool,

    // Resolution state machine
    pub resolution_requested: bool,
    pub resolution_requested_time: Option<i64>,
    pub resolution_received: bool,
    pub resolution_finalized: i64,

    // Resolution outcome
    pub winning_sides: Vec<u8>,
    pub winning_splits: Vec<u64>,
    pub force_majeure: bool,

    pub side_proposal_cost: u64, // if zero then there is no ability to propose sides
    pub min_sides_for_resolution: u8, // this is irrelevant if side_proposal_cost is 0
    pub max_sides: u8, // this is irrelevant if side_proposal_cost is 0

    pub confidence_sum_per_side: Vec<u128>,
    pub allows_extensions: bool,
    pub extensions_count: u8, // Track number of extensions granted
    pub allows_rollovers: bool,
    pub appeal_cost: u64,

    pub positions_revealed: u64,
    pub positions_total: u64,

    pub total_winner_weight_revealed: u128,
    pub total_loser_weight_revealed: u128,
    pub total_winner_capital_revealed: u64,
    pub total_loser_capital_revealed: u64,

    pub weights_complete: bool,
    pub payouts_complete: bool,

    pub creator_fee_bps: u16,
    pub resolution_fee_pool: u64,

    pub time_decay_lambda: u64,

    // TWAP accumulator fields for manipulation resistance
    pub price_cumulative_per_side: Vec<u128>,  // Cumulative price * time
    pub price_checkpoint_per_side: Vec<u128>,  // Checkpoint cumulative for TWAP lookback
    pub last_price_update: i64,                 // Last update timestamp
    pub checkpoint_timestamp: i64,              // When checkpoint was taken

    pub bump: u8,
}

impl Market {
    pub const SPACE: usize = 10240;
    pub fn get_state(&self, current_time: i64) -> MarketState {
        if self.force_majeure {
            return MarketState::Cancelled;
        }
        if self.resolution_finalized > 0 {
            if self.payouts_complete {
                return MarketState::Finalized;
            }
            if self.weights_complete {
                return MarketState::PushingPayouts;
            }
            return MarketState::CalculatingWeights;
        }
        if self.resolution_received {
            return MarketState::RevealPhase;
        }
        if self.resolution_requested {
            return MarketState::AwaitingRuling;
        }
        if self.resolution_time != 0 && current_time >= self.resolution_time {
            return MarketState::AwaitingResolutionRequest;
        }
        MarketState::Trading
    }
    pub fn check_minimum_proceeds(&self) -> bool {
        if self.minimum_proceeds == 0 { return true; }
        self.total_capital >= self.minimum_proceeds
    }
    pub fn is_depeg_market(&self) -> bool {
        self.num_sides == 2
            && self.resolve_whenever
            && self.sides.get(0)
                .and_then(|s| s.address.as_ref())
                .map(is_stablecoin_pyth_account)
                .unwrap_or(false)
    }
}

impl anchor_lang::Key for Market {
    fn key(&self) -> Pubkey {
        let (pda, _) = Pubkey::find_program_address(
            &[b"market", &self.market_id.to_le_bytes()[..6]],
            &crate::ID,
        );
        pda
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct CreateMarketParams {
    pub question: String,
    pub sides: Vec<Side>,
    pub resolution_time: i64,
    pub num_winners: u8,
    pub initial_liquidity: u64,
    pub minimum_proceeds: u64,
    pub requires_unanimous: bool,
    pub resolve_whenever: bool,
    pub requires_app_signature: bool,
    pub creator_fee_bps: u16,
    pub winning_splits: Vec<u64>,
    pub side_proposal_cost: u64,
    pub min_sides_for_resolution: u8,
    pub max_sides: u8,
    pub allows_extensions: bool,
    pub allows_rollovers: bool,
    pub appeal_cost: u64,
}

#[account]
pub struct AccuracyBuckets {
    pub market: Pubkey,
    pub buckets: Vec<u64>,
    pub bump: u8,
}

impl AccuracyBuckets {
    pub const NUM_BUCKETS: usize = 100;
    pub const SPACE: usize = 8 + 32 + 4 + (8 * Self::NUM_BUCKETS) + 1;

    pub fn add_position(&mut self, accuracy: u64) -> Result<()> {
        let bucket_idx = ((accuracy as usize)
            .saturating_mul(Self::NUM_BUCKETS) / 10_001)
            .min(Self::NUM_BUCKETS - 1);
        if bucket_idx < self.buckets.len() {
            self.buckets[bucket_idx] = self.buckets[bucket_idx].saturating_add(1);
        }
        Ok(())
    }

    pub fn calculate_percentile(&self, accuracy: u64, total_positions: u64) -> u64 {
        if total_positions == 0 { return 5000; }

        let bucket_idx = ((accuracy as usize)
            .saturating_mul(Self::NUM_BUCKETS) / 10_001)
            .min(Self::NUM_BUCKETS - 1);

        let mut positions_below = 0u64;
        for i in 0..bucket_idx {
            if i < self.buckets.len() {
                positions_below = positions_below.saturating_add(self.buckets[i]);
            }
        }
        if bucket_idx < self.buckets.len() {
            positions_below = positions_below.saturating_add(self.buckets[bucket_idx] / 2);
        }
        ((positions_below as u128)
            .saturating_mul(10_000) / (total_positions as u128))
            .min(10_000) as u64
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MarketState {
    Trading,
    AwaitingResolutionRequest,
    AwaitingRuling,
    RevealPhase,
    CalculatingWeights,
    PushingPayouts,
    Finalized,
    Cancelled,
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct PositionEntry {
    pub capital: u64,
    pub tokens: u64,
    pub price_at_entry: u64,
    pub timestamp: i64,
    pub capital_seconds: u128,
    pub last_updated: i64,
    pub commitment_hash: [u8; 32],
    pub confidence: Option<u64>,
}

#[account]
pub struct Position {
    pub market: Pubkey,
    pub user: Pubkey,
    pub side: u8,
    pub total_capital: u64,
    pub total_tokens: u64,
    pub total_capital_seconds: u128,
    pub entries: Vec<PositionEntry>,
    pub auto_rollover: bool,
    pub commitment_hash: [u8; 32],
    pub revealed: bool,
    pub revealed_confidence: u64,
    pub accuracy_percentile: u64,
    pub weight: u128,
    pub payout: u64,
    pub payout_pushed: bool,
    pub eth_signer: Option<[u8; 20]>,
    pub reveal_delegate: Option<Pubkey>,
    pub bump: u8,
}


impl Position {
    pub const MAX_ENTRIES: usize = 20;
    // Entry: 8 + 8 + 8 + 8 + 16 + 8 + 32 + 9 = 97 bytes
    pub const SPACE: usize = 8 + 32 + 32 + 1 + 8 + 8 + 16
        + 4 + (Self::MAX_ENTRIES * 97) + 1 + 32 + 1 + 8
        + 8 + 16 + 8 + 1 + 1 + 20 + 1 + 32 + 1;
}

pub fn hash_commitment_u64(confidence: u64, salt: [u8; 32]) -> [u8; 32] {
    hashv(&[&confidence.to_le_bytes(), &salt]).to_bytes()
}

/*
    Goal: Aggregate probabilistic beliefs into prices
    Method: Maximum entropy + cost function

    C(q) = b·log(Σ exp(qᵢ/b))

    Prices: pᵢ = exp(qᵢ/b) / Z  where Z = Σexp(qⱼ/b)

    This IS a Boltzmann distribution:
    - qᵢ = shares (like energy states)
    - b = liquidity parameter (like temperature kT)
    - pᵢ = probability (price) of outcome i
    - Z = partition function (we don't need this)

    Properties:
    - Σ p_i = 1.0 (prices sum to 1)
    - 0 < p_i < 1 (valid probabilities)
    - ∂p_i/∂q_i = p_i(1-p_i)/b (price sensitivity)
*/
pub fn calculate_lmsr_price(outcome_index: usize,
    shares_per_outcome: &[u64], liquidity: f64) -> Result<f64> {
    require!(outcome_index < shares_per_outcome.len(), PithyQuip::InvalidSide);
    require!(liquidity > 0.0, PithyQuip::InvalidLiquidity);
    let ratios: Vec<f64> = shares_per_outcome.iter()
        .map(|&s| (s as f64) / liquidity).collect();
    let max_ratio = ratios.iter().cloned().fold(
                    f64::NEG_INFINITY, f64::max);

    let exp_values: Vec<f64> = ratios.iter()
        .map(|&r| (r - max_ratio).exp())
        .collect();

    let sum: f64 = exp_values.iter().sum();
    require!(sum.is_finite() && sum > 0.0,
    PithyQuip::PriceCalculationOverflow);

    let price = exp_values[outcome_index] / sum;
    require!(price >= 0.0 && price <= 1.0,
                PithyQuip::InvalidPrice);
    Ok(price)
}

/// Theory:
/// - Information arrival rate decreases over time: I(t) = I₀ × exp(-λt)
/// - Early traders have information advantage
/// - Late traders may have better information but less time to profit
/// - Optimal λ balances: early mover advantage vs. late information value
///
/// Derivation from first principles:
/// 1. Define information value decay: V(t) = V₀ × exp(-λt)
/// 2. Total expected information: ∫₀¹ V(t) dt = V₀ × (1 - exp(-λ)) / λ
/// 3. Early trader advantage: A = V(0) / V(1) = exp(λ)
/// 4. Want moderate advantage: 2 ≤ A ≤ 10 (early traders get 2-10x late traders)
///
/// 5. For binary markets:
///    - Information arrives quickly → high λ (≈ 5-10)
///    - Early traders should dominate
///
/// 6. For complex markets (many outcomes):
///    - Information arrives slowly → low λ (≈ 1-3)
///    - Late analysis may be more valuable
///
/// 7. Duration matters:
///    - Short markets: High λ (information decays fast)
///    - Long markets: Low λ (information accumulates)
///
/// Optimal formula derived from maximizing market efficiency:
///    λ* = λ_base × √(num_outcomes) / ln(1 + duration_hours)
///
/// Where:
/// - λ_base depends on market type (prediction, futures, etc.)
/// - √(num_outcomes) captures complexity
/// - ln(1 + duration) captures diminishing returns of time
///
pub fn calculate_adaptive_lambda(duration_seconds: i64, num_outcomes: usize) -> f64 {
    let duration_hours = ((duration_seconds as f64) / 3600.0).max(0.1).min(8760.0);

    const LAMBDA_BASE: f64 = 5.0;
    const LAMBDA_MIN: f64 = 0.5;
    const LAMBDA_MAX: f64 = 10.0;

    let complexity = (num_outcomes as f64).sqrt();
    let complexity_adjustment = 1.0 / (1.0 + (complexity - 2.0) / 5.0);
    let duration_factor = if duration_hours < 1.0 {
        (2.0 / duration_hours).min(4.0)
    } else if duration_hours < 24.0 {
        3.0 / (1.0 + duration_hours.ln()).max(0.5)
    } else if duration_hours < 168.0 {
        2.0 / (1.0 + duration_hours.ln()).max(0.5)
    } else {
        1.5 / (1.0 + duration_hours.ln()).max(0.5)
    };
    let liquidity_premium = if duration_hours < 12.0 { 1.5 } else { 1.0 };
    let lambda_star = LAMBDA_BASE * complexity_adjustment * duration_factor * liquidity_premium;
    let lambda_clamped = lambda_star.max(LAMBDA_MIN).min(LAMBDA_MAX);

    if lambda_clamped.exp() > 50_000.0 {
        return LAMBDA_MAX.min(9.0);
    }
    lambda_clamped
}


/// Theory:
/// - LMSR cost function: C(q) = b × ln(Σ exp(q_i / b))
/// - Market maker subsidizes early trades (creates initial liquidity)
/// - As more traders arrive, market becomes more efficient
/// - Optimal b balances: liquidity provision vs. subsidy cost
///
/// Derivation from first principles:
/// 1. Expected volume V ∝ √(duration) × num_outcomes
/// 2. Price volatility σ ∝ 1/√(num_positions_expected)
/// 3. Optimal liquidity b* minimizes: subsidy_cost + inefficiency_cost
///
///    subsidy_cost(b) = b × ln(n) where n = num_outcomes
///    inefficiency_cost(b) = k × σ² × V / b where k is constant
///
/// 4. Taking derivative and setting to 0:
///    d/db [b × ln(n) + k × σ² × V / b] = 0
///    ln(n) - k × σ² × V / b² = 0
///
/// 5. Solving for b*:
///    b* = √(k × σ² × V / ln(n))
///
/// 6. Substituting empirical values and simplifying:
///    b* = α × √(duration_days) × ⁴√(num_outcomes) × √(expected_volume)
///
/// Where:
/// - α is calibration constant (≈ 1000 from empirical data)
/// - duration_days = market lifetime in days
/// - num_outcomes = number of possible outcomes
/// - expected_volume = E[total capital] ≈ β × duration_days × num_outcomes
///
pub fn calculate_adaptive_liquidity(market: &Market, current_timestamp: i64) -> u64 {
    let initial_liquidity = market.liquidity as f64;
    let age_seconds = current_timestamp.saturating_sub(market.start_time);
    let age_days = ((age_seconds as f64) / 86400.0).max(0.01);

    let time_factor = (1.0 + age_days.ln()).max(1.0);

    const BETA: f64 = 500.0;
    let expected_capital = BETA * (market.num_sides as f64);
    let expected_ctp = expected_capital * age_days;

    let actual_ctp = ((market.total_capital as f64) * age_days / 2.0).max(expected_ctp * 0.1);
    let ctp_ratio = (actual_ctp / expected_ctp).max(0.5).min(10.0);
    let volume_factor = ctp_ratio.powf(0.25);

    let n = market.num_sides as f64;
    let complexity_factor = n.powf(0.25);
    let entropy_factor = 1.0 + (n.ln() / 10.0);

    let liquidity = initial_liquidity * time_factor * volume_factor * complexity_factor * entropy_factor;

    liquidity.max(initial_liquidity).min(initial_liquidity * 10.0) as u64
}

/// Power-law decay: decay = participation^(lambda/100)
/// Similar shape to exponential but uses cheaper pow approximation
pub fn calculate_time_decay(position_duration: i64,
    market_duration: i64, lambda: u64) -> u64 {
    if market_duration <= 0 { return 10_000; }
    let participation = ((position_duration as u128)
        .saturating_mul(10_000) / (market_duration as u128))
        .min(10_000) as u64;

    if lambda <= 100 { return participation; }

    if lambda <= 200 {
        let t = lambda - 100;
        let linear = participation as u128;
        let quad = (participation as u128)
            .saturating_mul(participation as u128) / 10_000;
        return ((linear.saturating_mul((100 - t) as u128)
            .saturating_add(quad.saturating_mul(t as u128))) / 100) as u64;
    }

    let quad = ((participation as u128)
        .saturating_mul(participation as u128) / 10_000) as u64;
    let cubic = ((quad as u128)
        .saturating_mul(participation as u128) / 10_000) as u64;

    cubic.max(1000)
}

// =============================================================================
// RESOLUTION FEE CALCULATION
// =============================================================================

/// Minimum jury compensation pool ($1,200 for 12 jurors × $100 minimum)
/// This ensures juror incentive to be honest is always > 20% of $500
pub const MIN_JURY_POOL: u64 = 1_200_000_000; // 6 decimals

/// Maximum resolution fee to prevent excessive fees on huge markets
pub const MAX_RESOLUTION_FEE: u64 = 25_000_000_000; // $25,000 cap

/// Calculate resolution fee rate based on market size.
/// Returns fee rate in bps.
///
/// Sliding scale: larger markets pay lower percentage.
/// - $10k market: 12% (ensures $1,200 minimum for jury)
/// - $50k market: 3%
/// - $100k market: 2%
/// - $500k market: 1.5%
/// - $1M+ market: 1%
///
/// The minimum_rate ensures we always collect at least MIN_JURY_POOL.
/// The scale_rate provides a reasonable fee even for larger markets.
pub fn calculate_resolution_fee_rate(total_capital: u64) -> u64 {
    use std::cmp::max;
    if total_capital == 0 { return 10000; } // 100% if no capital (edge case)

    // Minimum rate needed to hit MIN_JURY_POOL
    let minimum_rate = ((MIN_JURY_POOL as u128) * 10_000 / (total_capital as u128)) as u64;

    // Sliding scale based on market size (6 decimals: 1_000_000 = $1)
    let scale_rate = if total_capital < 50_000_000_000 { 300 }       // < $50k: 3%
        else if total_capital < 100_000_000_000 { 200 }               // < $100k: 2%
        else if total_capital < 500_000_000_000 { 150 }               // < $500k: 1.5%
        else { 100 };                                                  // $500k+: 1%

    max(minimum_rate, scale_rate)
}

/// Calculate actual resolution fee amount.
/// Capped at MAX_RESOLUTION_FEE to prevent excessive fees on huge markets.
///
/// Examples:
/// - $10k market → $1,200 (12%, hits minimum)
/// - $50k market → $1,500 (3%)
/// - $100k market → $2,000 (2%)
/// - $500k market → $7,500 (1.5%)
/// - $1M market → $10,000 (1%)
/// - $2.5M+ market → $25,000 (capped)
pub fn calculate_resolution_fee(total_capital: u64) -> u64 {
    use std::cmp::{min, max};
    let rate = calculate_resolution_fee_rate(total_capital);
    let fee = ((total_capital as u128) * (rate as u128) / 10_000) as u64;
    min(MAX_RESOLUTION_FEE, max(MIN_JURY_POOL, fee))
}
