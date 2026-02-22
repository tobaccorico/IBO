export interface Chain {
  id: number
  name: string
  icon: string
  hex: string
  explorer: string
  color: string
  enabled: boolean
  hasLeverage: boolean  // Unichain doesn't have Amp
}

export interface Contracts {
  vogue: string
  vogueCore: string
  rover: string
  aux: string
  basket: string
  weth: string
  hook: string
  uma: string
  amp: string
}

export interface StableToken {
  symbol: string
  address: string
  decimals: number
  isVault?: boolean
}

export const CHAINS: Record<number, Chain> = {
  1: { id: 1, name: 'Ethereum', icon: '⟠', hex: '0x1', explorer: 'https://etherscan.io', color: '#627EEA', enabled: false, hasLeverage: true },
  137: { id: 137, name: 'Polygon', icon: '🟣', hex: '0x89', explorer: 'https://polygonscan.com', color: '#8247E5', enabled: false, hasLeverage: true },
  8453: { id: 8453, name: 'Base', icon: '🔵', hex: '0x2105', explorer: 'https://basescan.org', color: '#0052FF', enabled: false, hasLeverage: true },
  42161: { id: 42161, name: 'Arbitrum', icon: '🔷', hex: '0xa4b1', explorer: 'https://arbiscan.io', color: '#28A0F0', enabled: true, hasLeverage: true },
  130: { id: 130, name: 'Unichain', icon: '🦄', hex: '0x82', explorer: 'https://uniscan.xyz', color: '#FF007A', enabled: false, hasLeverage: false },
}

// Get only enabled chains
export const ENABLED_CHAINS = Object.values(CHAINS).filter(c => c.enabled)

export const CONTRACTS: Record<number, Contracts> = {
  1: { // Ethereum L1 - DISABLED (updating addresses)
    vogue: '0xEE84aaC4ea6F6Aeb1B1F6C045A22Ec0399CdFa5D',
    vogueCore: '0xEC48a5703F75Bfe2354B7b9a229627fd32C1696e',
    rover: '0xA0162a4Ecc70F70e4d1a3F9780096E3eAc662D55',
    aux: '0x065ed7A4249e6C8064c8BcC7C94c5a55D0905Cba',
    basket: '0xEFc1C956064B502eb4E381c4C9BAF31C5f1A5eE5',
    weth: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
    hook: '0x0fb5b3F06b407D26c5D919B9121A7481851c9C2D',
    uma: '0x78AE10c13600dF439e78b164CC1267A9Baab50CB',
    amp: '0x95915492Ae15793DD799cEa4E4CF0446B28FfA6a',
  },
  137: { // Polygon - DISABLED (not yet deployed)
    vogue: '0x9743dE2355d3840D52529503d496bf33fF7a9793',
    vogueCore: '0x6a436d35A48108556fB02FE18Be16ed3408D02Dd',
    rover: '0xB9Ae20B2ed85e508c29881F24Aa1308dD3751AFF',
    aux: '0xcEB26F3898F84C90a1FbFE7e305126327df5eEDa',
    basket: '0x02783890102DdC4585d4703647bd4DD24164cb2D',
    weth: '0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619',
    hook: '0x0000000000000000000000000000000000000000',
    uma: '0x0000000000000000000000000000000000000000',
    amp: '0x184b1D1cfD9De5D8BF70BCE2d7960741b5D0876E',
  },
  8453: { // Base - DISABLED
    vogue: '0x64830Cc6682C36dE6EAA1Afc771FBfc16322D092',
    vogueCore: '0x1642c86E7cb6D984fe0792884eC707c1Ab975AdA',
    rover: '0x5cc4A537D0CFe4479EE0c325D73134D930691199',
    aux: '0xB3Ab6732580D9b75E8f6eb3ea8204500E9872D75',
    basket: '0x7Cd2934584Ba15A9D352C166B2a2Cf4C476F443D',
    weth: '0x4200000000000000000000000000000000000006',
    hook: '0x0000000000000000000000000000000000000000',
    uma: '0x0000000000000000000000000000000000000000',
    amp: '0x48AE204e2e2dd73C6ab6B20A040902511E48f552',
  },
  42161: { // Arbitrum - ENABLED
    vogue: '0xC72eB8A1Af1e6d8df041F4a42A67bdfdCC14a088',
    vogueCore: '0x941FA25f9e9eaB5ecd402DAf22b0666Bd9E89198',
    rover: '0x4644fABac4b9b18834FecB4565409C083eCA73D3',
    aux: '0x376806f1E797079A0d99d7F3350A77b6E6ab52AC',
    basket: '0xe6a783Bb6743169C116949525d69f3291c931d85',
    weth: '0x82aF49447D8a07e3bd95BD0d56f35241523fBab1',
    hook: '0x0Fded58C90bEEafb5946c14E8AfABc107bdD79Bf',
    uma: '0x4a4A76c9Dba55E7e3285e2d8CB815eC28104ede8',
    amp: '0x9F773623952e9955379D7Af4E0eb971065c37F8F',
  },
  130: { // Unichain - DISABLED
    vogue: '0xA42EC270cCC8176e966A454DE91ca20eEB845AB0',
    vogueCore: '0x1d8227d7cDABce4aC80182857Bc0dE28645Fae53',
    rover: '0x19F4B1215456f706475e0Ee408D216EBB181129A',
    aux: '0x146D7bEC5ACCC0446B2052AFc44b21C05B1F93b1',
    basket: '0xBae245f523f4Fb2c377895Ee6d30De5488d15a83',
    weth: '0x4200000000000000000000000000000000000006',
    hook: '0x0000000000000000000000000000000000000000',
    uma: '0x0000000000000000000000000000000000000000',
    amp: '0x0000000000000000000000000000000000000000',
  },
}

// Amp addresses (keeper only - not exposed to frontend users)
// Unichain has no Amp contract
export const AMP_ADDRESSES: Record<number, string> = {
  1: '0x3cD9ef974354092C375C807122b9E1B245FD5D84',      // L1
  137: '0x184b1D1cfD9De5D8BF70BCE2d7960741b5D0876E',    // Polygon (placeholder)
  8453: '0x48AE204e2e2dd73C6ab6B20A040902511E48f552',   // Base
  42161: '0x9F773623952e9955379D7Af4E0eb971065c37F8F',  // Arbitrum
  // 130: No Amp on Unichain
}

export const STABLES: Record<number, StableToken[]> = {
  1: [ // Ethereum L1
    { symbol: 'USDC', address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', decimals: 6 },
    { symbol: 'USDT', address: '0xdAC17F958D2ee523a2206206994597C13D831ec7', decimals: 6 },
    { symbol: 'DAI', address: '0x6B175474E89094C44Da98b954EedeAC495271d0F', decimals: 18 },
    { symbol: 'PYUSD', address: '0x6c3ea9036406852006290770BEdFcAbA0e23A0e8', decimals: 6 },
    { symbol: 'USDS', address: '0xdC035D45d973E3EC169d2276DDab16f1e407384F', decimals: 18 },
    { symbol: 'USDe', address: '0x4c9EDD5852cd905f086C759E8383e09bff1E68B3', decimals: 18 },
    { symbol: 'crvUSD', address: '0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E', decimals: 18 },
    { symbol: 'FRAX', address: '0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29', decimals: 18 },
    { symbol: 'GHO', address: '0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f', decimals: 18 },
    { symbol: 'BOLD', address: '0x6440f144b7e50d6a8439336510312d2f54beb01d', decimals: 18 },
    // Vault tokens
    { symbol: 'sDAI', address: '0x83F20F44975D03b1b09e64809B757c47f942BEeA', decimals: 18, isVault: true },
    { symbol: 'sFRAX', address: '0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6', decimals: 18, isVault: true },
    { symbol: 'sUSDS', address: '0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD', decimals: 18, isVault: true },
    { symbol: 'sUSDe', address: '0x9D39A5DE30e57443BfF2A8307A4256c8797A3497', decimals: 18, isVault: true },
    { symbol: 'scrvUSD', address: '0x0655977FEb2f289A4aB78af67BAB0d17aAb84367', decimals: 18, isVault: true },
  ],
  137: [ // Polygon - placeholder until deployed
    { symbol: 'USDC', address: '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359', decimals: 6 },
    { symbol: 'USDT', address: '0xc2132D05D31c914a87C6611C10748AEb04B58e8F', decimals: 6 },
    { symbol: 'DAI', address: '0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063', decimals: 18 },
    { symbol: 'FRAX', address: '0x45c32fA6DF82ead1e2EF74d17b76547EDdFaFF89', decimals: 18 },
  ],
  8453: [ // Base
    { symbol: 'USDC', address: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', decimals: 6 },
    { symbol: 'USDT', address: '0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2', decimals: 6 },
    { symbol: 'DAI', address: '0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb', decimals: 18 },
    { symbol: 'GHO', address: '0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee', decimals: 18 },
    { symbol: 'USDS', address: '0x820C137fa70C8691f0e44Dc420a5e53c168921Dc', decimals: 18 },
    { symbol: 'USDe', address: '0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34', decimals: 18 },
    { symbol: 'crvUSD', address: '0x417Ac0e078398C154EdFadD9Ef675d30Be60Af93', decimals: 18 },
    { symbol: 'FRAX', address: '0xe5020A6d073a794B6E7f05678707dE47986Fb0b6', decimals: 18 },
    // Vault tokens
    { symbol: 'sFRAX', address: '0x91A3f8a8d7a881fBDfcfEcd7A2Dc92a46DCfa14e', decimals: 18, isVault: true },
    { symbol: 'sUSDS', address: '0x5875eEE11Cf8398102FdAd704C9E96607675467a', decimals: 18, isVault: true },
    { symbol: 'sUSDe', address: '0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2', decimals: 18, isVault: true },
    { symbol: 'scrvUSD', address: '0x646A737B9B6024e49f5908762B3fF73e65B5160c', decimals: 18, isVault: true },
  ],
  42161: [ // Arbitrum
    { symbol: 'USDC', address: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831', decimals: 6 },
    { symbol: 'USDT', address: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9', decimals: 6 },
    { symbol: 'DAI', address: '0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1', decimals: 18 },
    { symbol: 'GHO', address: '0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33', decimals: 18 },
    { symbol: 'USDS', address: '0x6491c05A82219b8D1479057361ff1654749b876b', decimals: 18 },
    { symbol: 'USDe', address: '0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34', decimals: 18 },
    { symbol: 'crvUSD', address: '0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5', decimals: 18 },
    { symbol: 'FRAX', address: '0x80Eede496655FB9047dd39d9f418d5483ED600df', decimals: 18 },
    // Vault tokens
    { symbol: 'sFRAX', address: '0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0', decimals: 18, isVault: true },
    { symbol: 'sUSDS', address: '0xdDb46999F8891663a8F2828d25298f70416d7610', decimals: 18, isVault: true },
    { symbol: 'sUSDe', address: '0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2', decimals: 18, isVault: true },
    { symbol: 'scrvUSD', address: '0xEfB6601Df148677A338720156E2eFd3c5Ba8809d', decimals: 18, isVault: true },
  ],
  130: [ // Unichain
    { symbol: 'USDC', address: '0x078D782b760474a361dDA0AF3839290b0EF57AD6', decimals: 6 },
    { symbol: 'USDT', address: '0x9151434b16b9763660705744891fA906F660EcC5', decimals: 6 },
    { symbol: 'USDS', address: '0x7E10036Acc4B56d4dFCa3b77810356CE52313F9C', decimals: 18 },
    { symbol: 'FRAX', address: '0x80Eede496655FB9047dd39d9f418d5483ED600df', decimals: 18 },
    // Vault tokens
    { symbol: 'sUSDS', address: '0xA06b10Db9F390990364A3984C04FaDf1c13691b5', decimals: 18, isVault: true },
  ],
}
