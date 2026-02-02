// Contract ABIs for Vogue Protocol

// ERC20 ABI (for stablecoins)
export const ERC20_ABI = [
  'function balanceOf(address owner) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
  'function name() view returns (string)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function transferFrom(address from, address to, uint256 amount) returns (bool)',
];

// Basket (QD Token) ABI
export const BASKET_ABI = [
  // ERC20 functions
  'function balanceOf(address owner) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
  'function name() view returns (string)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function transferFrom(address from, address to, uint256 amount) returns (bool)',
  // Basket-specific functions
  'function mint(address pledge, uint256 amount, address token, uint256 when) returns (uint256)',
  'function currentMonth() view returns (uint256)',
  'function totalSupplies(uint256 month) view returns (uint256)',
  'function seeded() view returns (uint256)',
  'function V4() view returns (address)',
  // ERC6909 functions (multi-token)
  'function balanceOf(address owner, uint256 id) view returns (uint256)',
  // Mature balance helper (requires contract update)
  // 'function totalMatureBalanceOf(address owner) view returns (uint256)',
];

// Vogue (UniV4 Liquidity Manager) ABI - L1 Ethereum
export const VOGUE_ABI = [
  'function deposit(uint256 amount) payable',
  'function withdraw(uint256 amount)',
  'function autoManaged(address user) view returns (uint256 pooled_eth, uint256 fees_eth, uint256 fees_usd, uint256 usd_owed)',
  'function pendingRewards(address user) view returns (uint256 ethReward, uint256 usdReward)',
  'function totalShares() view returns (uint256)',
  'function YIELD() view returns (uint256)',
  'function ETH_FEES() view returns (uint256)',
  'function USD_FEES() view returns (uint256)',
  'function PENDING_ETH() view returns (uint256)',
  'function PENDING_USD() view returns (uint256)',
  'function token1isETH() view returns (bool)',
  // Self-managed positions
  'function outOfRange(uint256 amount, address token, int24 distance, int24 range) payable returns (uint256 next)',
  'function pull(uint256 id, int256 percent, address token)',
  'function positions(address user, uint256 index) view returns (uint256)',
  'function selfManaged(uint256 id) view returns (address owner, int24 lower, int24 upper, int256 liq)',
];

// VogueArb (UniV4 Liquidity Manager) ABI - Arbitrum (uses AAVE instead of Morpho)
export const VOGUE_ARB_ABI = [
  'function deposit(uint256 amount) payable',
  'function withdraw(uint256 amount)',
  'function autoManaged(address user) view returns (uint256 pooled_eth, uint256 fees_eth, uint256 fees_usd, uint256 usd_owed)',
  'function pendingRewards(address user) view returns (uint256 ethReward, uint256 usdReward)',
  'function totalShares() view returns (uint256)',
  'function YIELD() view returns (uint256)',
  'function ETH_FEES() view returns (uint256)',
  'function USD_FEES() view returns (uint256)',
  'function PENDING_ETH() view returns (uint256)',
  'function PENDING_USD() view returns (uint256)',
  'function token1isETH() view returns (bool)',
  // Self-managed positions
  'function outOfRange(uint256 amount, address token, int24 distance, int24 range) payable returns (uint256 next)',
  'function pull(uint256 id, int256 percent, address token)',
  'function positions(address user, uint256 index) view returns (uint256)',
  'function selfManaged(uint256 id) view returns (address owner, int24 lower, int24 upper, int256 liq)',
];

// Rover (UniV3 Liquidity Manager) ABI
export const ROVER_ABI = [
  'function deposit(uint256 amount) payable',
  'function withdraw(uint256 amount)',
  'function positions(address user) view returns (uint256 fees_eth, uint256 fees_usd, uint128 liq)',
  'function pendingRewards(address user) view returns (uint256 fees_eth, uint256 fees_usd)',
  'function totalShares() view returns (uint256)',
  'function liquidityUnderManagement() view returns (uint128)',
  'function YIELD() view returns (uint256)',
  'function ETH_FEES() view returns (uint256)',
  'function USD_FEES() view returns (uint256)',
  'function token1isWETH() view returns (bool)',
  'function getPrice(uint160 sqrtRatioX96) view returns (uint256 price)',
  'function repackNFT() returns (uint160)',
];

// Aux (Price Oracle & Swap Router) ABI - L1 Ethereum
export const AUX_ABI = [
  // Swap function - main entry point for swaps
  'function swap(address token, bool forETH, uint256 amount, uint256 waitable) payable returns (uint256 blockNumber)',
  // Redeem QD for stablecoins
  'function redeem(uint256 amount)',
  // Price functions
  'function getPrice(uint160 sqrtPriceX96, bool token0isUSD) pure returns (uint256 price)',
  'function getTWAP(uint32 period) view returns (uint256 price)',
  // Metrics - total deposits and yield
  'function get_metrics(bool force) returns (uint256 total, uint256 yield)',
  'function getAverageYield() view returns (uint256)',
  'function get_deposits() view returns (uint256[11])',
  // Fee calculation - returns fee in basis points (e.g., 4 = 0.04%)
  'function getFee(address token) view returns (uint256)',
  // Deposit (used internally)
  'function deposit(address from, address token, uint256 amount) returns (uint256 usd)',
  // Stablecoin info
  'function stables(uint256 index) view returns (address)',
  'function isStable(address token) view returns (bool)',
  'function isVault(address token) view returns (bool)',
  'function vaults(address token) view returns (address)',
  // Leverage functions
  'function leverETH(uint256 amount) payable',
  'function leverUSD(uint256 amount, address token) returns (uint256 usdcAmount)',
  // References
  'function WETH() view returns (address)',
];

// AuxArb/AuxBase ABI - Base & Arbitrum (14-element deposits array)
export const AUX_ARB_ABI = [
  // Swap function
  'function swap(address token, bool forETH, uint256 amount, uint256 waitable) payable returns (uint256 blockNumber)',
  // Redeem QD for stablecoins
  'function redeem(uint256 amount)',
  // Price functions
  'function getPrice(uint160 sqrtPriceX96, bool token0isUSD) pure returns (uint256 price)',
  'function getTWAP(uint32 period) view returns (uint256 price)',
  // Metrics - total deposits and yield
  'function get_metrics(bool force) returns (uint256 total, uint256 yield)',
  'function getAverageYield() view returns (uint256)',
  'function get_deposits() view returns (uint256[14])',
  // Fee calculation - returns fee in basis points
  'function getFee(address token) view returns (uint256)',
  // Stablecoin info
  'function stables(uint256 index) view returns (address)',
  'function isStable(address token) view returns (bool)',
  'function isVault(address token) view returns (bool)',
  'function vaults(address token) view returns (address)',
  // Leverage functions
  'function leverETH(uint256 amount) payable',
  'function leverUSD(uint256 amount, address token) returns (uint256 usdcAmount)',
  // References
  'function WETH() view returns (address)',
];

// Combined ABI for convenience (includes all functions)
export const COMBINED_ABI = [
  ...ERC20_ABI,
  // Basket
  'function mint(address pledge, uint256 amount, address token, uint256 when) returns (uint256)',
  'function currentMonth() view returns (uint256)',
  // Vogue/VogueArb
  'function deposit(uint256 amount) payable',
  'function withdraw(uint256 amount)',
  'function autoManaged(address user) view returns (uint256 pooled_eth, uint256 fees_eth, uint256 fees_usd, uint256 usd_owed)',
  'function pendingRewards(address user) view returns (uint256 ethReward, uint256 usdReward)',
  // Aux swap
  'function swap(address token, bool forETH, uint256 amount, uint256 waitable) payable returns (uint256 blockNumber)',
  'function redeem(uint256 amount)',
  'function getTWAP(uint32 period) view returns (uint256 price)',
];
