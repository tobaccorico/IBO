// src/contracts/addresses.ts
// Update these addresses after deploying contracts with Deploy.s.sol

export const FACTORY_ADDRESS = "0x..."; // AuctionFactory address
export const HELPERS_ADDRESS = "0x..."; // AuctionHelpers address  
export const SETTLEMENT_ADDRESS = "0x..."; // Settlement address
export const BASKET_ADDRESS = "0x..."; // Basket (QUID) address

// Chain configuration
export const CHAIN_ID = 8453; // Base mainnet (update for your chain)
export const RPC_URL = "https://mainnet.base.org"; // Update for your chain

// Contract deployment block (for event filtering)
export const DEPLOYMENT_BLOCK = 0; // Update with actual deployment block

// Export all addresses as a config object
export const CONTRACT_ADDRESSES = {
  factory: FACTORY_ADDRESS,
  helpers: HELPERS_ADDRESS,
  settlement: SETTLEMENT_ADDRESS,
  basket: BASKET_ADDRESS
};

// Helper to validate addresses
export function isValidAddress(address: string): boolean {
  return /^0x[a-fA-F0-9]{40}$/.test(address);
}

// Helper to check if contracts are configured
export function areContractsConfigured(): boolean {
  return Object.values(CONTRACT_ADDRESSES).every(addr => 
    addr !== "0x..." && isValidAddress(addr)
  );
}