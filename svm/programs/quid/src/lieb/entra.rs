
use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{ 
    self, Mint, TokenAccount, 
    TokenInterface, TransferChecked 
};
use crate::stay::*;
use crate::etc::{
    USD_STAR, HEX_MAP,
    MAX_LEN, PithyQuip
};

#[derive(Accounts)]
pub struct Deposit<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,
    pub mint: InterfaceAccount<'info, Mint>,
    
    #[account(
        init_if_needed, 
        space = 8 + Depository::INIT_SPACE, 
        payer = signer,
        seeds = [mint.key().as_ref()],
        bump,
    )]  
    pub bank: Account<'info, Depository>,
    
    #[account(
        init_if_needed, 
        token::mint = mint, 
        token::authority = bank_token_account,
        payer = signer,
        seeds = [b"vault", mint.key().as_ref()],
        bump, 
    )]  
    pub bank_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = signer, 
        space = 8 + Depositor::INIT_SPACE + MAX_LEN * Position::INIT_SPACE,
        seeds = [signer.key().as_ref()],
        bump,
    )]  
    pub customer_account: Account<'info, Depositor>,
    
    #[account( 
        init_if_needed, 
        payer = signer,
        associated_token::mint = mint, 
        associated_token::authority = signer,
        associated_token::token_program = token_program,
    )]
    pub customer_token_account: InterfaceAccount<'info, TokenAccount>, 
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn handle_in(ctx: Context<Deposit>, amount: u64, ticker: String) -> Result<()> {
    // require_keys_eq!(ctx.accounts.mint.key(), USD_STAR, PithyQuip::InvalidMint);
    // ^ only for deployment, comment out for anchor test --skip-local-validator
    require!(amount >= 100000000, PithyQuip::InvalidAmount); // $100; if too small,
    // then the liqudiator cut, which is also small, may not be enough of an 
    // incentive to cover the gas cost of the performing the transaction...
    let Banks = &mut ctx.accounts.bank;
    let customer = &mut ctx.accounts.customer_account;
    let transfer_cpi_accounts = TransferChecked {
        from: ctx.accounts.customer_token_account.to_account_info(),
        mint: ctx.accounts.mint.to_account_info(),
        to: ctx.accounts.bank_token_account.to_account_info(),
        authority: ctx.accounts.signer.to_account_info(),
    };  let decimals = ctx.accounts.mint.decimals;
    let cpi_program = ctx.accounts.token_program.to_account_info();
    let cpi_ctx = CpiContext::new(cpi_program, transfer_cpi_accounts);
    token_interface::transfer_checked(cpi_ctx, amount, decimals)?; 
    
    let mut users_shares = amount;
    if Banks.total_deposits == 0 {
        Banks.interest_rate = 12;
        Banks.total_deposits = amount;
        Banks.total_deposit_shares = amount;
    } 
    if customer.owner == Pubkey::default() {
        customer.owner = ctx.accounts.signer.key();
    }
    if ticker.is_empty() {
        customer.deposited_usd_star += amount;
        customer.deposited_usd_star_shares += users_shares;
    } 
    else if Banks.total_deposits > 0 { 
        let t: &str = ticker.as_str();
        if HEX_MAP.get(t).is_none() {
            return Err(PithyQuip::UnknownSymbol.into());
        }   customer.renege(Some(t), amount as i64, 
        None, Clock::get()?.unix_timestamp)?;
        let deposit_ratio = amount.checked_div(Banks.total_deposits).unwrap();
        users_shares = Banks.total_deposit_shares.checked_mul(deposit_ratio).unwrap();
        Banks.total_deposits += amount; Banks.total_deposit_shares += users_shares;
    } Ok(())
}
