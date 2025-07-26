use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(init, payer = payer, space = 8 + ConditionManager::MAX_SIZE)]
    pub condition_manager: Account<'info, ConditionManager>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Modify<'info> {
    #[account(mut)]
    pub condition_manager: Account<'info, ConditionManager>,
}

#[derive(Accounts)]
pub struct Validate<'info> {
    pub condition_manager: Account<'info, ConditionManager>,
}

#[account]
pub struct ConditionManager {
    pub frozen: bool,
    pub logic: Logic,
    pub conditions: Vec<Pubkey>,
}

impl ConditionManager {
    pub const MAX_SIZE: usize = 1 + 1 + (32 * 20);
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq)]
pub enum Logic {
    And,
    Or,
}

#[error_code]
pub enum ConditionErrorCode {
    #[msg("Cannot modify conditions in frozen mode.")]
    Immutable,
    #[msg("Duplicate condition.")]
    Duplicate,
    #[msg("Condition not found.")]
    ConditionNotFound,
    #[msg("Condition failed.")]
    ConditionFailed,
    #[msg("Required condition account is missing.")]
    MissingAccount,
}

pub trait ConditionInterface {
    fn validate(account_info: &AccountInfo) -> Result<bool>;
}

// Condition manager instruction handlers
pub fn initialize_condition_manager(
    ctx: Context<Initialize>,
    frozen: bool,
    logic: Logic,
) -> Result<()> {
    let manager = &mut ctx.accounts.condition_manager;
    manager.frozen = frozen;
    manager.logic = logic;
    Ok(())
}

pub fn add_condition(ctx: Context<Modify>, condition: Pubkey) -> Result<()> {
    let manager = &mut ctx.accounts.condition_manager;
    require!(!manager.frozen, ConditionErrorCode::Immutable);

    require!(
        !manager.conditions.contains(&condition),
        ConditionErrorCode::Duplicate
    );

    manager.conditions.push(condition);
    Ok(())
}

pub fn remove_condition(ctx: Context<Modify>, condition: Pubkey) -> Result<()> {
    let manager = &mut ctx.accounts.condition_manager;
    require!(!manager.frozen, ConditionErrorCode::Immutable);

    if let Some(index) = manager.conditions.iter().position(|x| *x == condition) {
        manager.conditions.swap_remove(index);
        Ok(())
    } else {
        err!(ConditionErrorCode::ConditionNotFound)
    }
}

pub fn validate_conditions(ctx: Context<Validate>) -> Result<()> {
    let manager = &ctx.accounts.condition_manager;
    let remaining = &ctx.remaining_accounts;

    let mut successes = 0;
    let total = manager.conditions.len();

    for condition_key in &manager.conditions {
        let acc = remaining
            .iter()
            .find(|a| a.key == *condition_key)
            .ok_or(ConditionErrorCode::MissingAccount)?;

        let is_valid = ConditionInterface::validate(acc)?;

        if is_valid {
            successes += 1;
            if manager.logic == Logic::Or {
                return Ok(());
            }
        } else if manager.logic == Logic::And {
            return err!(ConditionErrorCode::ConditionFailed);
        }
    }

    if manager.logic == Logic::Or && successes == 0 {
        return err!(ConditionErrorCode::ConditionFailed);
    }

    Ok(())
}