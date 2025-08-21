
import React, { createContext, useContext, useState } from "react";
import { PublicKey } from "@solana/web3.js";

const PRICE_FEED_ID =
  "0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2";

const PRICE_FEED_ACCOUNT = new PublicKey(
  "2uPQGpm8X4ZkxMHxrAW1QuhXcse1AHEgPih6Xp9NuEWW",
); // https://docs.pyth.network/price-feeds/sponsored-feeds/solana

// Shared state for pyth price feed
interface PythPriceContextType {
  AuPrice: Number;
  PriceFeedAccount: PublicKey;
  fetchInitialPrice: () => Promise<void>;
  isLoading: boolean;
  error: string | null;
}

const PythPriceContext = createContext<PythPriceContextType | undefined>(
  undefined,
);

export function usePythPrice() {
  const context = useContext(PythPriceContext);
  if (context === undefined) {
    throw new Error("usePythPrice must be used within a PythPriceProvider");
  }
  return context;
}

export function PythPriceProvider({ children }: { children: React.ReactNode }) {  
  const [AuPrice, setPrice] = useState(0);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchInitialPrice = async () => {
    try {  
      await fetch(
        `https://hermes.pyth.network/api/latest_price_feeds?ids[]=${PRICE_FEED_ID}&encoding=base64`
      ).then((response) => {
        if (!response.ok) {
          console.log("no")
          throw new Error(`Failed to fetch price feed: ${response.status} ${response.statusText}`);
        }
        return response.json()
      }).then((json) => {
        if (json != null) {
          let price = json[0]
          
          let adjusted = Number(price.price.price) * 
            Math.pow(10, Number(price.price.expo))
          
          setPrice(adjusted);
        } else {
          setError("No price feeds returned");
        } 
        setIsLoading(false);  
      })
    } catch (err) {
      setError("Failed to fetch initial Au price");
      setIsLoading(false);
    }
  };

  return (
    <PythPriceContext.Provider
      value={{
        AuPrice,
        PriceFeedAccount: PRICE_FEED_ACCOUNT,
        fetchInitialPrice,
        isLoading,
        error,
      }}> {children}
    </PythPriceContext.Provider>
  );
}
