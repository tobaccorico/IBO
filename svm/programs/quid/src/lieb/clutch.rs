
use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{ 
    self, Mint, TokenAccount, 
    TokenInterface, TransferChecked 
};
use crate::stay::*;
use crate::etc::{ USD_STAR, MAX_AGE,
    ACCOUNT_MAP, HEX_MAP, PithyQuip,
    fetch_price, fetch_multiple_prices
};

#[derive(Accounts)]
pub struct Liquidate<'info> {
    /// CHECK: raw account only to validate ownership;
    /// no reads/writes or assumptions beyond `.key()`
    pub liquidating: AccountInfo<'info>,
    // Obiwan Kenobi

    #[account(mut)]
    pub liquidator: Signer<'info>,
    // убиван who not bleed...

    pub mint: InterfaceAccount<'info, Mint>,
    
    #[account(mut, 
        seeds = [mint.key().as_ref()],
        bump,
    )]  
    pub bank: Account<'info, Depository>,
    
    #[account(mut, 
        seeds = [b"vault", mint.key().as_ref()],
        bump, 
    )]  
    pub bank_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut, 
        seeds = [liquidating.key().as_ref()],
        bump,
    )]  
    pub customer_account: Account<'info, Depositor>,

    #[account( 
        init_if_needed, 
        payer = liquidator,
        associated_token::mint = mint, 
        associated_token::authority = liquidator,
        associated_token::token_program = token_program,
        constraint = liquidator_token_account.owner == liquidator.key() 
    )] 
    pub liquidator_token_account: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

// "It's like inch by inch...step by step...closin' in on your position
//  in small doses...when things have gotten closer to the sun," she said, 
// "don't think I'm pushing you away as ⚡️ strikes...court lights get dim"
pub fn amortise(ctx: Context<Liquidate>, ticker: String) -> Result<()> { 
    // require_keys_eq!(ctx.accounts.mint.key(), USD_STAR, PithyQuip::InvalidMint); 
    // ^ only for deployment, comment out for anchor test --skip-local-validator
    
    let Banks = &mut ctx.accounts.bank;
    let customer = &mut ctx.accounts.customer_account;
    require_keys_eq!(customer.owner, 
        ctx.accounts.liquidating.key(), 
        PithyQuip::InvalidUser);
    
    let transfer_cpi_accounts = TransferChecked {
        from: ctx.accounts.bank_token_account.to_account_info(),
        mint: ctx.accounts.mint.to_account_info(),
        to: ctx.accounts.liquidator_token_account.to_account_info(),
        authority: ctx.accounts.bank_token_account.to_account_info(),
    };
    let cpi_program = ctx.accounts.token_program.to_account_info();
    let mint_key = ctx.accounts.mint.key();
    let signer_seeds: &[&[&[u8]]] = &[
        &[ b"vault", mint_key.as_ref(),
            &[ctx.bumps.bank_token_account],
        ],
    ]; 
    let decimals = ctx.accounts.mint.decimals;
    let cpi_ctx = CpiContext::new(cpi_program, 
            transfer_cpi_accounts).with_signer(signer_seeds);

    let t: &str = ticker.as_str(); 
    let right_now = Clock::get()?.unix_timestamp;
    let key: &str = ACCOUNT_MAP.get(t).ok_or(PithyQuip::UnknownSymbol)?;
    let first: &AccountInfo = &ctx.remaining_accounts[0];
    let first_key = first.key.to_string(); 
    if first_key != key {
        return Err(PithyQuip::UnknownSymbol.into());
    }
    let adjusted_price = fetch_price(t, first)?;

    // Update time-weighted metrics for proper interest rate calculation
    let mut time_delta = right_now - customer.last_updated;
    customer.deposit_seconds += (customer.deposited_usd_star * time_delta as u64) as u128; 
    
    time_delta = right_now - Banks.last_updated;
    Banks.total_deposit_seconds += (Banks.total_deposits * time_delta as u64) as u128;
    Banks.last_updated = right_now;

    let (mut delta, mut interest) = customer.repo(t, 
         0, adjusted_price, right_now, Banks.interest_rate, Banks)?;
    
    require!(delta != 0, PithyQuip::NotUndercollateralised);
    // ^ delta has to be non-zero, otherwise the position is
    // totally within boundaries, and no need to be touched
    Banks.total_deposits += interest;
    
    // Calculate liquidator commission (~0.5%)
    interest = (delta.abs() as u64 / 250) as u64;
    
    if delta < 0 { 
        // Take profit on behalf of all depositors, at the expense of one... 
        delta *= -1; // < remove symbolic meaning, converting it to a usable number
        delta -= interest as i64; // < commission for the liquidator
    
        Banks.total_deposits += delta as u64;
        Banks.record_take_profit(delta as u64);
    }
    else if delta > 0 { 
        // Position was saved from liquidation
        // before we try to deduct from depository
        // attempt to salvage amount from depositor
        let prices = fetch_multiple_prices(&customer.balances, ctx.remaining_accounts)?;
        
        // Try to salvage from other positions first
        let remainder = customer.renege(None, -delta as i64, Some(&prices), right_now)? as i64;
        customer.deposited_usd_star += (delta - remainder) as u64; // < return amount deducted in stay (repo), now taken from positions
        
        // Remaining amount comes from total deposits (pool loss)
        Banks.total_deposits -= remainder as u64;
    }   Banks.reprice(); 
    
    // TODO pay liquidator commission or instead deposit it depending on flag
    token_interface::transfer_checked(cpi_ctx, interest, decimals)?;
    Ok(())
}
