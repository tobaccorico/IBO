
"use client";

import React, { createContext, useContext, useEffect, useState } from "react";
import { useConnection, useWallet } from "@solana/wallet-adapter-react";
import { AccountInfo, PublicKey } from "@solana/web3.js";
import { IdlAccounts, Program, AnchorProvider } from "@coral-xyz/anchor";
import type { Quid } from "../anchor/idlTypes";
import idl from "../anchor/idl.json";
import { Buffer } from 'buffer';

export type DepositoryAccount = IdlAccounts<Quid>["depository"];

// Shared state for program depository account
interface DepositoryContextType {
  depository: DepositoryAccount | null;
  program: Program<Quid> | null;
  depositoryAccountPDA: PublicKey | null;
  depositoryIsLoading: boolean;
  depositoryError: string | null;
}

const DepositoryContext = createContext<DepositoryContextType | undefined>(undefined);

export function useDepository() {
  const context = useContext(DepositoryContext);
  if (context === undefined) {
    throw new Error("useDepository must be used within a DepositoryProvider");
  }
  return context;
}

export function DepositoryProvider({ children }: { children: React.ReactNode }) {
  const wallet = useWallet()
  const { connection } = useConnection();
  const [depositoryIsLoading, setIsLoading] = useState(true);
  const [depositoryError, setError] = useState<string | null>(null);
  const [program, setProgram] = useState<Program<Quid> | null>(null);
  const [depository, setDepository] = useState<DepositoryAccount | null>(null);
  const [depositoryAccountPDA, setDepositoryAccountPDA] = useState<PublicKey | null>(null);
  

  /*
  const handleAccountChange = (accountInfo: AccountInfo<Buffer>) => {
    try {
      if (program != null) {
        const decodedData = program.coder.accounts.decode(
          "depository",
          accountInfo.data,
        ) as DepositoryAccount;
        setDepository(decodedData);
        setError(null);
      } else {
        console.error("Program is null")
        setError("Program is null");
      }
    } catch (error) {
      console.error("Error decoding depository account data:", error);
      setError("Failed to decode depository account data");
    } finally {
      setIsLoading(false);
    }
  }; */

  useEffect(() => {
    if (!wallet.connected 
      || !wallet.publicKey 
      || !wallet.signTransaction
      || !wallet.signAllTransactions) {
      setDepository(null);
      setDepositoryAccountPDA(null);
      setIsLoading(false);
      setError(null);
      return;
    }
    var programId: PublicKey;
    if (!program) {
      setIsLoading(true);
      const anchorWallet = {
        publicKey: wallet.publicKey,
        signTransaction: wallet.signTransaction,
        signAllTransactions: wallet.signAllTransactions,
      };
      const provider = new AnchorProvider(connection, anchorWallet, { preflightCommitment: "confirmed" });
      let p = new Program<Quid>(idl as Quid, provider)
      setProgram(p);      
      programId = p.programId;
    } else {
      programId = program.programId
    }
    if (!depositoryAccountPDA) {
      // const mint = new PublicKey("BenJy1n3WTx9mTjEvy63e8Q1j4RqUc6E4VBMz3ir4Wo6") // TODO mainnet
      const mint = new PublicKey("6QxnHc15LVbRf8nj6XToxb8RYZQi5P9QvgJ4NDW3yxRc")
      const [depositoryPDA] = PublicKey.findProgramAddressSync(
        [mint.toBuffer()], programId
      );
      setDepositoryAccountPDA(depositoryPDA)
        // Fetch initial account data
      program?.account.depository
      .fetch(depositoryPDA)
      .then(setDepository)
      .catch((error: any) => {
        console.error("Error fetching depository account:", error);
        setError("Failed to fetch depository account");
        setIsLoading(false);
      });
    }
    /*
    const subscriptionId = connection.onAccountChange(
      depositoryAccountPDA,
      handleAccountChange,
    );

    return () => {
      connection.removeAccountChangeListener(subscriptionId);
    }; */
  }, [connection, wallet, depositoryAccountPDA, program]);

  return (
    <DepositoryContext.Provider value={{ 
        depository, program, 
        depositoryAccountPDA, 
        depositoryIsLoading, 
        depositoryError }}> {children}
    </DepositoryContext.Provider>
  );
}
