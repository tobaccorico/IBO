
use anchor_lang::prelude::*;
use solana_program::keccak::hashv;
use crate::etc::{ PithyQuip,
    DEPEG_THRESHOLD, fetch_price,
    STABLECOINS_ACCOUNT_MAP };

use crate::state::{Market, Position, MIN_JURY_POOL};
pub const OAPP_STORE_SEED: &[u8] = b"Store";
pub const CHAIN_SEED: &[u8] = b"Chain";
pub const LZ_RECEIVE_TYPES_SEED: &[u8] = b"LzReceiveTypes";
pub const PEER_SEED: &[u8] = b"Peer";

pub const ENFORCED_OPTIONS_SEND_MAX_LEN: usize = 512;
pub const ENFORCED_OPTIONS_SEND_AND_CALL_MAX_LEN: usize = 1024;

pub const RESOLUTION_REQUEST: u8 = 5;
pub const FINAL_RULING: u8 = 6;
pub const JURY_COMPENSATION: u8 = 7;
pub const EXTENSION_MARKER: u8 = 101;

#[account]
pub struct OAppStore {
    pub admin: Pubkey, pub bump: u8,
    pub endpoint_program: Pubkey,
    pub registered_mints: Vec<Pubkey>,
}

impl OAppStore {
    pub const MAX_CHAINS: usize = 10;
    pub const SIZE: usize = 8 + 32 + 1 + 32 + 4 + (32 * Self::MAX_CHAINS);
    pub fn is_basket_mint(&self, mint: &Pubkey) -> bool {
        self.registered_mints.contains(mint)
    }
}

#[account]
pub struct ChainConfig {
    pub eid: u32, pub mint: Pubkey,
    pub peer_address: [u8; 32],
    pub enforced_options: EnforcedOptions,
    pub active: bool, pub bump: u8,
}

impl ChainConfig {
    pub const SIZE: usize = 8 + 4 + 32 + 32
        + EnforcedOptions::MAX_SIZE + 1 + 1;
}

#[derive(Clone, Default,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct EnforcedOptions {
    pub send: Vec<u8>,
    pub send_and_call: Vec<u8>,
}

impl EnforcedOptions {
    pub const MAX_SIZE: usize = 4 +
    ENFORCED_OPTIONS_SEND_MAX_LEN + 4
    + ENFORCED_OPTIONS_SEND_AND_CALL_MAX_LEN;
    pub fn get_enforced_options(&self,
        composed_msg: &Option<Vec<u8>>) -> Vec<u8> {
        if composed_msg.is_none() {
            self.send.clone()
        } else {
            self.send_and_call.clone()
        }
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct FinalRuling {
    pub market_id: u64,
    pub winning_sides: Vec<u8>,
    pub slashing_sides: Vec<u8>,
    pub slashing_addresses: Vec<Pubkey>,
}

impl FinalRuling {
    pub fn new(market_id: u64, winning_sides: Vec<u8>,
               slashing_addresses: Vec<Pubkey>, slashing_sides: Vec<u8>) -> Result<Self> {
        require!(slashing_addresses.len() <= 100, PithyQuip::TooManySlashingAddresses);
        require!(slashing_addresses.len() == slashing_sides.len(), PithyQuip::InvalidMessageFormat);
        Ok(Self { market_id, winning_sides, slashing_addresses, slashing_sides })
    }

    pub fn decode(data: &[u8]) -> Result<Self> {
        require!(data.len() >= 10, PithyQuip::InvalidMessageFormat);
        require!(data[0] == FINAL_RULING, PithyQuip::InvalidMessageType);

        let mut offset = 1;
        let market_id = u64::from_le_bytes(data[offset..offset+8].try_into().unwrap());
        offset += 8;

        let num_sides = data[offset] as usize; offset += 1;
        let mut winning_sides = Vec::with_capacity(num_sides);
        for _ in 0..num_sides {
            require!(offset < data.len(), PithyQuip::InvalidMessageFormat);
            winning_sides.push(data[offset]);
            offset += 1;
        }
        require!(offset < data.len(), PithyQuip::InvalidMessageFormat);
        let num_slashings = data[offset] as usize; offset += 1;

        let mut slashing_addresses = Vec::with_capacity(num_slashings);
        let mut slashing_sides = Vec::with_capacity(num_slashings);
        for _ in 0..num_slashings {
            require!(offset + 33 <= data.len(), PithyQuip::InvalidMessageFormat);
            let addr_bytes: [u8; 32] = data[offset..offset+32].try_into().unwrap();
            slashing_addresses.push(Pubkey::new_from_array(addr_bytes));

            offset += 32;
            slashing_sides.push(data[offset]);
            offset += 1;
        }
        Ok(Self { market_id, winning_sides, slashing_addresses, slashing_sides })
    }
    pub fn is_force_majeure(&self) -> bool { self.winning_sides.is_empty() }
    pub fn is_extension(&self) -> bool { self.winning_sides.len() == 1
                                      && self.winning_sides[0] == EXTENSION_MARKER }
}

#[derive(Clone, Debug)]
pub struct ResolutionRequest {
    pub market_id: u64,
    pub num_sides: u8,
    pub num_winners: u8,
    pub merkle_root: [u8; 32],
    pub requires_unanimous: bool,
    pub requires_app_signature: bool,
    pub is_depeg_market: bool,
    pub allows_extensions: bool,
    pub appeal_cost: u64,
    pub requester: Pubkey,
}

impl ResolutionRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut message = vec![RESOLUTION_REQUEST];
        message.extend_from_slice(&self.market_id.to_le_bytes());
        message.push(self.num_sides);
        message.push(self.num_winners);
        message.extend_from_slice(&self.merkle_root);
        message.push(if self.requires_unanimous { 1 } else { 0 });
        message.push(if self.requires_app_signature { 1 } else { 0 });
        message.push(if self.is_depeg_market { 1 } else { 0 });
        message.push(if self.allows_extensions { 1 } else { 0 });
        message.extend_from_slice(&self.appeal_cost.to_le_bytes());
        message.extend_from_slice(self.requester.as_ref());
        message
    }
}

#[derive(Clone, Debug)]
pub struct DepegStats {
    pub avg_conf_peg: u64,
    pub avg_conf_depeg: u64,
    pub cap_peg: u64,
    pub cap_depeg: u64,
    pub depegged: bool,
}

impl DepegStats {
    pub fn encode(&self) -> Vec<u8> {
        let mut data = Vec::with_capacity(33);
        data.extend_from_slice(&self.avg_conf_peg.to_le_bytes());
        data.extend_from_slice(&self.avg_conf_depeg.to_le_bytes());
        data.extend_from_slice(&self.cap_peg.to_le_bytes());
        data.extend_from_slice(&self.cap_depeg.to_le_bytes());
        data.push(if self.depegged { 1 } else { 0 });
        data
    }

    pub fn from_market(market: &Market) -> Self {
        let cap_peg = market.total_capital_per_side.get(0).copied().unwrap_or(0);
        let cap_depeg = market.total_capital_per_side.get(1).copied().unwrap_or(0);

        let avg_conf_peg = if cap_peg > 0 {
            (market.confidence_sum_per_side.get(0)
            .copied().unwrap_or(0) / (cap_peg as u128)) as u64
        } else { 0 };

        let avg_conf_depeg = if cap_depeg > 0 {
            (market.confidence_sum_per_side.get(1)
            .copied().unwrap_or(0) / (cap_depeg as u128)) as u64
        } else { 0 };

        Self { avg_conf_peg,
            avg_conf_depeg,
            cap_peg, cap_depeg,
            depegged: market.winning_sides.contains(&1),
        }
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct JuryCompensation {
    pub market_id: u64,
    pub amount: u64,
}

impl JuryCompensation {
    pub fn encode(&self) -> Vec<u8> {
        let mut data = vec![JURY_COMPENSATION];
        data.extend_from_slice(&self.market_id.to_le_bytes());
        data.extend_from_slice(&self.amount.to_le_bytes());
        data
    }

    pub fn encode_with_stats(&self, stats: &DepegStats) -> Vec<u8> {
        let mut data = self.encode();
        data.extend(stats.encode());
        data
    }
}

/// Wrap a compose message in OFT format for cross-chain delivery
/// OFT message format (from OFTMsgCodec.sol):
///   [0-31]  = sendTo (bytes32) - recipient/peer address on destination
///   [32-39] = amountSD (uint64 BE) - 0 for non-token messages
///   [40+]   = composeMsg - the actual payload
///
/// Note: Standard OFT compose includes composeFrom (msg.sender) at [40:72],
/// but Basket.sol expects raw payload starting at [40] without composeFrom.
pub fn wrap_in_oft_format(compose_msg: Vec<u8>, send_to: [u8; 32]) -> Vec<u8> {
    let mut message = Vec::with_capacity(40 + compose_msg.len());
    message.extend_from_slice(&send_to);             // sendTo: bytes[0:32]
    message.extend_from_slice(&0u64.to_be_bytes());  // amountSD: bytes[32:40] (big-endian)
    message.extend(compose_msg);                     // composeMsg: bytes[40:]
    message
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct RegisterChainParams {
    pub eid: u32,
    pub mint: Pubkey,
    pub peer_address: [u8; 32],
    pub enforced_options_send: Vec<u8>,
}

#[derive(Accounts)]
#[instruction(params: RegisterChainParams)]
pub struct RegisterChain<'info> {
    #[account(mut, address = store.admin @ PithyQuip::Unauthorized)]
    pub admin: Signer<'info>,

    #[account(mut, seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    #[account(
        init,
        payer = admin,
        space = ChainConfig::SIZE,
        seeds = [CHAIN_SEED, &params.eid.to_be_bytes()],
        bump
    )]
    pub chain_config: Account<'info, ChainConfig>,

    pub system_program: Program<'info, System>,
}

pub fn register_chain_handler(ctx: Context<RegisterChain>,
    params: RegisterChainParams) -> Result<()> {
    let store = &mut ctx.accounts.store;
    let config = &mut ctx.accounts.chain_config;

    require!(!store.registered_mints.contains(&params.mint), PithyQuip::InvalidMint);
    require!(store.registered_mints.len() < OAppStore::MAX_CHAINS, PithyQuip::InvalidParameters);

    store.registered_mints.push(params.mint);
    config.eid = params.eid;
    config.mint = params.mint;
    config.peer_address = params.peer_address;
    config.enforced_options = EnforcedOptions {
        send: params.enforced_options_send,
        send_and_call: Vec::new(),
    };
    config.active = true;
    config.bump = ctx.bumps.chain_config;
    Ok(())
}

#[derive(Accounts)]
pub struct SendResolutionRequest<'info> {
    #[account(mut)]
    pub requester: Signer<'info>,

    #[account(mut, seeds = [b"market", &market.market_id.to_le_bytes()[..6]], bump = market.bump)]
    pub market: Account<'info, Market>,

    #[account(seeds = [OAPP_STORE_SEED], bump = oapp_store.bump)]
    pub oapp_store: Account<'info, OAppStore>,

    pub system_program: Program<'info, System>,
}

pub fn send_resolution_request(
    ctx: Context<SendResolutionRequest>) -> Result<()> {
    let market = &mut ctx.accounts.market; let clock = Clock::get()?;
    require!(!market.resolution_received, PithyQuip::AlreadyResolved);
    require!(!market.resolution_requested, PithyQuip::AlreadyRequested);
    require!(market.total_capital >= MIN_JURY_POOL,
                PithyQuip::RequesterPositionTooSmall);

    // =========================================================================
    // Depeg markets have Pyth at [0], so ChainConfig is at [1]
    // Normal markets have ChainConfig at [0]
    // =========================================================================
    let mut chain_config_offset = 0usize;  // Track account index offset for depeg markets
    // =========================================================================
    // DEPEG MARKET HANDLING
    // For depeg markets, remaining_accounts layout is:
    //   [0] = Pyth oracle account
    //   [1] = ChainConfig (only needed if price >= threshold)
    //   [2+] = Position accounts (for merkle tree)
    //
    // For normal markets:
    //   [0] = ChainConfig
    //   [1+] = Position accounts
    // =========================================================================
    if market.is_depeg_market() {
        let pyth_feed_key = market.sides[0].address.unwrap();
        let pyth_feed_str = pyth_feed_key.to_string();
        let ticker = STABLECOINS_ACCOUNT_MAP.entries()
            .find(|(_, &acct)| acct == pyth_feed_str)
            .map(|(ticker, _)| *ticker);

        if let Some(ticker) = ticker {
            require!(ctx.remaining_accounts.len() >= 1, PithyQuip::MissingPythAccount);
            let pyth_account = &ctx.remaining_accounts[0];
            require!(pyth_account.key() == pyth_feed_key, PithyQuip::InvalidPythFeed);

            let price = fetch_price(ticker, Some(pyth_account))?;

            if price < DEPEG_THRESHOLD {
                msg!("Depeg detected: price {} < threshold", price);
                market.winning_sides = vec![1];
                market.resolution_finalized = clock.unix_timestamp;
                market.resolution_received = true;
                market.resolution_requested = true;
                market.resolution_requester = Some(ctx.accounts.requester.key());
                market.resolution_requested_time = Some(clock.unix_timestamp);
                return Ok(());
            }
            // remaining_accounts[0] is Pyth, ChainConfig is at [1]
            chain_config_offset = 1;
        }
    }
    if !market.resolve_whenever {
        require!(clock.unix_timestamp >= market.resolution_time, PithyQuip::TooEarlyToResolve);
        if !market.check_minimum_proceeds() {
            msg!("Force majeure: minimum proceeds not met");
            market.creator_bond = 0;
            market.force_majeure = true;
            market.resolution_received = true;
            market.winning_sides = Vec::new();
            market.winning_splits = Vec::new();
            return Ok(());
        }
    }
    // Use chain_config_offset to read correct account
    require!(ctx.remaining_accounts.len() > chain_config_offset, PithyQuip::InsufficientAccounts);
    let chain_config_info = &ctx.remaining_accounts[chain_config_offset];
    let chain_data = chain_config_info.try_borrow_data()?;
    let chain_config = ChainConfig::try_deserialize(&mut chain_data.as_ref())
        .map_err(|_| PithyQuip::InvalidPeer)?;

    require!(chain_config.active, PithyQuip::InvalidPeer);
    require!(chain_config.peer_address != [0u8; 32], PithyQuip::PeerNotConfigured);

    if market.resolve_whenever {
        require!(market.check_minimum_proceeds(), PithyQuip::MinimumProceedsNotMet);
    }
    let active_sides = market.sides.len() as u8;
    require!(active_sides >= market.min_sides_for_resolution, PithyQuip::InsufficientSides);

    // Use chain_config_offset to get correct position accounts slice
    let position_accounts = if ctx.remaining_accounts.len() > chain_config_offset + 1 {
        &ctx.remaining_accounts[chain_config_offset + 1..]
    } else { &[] };
    let merkle_root = build_merkle_tree_from_market(market,
        position_accounts, &ctx.accounts.requester.key())?;

    let request = ResolutionRequest { market_id: market.market_id,
        num_sides: market.sides.len() as u8, num_winners: market.num_winners,
        merkle_root, requires_unanimous: market.requires_unanimous,
        requires_app_signature: market.requires_app_signature,
        is_depeg_market: market.is_depeg_market(),
        allows_extensions: market.allows_extensions,
        appeal_cost: market.appeal_cost,
        requester: ctx.accounts.requester.key(),
    };  market.resolution_requested = true;
    market.resolution_requested_time = Some(clock.unix_timestamp);
    market.resolution_requester = Some(ctx.accounts.requester.key());

    // Wrap in OFT format: [amountSD(8), sendTo(32), composeMsg(...)]
    let compose_msg = request.encode();
    let message = wrap_in_oft_format(compose_msg, chain_config.peer_address);
    let seeds: &[&[&[u8]]] = &[&[OAPP_STORE_SEED, &[ctx.accounts.oapp_store.bump]]];
    let options = chain_config.enforced_options.get_enforced_options(&None::<Vec<u8>>);

    // Account for depeg offset in LZ account indices
    let quote_start = chain_config_offset + 1;
    let quote_end = quote_start + 6; let send_start = quote_end;
    require!(ctx.remaining_accounts.len() >= send_start + 7,
                    PithyQuip::InsufficientAccounts);

    let quote_accounts = &ctx.remaining_accounts[quote_start..quote_end];
    let send_accounts = &ctx.remaining_accounts[send_start..];
    let quote_result = cpi_quote(
        ctx.accounts.oapp_store.endpoint_program,
        quote_accounts, QuoteParams {
            sender: ctx.accounts.oapp_store.key(),
            dst_eid: chain_config.eid,
            receiver: chain_config.peer_address,
            message: message.clone(),
            options: options.clone(),
            pay_in_lz_token: false,
        },
    )?;
    require!(ctx.accounts.requester.lamports() >= quote_result.native_fee,
                                            PithyQuip::InsufficientLZFee);
    cpi_send(
        ctx.accounts.oapp_store.endpoint_program,
        ctx.accounts.oapp_store.key(), send_accounts,
        seeds, SendParams { dst_eid: chain_config.eid,
            receiver: chain_config.peer_address,
            message, options,
            native_fee: quote_result.native_fee,
            lz_token_fee: quote_result.lz_token_fee,
        })?;
    Ok(())
}

fn build_merkle_tree_from_market(market: &Market,
    remaining_accounts: &[AccountInfo],
    requester: &Pubkey) -> Result<[u8; 32]> {
    let mut participants: Vec<(Pubkey, [u8; 20])> = Vec::new();
    let mut requester_found = false;
    let mut requester_capital = 0u64;
    for account_info in remaining_accounts {
        if account_info.owner != &crate::ID { continue; }
        let data = account_info.try_borrow_data()?;
        if let Ok(position) = Position::try_deserialize(&mut data.as_ref()) {
            if position.market == market.key() && position.total_capital > 0 {
                if let Some(eth_addr) = position.eth_signer {
                    participants.push((position.user, eth_addr));
                }
                if position.user == *requester {
                    requester_found = true;
                    requester_capital = position.total_capital;
                }
            }
        }
    } require!(requester_found,
        PithyQuip::RequesterMustHavePosition);
    // Requester must have position >= MIN_JURY_POOL to cover slashing if frivolous
    require!(requester_capital >= MIN_JURY_POOL,
        PithyQuip::RequesterPositionTooSmall);

    participants.sort_by(|a, b| a.0.cmp(&b.0));
    participants.dedup_by(|a, b| a.0 == b.0);
    let leaves: Vec<[u8; 32]> = participants.iter()
        .map(|(solana_key, eth_addr)| {
            let leaf = hashv(&[solana_key.as_ref(),
                            eth_addr]).to_bytes();
            hashv(&[&leaf]).to_bytes()
        }).collect();

    if leaves.is_empty() { return Ok([0u8; 32]); }
    let mut current_level = leaves;
    while current_level.len() > 1 {
        let mut next_level = Vec::with_capacity(
                (current_level.len() + 1) / 2);
        for chunk in current_level.chunks(2) {
            let out = if chunk.len() > 1 {
                if chunk[0] < chunk[1] {
                    hashv(&[&chunk[0], &chunk[1]]).to_bytes()
                } else {
                    hashv(&[&chunk[1], &chunk[0]]).to_bytes()
                }
            } else {
                hashv(&[&chunk[0], &chunk[0]]).to_bytes()
            };
            next_level.push(out);
        }
        current_level = next_level;
    } Ok(current_level[0])
}

/// NEW: Accounts for checking Pyth during jury process
/// This allows depeg markets to resolve via oracle even while jury is pending
#[derive(Accounts)]
pub struct CheckDepegOverride<'info> {
    #[account(mut, seeds = [b"market",
        &market.market_id.to_le_bytes()[..6]],
        bump = market.bump)]
    pub market: Account<'info, Market>,

    #[account(mut)]
    pub caller: Signer<'info>,
}

/// NEW: Check Pyth oracle during jury process for depeg markets
///
/// This function allows anyone to check the Pyth oracle for a depeg market
/// that is currently in jury resolution. If a depeg is detected (price < threshold),
/// the market is immediately resolved via oracle, overriding the jury process.
///
/// This prevents the attack where someone triggers jury when price is healthy,
/// then a real depeg occurs but cannot be captured because send_resolution_request
/// is blocked by `resolution_requested = true`.
///
/// # Arguments
/// * `ctx` - Context containing market account
/// * Pyth oracle account must be passed in remaining_accounts[0]
///
/// # Errors
/// * `NotDepegMarket` - Market is not a depeg market
/// * `NotInResolution` - Market has not entered resolution process
/// * `AlreadyResolved` - Market already has a final resolution
/// * `NoDepegDetected` - Price is >= threshold, no override applied
pub fn check_depeg_override(ctx: Context<CheckDepegOverride>) -> Result<()> {
    let market = &mut ctx.accounts.market;
    let clock = Clock::get()?;

    // Must be a depeg market
    require!(market.is_depeg_market(), PithyQuip::NotDepegMarket);

    // Must be in jury process (resolution_requested but not received)
    require!(market.resolution_requested, PithyQuip::NotInResolution);
    require!(!market.resolution_received, PithyQuip::AlreadyResolved);

    // Get Pyth feed from market config
    let pyth_feed_key = market.sides[0].address
        .ok_or(PithyQuip::InvalidMarketConfig)?;
    let pyth_feed_str = pyth_feed_key.to_string();

    let ticker = STABLECOINS_ACCOUNT_MAP.entries()
        .find(|(_, &acct)| acct == pyth_feed_str)
        .map(|(ticker, _)| *ticker)
        .ok_or(PithyQuip::InvalidStablecoinAddress)?;

    // Validate Pyth account
    require!(ctx.remaining_accounts.len() >= 1, PithyQuip::MissingPythAccount);
    let pyth_account = &ctx.remaining_accounts[0];
    require!(pyth_account.key() == pyth_feed_key, PithyQuip::InvalidPythFeed);

    // Fetch current price
    let price = fetch_price(ticker, Some(pyth_account))?;

    // Check for depeg
    if price < DEPEG_THRESHOLD {
        msg!("Depeg override detected: price {} < threshold", price);

        // Resolve market immediately via oracle
        market.winning_sides = vec![1];  // Side 1 = depeg
        market.resolution_finalized = clock.unix_timestamp;
        market.resolution_received = true;
        // Note: resolution_requested stays true, resolution_requester unchanged

        // Jury process on Ethereum will be orphaned but that's OK
        // When Solana sends jury compensation, it will include depeg stats
        // Court.sol will see market is already resolved and handle gracefully

        Ok(())
    } else {
        // No depeg detected, jury process continues
        Err(PithyQuip::NoDepegDetected.into())
    }
}

#[derive(Accounts)]
pub struct SendJuryCompensation<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Account<'info, Market>,

    #[account(seeds = [OAPP_STORE_SEED],
               bump = oapp_store.bump)]
    pub oapp_store: Account<'info, OAppStore>,

    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn send_jury_compensation(ctx: Context<SendJuryCompensation>) -> Result<()> {
    let market = &mut ctx.accounts.market;
    require!(market.resolution_finalized > 0,
            PithyQuip::ResolutionNotFinal);

    let amount = market.resolution_fee_pool;
    market.resolution_fee_pool = 0;
    let compensation = JuryCompensation {
    market_id: market.market_id, amount };
    let mut compose_msg = compensation.encode();
    let is_depeg = market.is_depeg_market();
    if is_depeg {
        compose_msg.extend(DepegStats::from_market(market).encode());
    }
    let seeds: &[&[&[u8]]] = &[&[OAPP_STORE_SEED,
                &[ctx.accounts.oapp_store.bump]]];
    if is_depeg {
        let accounts_per_send = 14;
        let num_chains = ctx.remaining_accounts.len() / accounts_per_send;
        for i in 0..num_chains { let base = i * accounts_per_send;
            let chain_config_info = &ctx.remaining_accounts[base];
            let chain_data = chain_config_info.try_borrow_data()?;
            let chain_config = match ChainConfig::try_deserialize(
                &mut chain_data.as_ref()) { Ok(c) => c,
                                    Err(_) => continue, };

            if !chain_config.active || chain_config.peer_address == [0u8; 32] { continue; }
            // Wrap in OFT format for this specific chain
            let message = wrap_in_oft_format(compose_msg.clone(), chain_config.peer_address);
            let options = chain_config.enforced_options.get_enforced_options(&None::<Vec<u8>>);
            let quote_accounts = &ctx.remaining_accounts[base + 1..base + 7];
            let send_accounts = &ctx.remaining_accounts[base + 7..base + accounts_per_send];
            let quote_result = cpi_quote(ctx.accounts.oapp_store.endpoint_program,
                quote_accounts, QuoteParams { sender: ctx.accounts.oapp_store.key(),
                    dst_eid: chain_config.eid, receiver: chain_config.peer_address,
                    message: message.clone(), options: options.clone(), pay_in_lz_token: false,
                },
            )?;
            cpi_send(ctx.accounts.oapp_store.endpoint_program,
                ctx.accounts.oapp_store.key(), send_accounts, seeds,
                SendParams { dst_eid: chain_config.eid,
                    receiver: chain_config.peer_address,
                    message, options,
                    native_fee: quote_result.native_fee,
                    lz_token_fee: 0,
                },
            )?;
        }
    } else {
        let chain_config_info = &ctx.remaining_accounts[0];
        let chain_data = chain_config_info.try_borrow_data()?;
        let chain_config = ChainConfig::try_deserialize(&mut chain_data.as_ref())
            .map_err(|_| PithyQuip::InvalidPeer)?;

        require!(chain_config.active
        && chain_config.peer_address != [0u8; 32],
                    PithyQuip::PeerNotConfigured);

        // Wrap in OFT format
        let message = wrap_in_oft_format(compose_msg, chain_config.peer_address);
        let options = chain_config.enforced_options.get_enforced_options(&None::<Vec<u8>>);
        let quote_accounts = &ctx.remaining_accounts[1..7];
        let send_accounts = &ctx.remaining_accounts[7..];
        let quote_result = cpi_quote(
            ctx.accounts.oapp_store.endpoint_program, quote_accounts,
            QuoteParams {
                sender: ctx.accounts.oapp_store.key(),
                dst_eid: chain_config.eid,
                receiver: chain_config.peer_address,
                message: message.clone(),
                options: options.clone(),
                pay_in_lz_token: false,
            },
        )?;
        cpi_send(
            ctx.accounts.oapp_store.endpoint_program,
            ctx.accounts.oapp_store.key(), send_accounts, seeds,
            SendParams { dst_eid: chain_config.eid, receiver: chain_config.peer_address,
                message, options, native_fee: quote_result.native_fee, lz_token_fee: 0 },
        )?;
    } Ok(())
}

#[derive(Accounts)]
#[instruction(params: LzReceiveParams)]
pub struct LzReceive<'info> {
    #[account(mut, seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    /// CHECK: LayerZero endpoint account
    #[account(seeds = [b"OApp", store.key().as_ref()],
    bump, seeds::program = store.endpoint_program)]
    pub oapp_registry: AccountInfo<'info>,

    /// CHECK: LayerZero nonce account
    #[account(seeds = [b"Nonce",
        store.key().as_ref(),
        &params.src_eid.to_be_bytes(), &params.sender[..]],
        bump, seeds::program = store.endpoint_program
    )]
    pub nonce: AccountInfo<'info>,

    /// CHECK: LayerZero payload hash account
    #[account(mut,
        seeds = [b"PayloadHash",
        store.key().as_ref(),
        &params.src_eid.to_be_bytes(),
        &params.sender[..], &params.nonce.to_be_bytes()],
        bump, seeds::program = store.endpoint_program
    )]
    pub payload_hash: AccountInfo<'info>,

    /// CHECK: LayerZero endpoint settings
    #[account(mut, seeds = [b"Endpoint"],
    bump, seeds::program = store.endpoint_program)]
    pub endpoint: AccountInfo<'info>,

    /// CHECK: LayerZero endpoint program
    pub endpoint_program: AccountInfo<'info>,
}

#[derive(Accounts)]
pub struct LzReceiveTypes<'info> {
    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,
}

pub fn lz_receive_types_handler(ctx: Context<LzReceiveTypes>,
    params: &LzReceiveParams) -> Result<Vec<LzAccount>> {
    require!(params.message.len() > 0, PithyQuip::InvalidMessageType);
    let msg_type = params.message[0]; let mut accounts = vec![];
    if msg_type == FINAL_RULING {
        let ruling = FinalRuling::decode(&params.message)?;
        let (market_pda, _) = Pubkey::find_program_address(&[b"market",
                &ruling.market_id.to_le_bytes()[..6]], ctx.program_id);

        accounts.push(LzAccount { pubkey: market_pda,
            is_signer: false, is_writable: true });

        for i in 0..ruling.slashing_addresses.len() {
            let (position_pda, _) = Pubkey::find_program_address(
                &[b"position", market_pda.as_ref(),
                ruling.slashing_addresses[i].as_ref(),
                &[ruling.slashing_sides[i]]], ctx.program_id);

            accounts.push(LzAccount { pubkey: position_pda,
                    is_signer: false, is_writable: true });
        }
    } Ok(accounts)
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct InitOAppStoreParams {
    pub endpoint: Pubkey,
}

#[derive(Accounts)]
#[instruction(params: InitOAppStoreParams)]
pub struct InitOAppStore<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,

    #[account(init, payer = payer, space = OAppStore::SIZE, seeds = [OAPP_STORE_SEED], bump)]
    pub store: Account<'info, OAppStore>,

    #[account(init, payer = payer, space = LzReceiveTypesAccounts::SIZE,
              seeds = [LZ_RECEIVE_TYPES_SEED, &store.key().to_bytes()], bump)]
    pub lz_receive_types_accounts: Account<'info, LzReceiveTypesAccounts>,

    /// CHECK: Verified via constraint - program data must be derived from program
    #[account(
        constraint = {
            // Derive the expected programdata address from the program ID
            let (expected_programdata, _) = Pubkey::find_program_address(
                &[program.key().as_ref()],
                &anchor_lang::solana_program::bpf_loader_upgradeable::id()
            );
            expected_programdata == program_data.key()
        } @ PithyQuip::InvalidParameters
    )]
    pub program: AccountInfo<'info>,

    /// CHECK: Constraint ensures payer IS the upgrade authority
    #[account(
        constraint = {
            let data = program_data.try_borrow_data()?;
            // UpgradeableLoaderState::ProgramData layout:
            // - bytes 0..4: enum variant (3 = ProgramData)
            // - bytes 4..12: slot (u64)
            // - byte 12: Option discriminant (0 = None, 1 = Some)
            // - bytes 13..45: upgrade_authority pubkey (if Some)
            if data.len() < 45 { return Err(PithyQuip::InvalidParameters.into()); }
            let variant = u32::from_le_bytes(data[0..4].try_into().unwrap());
            if variant != 3 { return Err(PithyQuip::InvalidParameters.into()); }
            let has_authority = data[12] == 1;
            if !has_authority { return Err(PithyQuip::Unauthorized.into()); }
            let authority_bytes: [u8; 32] = data[13..45].try_into().unwrap();
            let upgrade_authority = Pubkey::new_from_array(authority_bytes);
            upgrade_authority == payer.key()
        } @ PithyQuip::Unauthorized
    )]
    pub program_data: AccountInfo<'info>,
    pub system_program: Program<'info, System>,
}

pub fn init_oapp_store_handler(ctx: &mut Context<InitOAppStore>, params: &InitOAppStoreParams) -> Result<()> {
    ctx.accounts.store.admin = ctx.accounts.payer.key();
    ctx.accounts.store.bump = ctx.bumps.store;
    ctx.accounts.store.endpoint_program = params.endpoint;
    ctx.accounts.store.registered_mints = Vec::new();
    ctx.accounts.lz_receive_types_accounts.store = ctx.accounts.store.key();

    #[cfg(not(feature = "testing"))]
    {
        let register_params = RegisterOAppParams { delegate: ctx.accounts.store.admin };
        let seeds: &[&[&[u8]]] = &[&[OAPP_STORE_SEED, &[ctx.accounts.store.bump]]];
        cpi_register_oapp(params.endpoint, ctx.accounts.store.key(), ctx.remaining_accounts, seeds, register_params)?;
    }

    #[cfg(feature = "testing")]
    Ok(())
}

#[account]
pub struct LzReceiveTypesAccounts {
    pub store: Pubkey,
}

impl LzReceiveTypesAccounts {
    pub const SIZE: usize = 8 + 32;
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct LzReceiveParams {
    pub src_eid: u32,
    pub sender: [u8; 32],
    pub nonce: u64,
    pub guid: [u8; 32],
    pub message: Vec<u8>,
    pub extra_data: Vec<u8>,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct SendParams {
    pub dst_eid: u32,
    pub receiver: [u8; 32],
    pub message: Vec<u8>,
    pub options: Vec<u8>,
    pub native_fee: u64,
    pub lz_token_fee: u64,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct ClearParams {
    pub receiver: Pubkey,
    pub src_eid: u32,
    pub sender: [u8; 32],
    pub nonce: u64,
    pub guid: [u8; 32],
    pub message: Vec<u8>,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct RegisterOAppParams {
    pub delegate: Pubkey,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct LzAccount {
    pub pubkey: Pubkey,
    pub is_signer: bool,
    pub is_writable: bool,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct QuoteParams {
    pub sender: Pubkey,
    pub dst_eid: u32,
    pub receiver: [u8; 32],
    pub message: Vec<u8>,
    pub options: Vec<u8>,
    pub pay_in_lz_token: bool,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct MessagingFee {
    pub native_fee: u64,
    pub lz_token_fee: u64,
}

pub mod options {
    use anchor_lang::prelude::*;
    use crate::etc::PithyQuip;
    pub fn assert_type_3(options: &Vec<u8>) -> Result<()> {
        if options.is_empty() { return Ok(()); }
        require!(options.len() >= 2,
        PithyQuip::InvalidOptions);
        require!(options[0] == 0 && options[1] == 3,
                    PithyQuip::InvalidOptions);
        Ok(())
    }

    pub fn combine_options(enforced: &Vec<u8>,
        extra: &Option<Vec<u8>>) -> Result<Vec<u8>> {
        match extra {
            None => Ok(enforced.clone()),
            Some(extra_opts) if extra_opts.is_empty() => Ok(enforced.clone()),
            Some(extra_opts) => {
                if enforced.is_empty() { return Ok(extra_opts.clone()); }
                let mut combined = enforced.clone();
                combined.extend_from_slice(extra_opts);
                Ok(combined)
            }
        }
    }
}

fn cpi_send<'info>(
    endpoint_program: Pubkey, _oapp: Pubkey,
    remaining_accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[&[u8]]], params: SendParams) -> Result<()> {
    let mut ix_data = vec![102, 251, 20, 187, 65, 75, 12, 69];
    ix_data.extend_from_slice(&params.try_to_vec()?);
    let ix = anchor_lang::solana_program::instruction::Instruction {
        program_id: endpoint_program, accounts: remaining_accounts.iter()
            .map(|acc| anchor_lang::solana_program::instruction::AccountMeta {
                pubkey: *acc.key, is_signer: acc.is_signer,
                is_writable: acc.is_writable }).collect(),
        data: ix_data,
    };
    anchor_lang::solana_program::program::invoke_signed(
                  &ix, remaining_accounts, signer_seeds)?;
    Ok(())
}

fn cpi_quote<'info>(endpoint_program: Pubkey,
    accounts: &[AccountInfo<'info>], params: QuoteParams) -> Result<MessagingFee> {
    let mut ix_data = vec![53, 91, 145, 11, 230, 75, 175, 90];
    ix_data.extend_from_slice(&params.try_to_vec()?);
    let ix = anchor_lang::solana_program::instruction::Instruction {
        program_id: endpoint_program, accounts: accounts.iter().map(
        |acc| anchor_lang::solana_program::instruction::AccountMeta {
                            pubkey: *acc.key, is_signer: acc.is_signer,
                is_writable: acc.is_writable }).collect(), data: ix_data };

    anchor_lang::solana_program::program::invoke(&ix, accounts)?;
    let (program_id, return_data) = anchor_lang::solana_program::program::get_return_data()
                                                        .ok_or(PithyQuip::NoReturnData)?;

    require!(program_id == endpoint_program, PithyQuip::InvalidReturnData);
    MessagingFee::try_from_slice(&return_data).map_err(|_| PithyQuip::InvalidReturnData.into())
}

pub fn cpi_clear<'info>(
    endpoint_program: Pubkey, _oapp: Pubkey, accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[&[u8]]], params: ClearParams) -> Result<()> {
    let mut ix_data = vec![250, 39, 28, 213, 123, 163, 133, 5];

    ix_data.extend_from_slice(&params.try_to_vec()?);
    let ix = anchor_lang::solana_program::instruction::Instruction {
        program_id: endpoint_program, accounts: accounts.iter().map(
                |acc| anchor_lang::solana_program::instruction::AccountMeta {
                                pubkey: *acc.key, is_signer: acc.is_signer,
                                is_writable: acc.is_writable, }).collect(),
        data: ix_data,
    };
    anchor_lang::solana_program::program::invoke_signed(
                            &ix, accounts, signer_seeds)?;
    Ok(())
}

pub fn cpi_register_oapp<'info>(
    endpoint_program: Pubkey, _oapp: Pubkey, accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[&[u8]]], params: RegisterOAppParams) -> Result<()> {
    let mut ix_data = vec![129, 89, 71, 68, 11, 82, 210, 125];
    ix_data.extend_from_slice(&params.try_to_vec()?);

    let ix = anchor_lang::solana_program::instruction::Instruction {
        program_id: endpoint_program, accounts: accounts.iter().map(
                |acc| anchor_lang::solana_program::instruction::AccountMeta {
                                pubkey: *acc.key, is_signer: acc.is_signer,
                                is_writable: acc.is_writable, }).collect(),
        data: ix_data,
    };
    anchor_lang::solana_program::program::invoke_signed(
                            &ix, accounts, signer_seeds)?;
    Ok(())
}

pub fn get_accounts_for_clear(_endpoint_program: &Pubkey,
    _receiver: &Pubkey, _src_eid: u32, _sender: &[u8; 32],
    _nonce: u64) -> Vec<LzAccount> { vec![] }
