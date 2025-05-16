
import React, {createContext, useContext, useEffect, useState, useCallback } from "react";
import { useConnection, useWallet } from "@solana/wallet-adapter-react";
import { useDepository } from "./DepositoryProvider";
import { AccountInfo, PublicKey } from "@solana/web3.js";
import { IdlAccounts } from "@coral-xyz/anchor";
import type { Quid } from "../anchor/idlTypes";
import { Buffer } from 'buffer';
  
export type DepositorAccount = IdlAccounts<Quid>["depositor"];

// Shared state for program collateral accounts
interface DepositorContextType {
  depositor: DepositorAccount | null;
  depositorAccountPDA: PublicKey | null;
  allDepositorAccounts: { publicKey: PublicKey; account: DepositorAccount }[];
  depositorIsLoading: boolean;
  depositorError: string | null;
  fetchAllDepositorAccounts: (force: boolean) => Promise<void>;
  refetchDepositorAccount: (pubkey: PublicKey) => Promise<void>;
}

const DepositorContext = createContext<DepositorContextType | undefined>(
  undefined,
);

export function useDepositor() {
  const context = useContext(DepositorContext);
  if (context === undefined) {
    throw new Error("useDepositor must be used within a DepositorProvider");
  }
  return context;
}

export function DepositorProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  const wallet = useWallet();
  const { connection } = useConnection();
  const { program } = useDepository();

  const [depositor, setDepositor] = useState<DepositorAccount | null>(null);
  const [depositorAccountPDA, setDepositorAccountPDA] =
    useState<PublicKey | null>(null);
  const [allDepositorAccounts, setAllDepositorAccounts] = useState<
    { publicKey: PublicKey; account: DepositorAccount }[]
  >([]);
  const [depositorIsLoading, setIsLoading] = useState(true);
  const [depositorError, setError] = useState<string | null>(null);

  /*
  const handleAccountChange = (accountInfo: AccountInfo<Buffer>) => {
    try {
      if (program != null) {
        const decodedData = program.coder.accounts.decode(
          "depositor",
          accountInfo.data,
        ) as DepositorAccount;
        setDepositor(decodedData);
        setError(null);
      } 
    } catch (error) {
      console.error("Error decoding collateral account data:", error);
      setError("Failed to decode collateral account data");
    } finally {
      setIsLoading(false);
    }
  }; */

  const fetchAllDepositorAccounts = async (force: boolean) => {
    try {
      if (program != null && (
        force || allDepositorAccounts == null)) {
        await program.account.depositor.all().then((data: { publicKey: PublicKey; account: DepositorAccount }[]) => {
          setAllDepositorAccounts(data);
          setError(null);
        })
      } 
    } catch (error) {
      console.error("Error fetching all deposit accounts:", error);
      setError("Failed to fetch all collateral accounts");
    }
  };
  
  const refetchDepositorAccount = useCallback(async (pubkey: PublicKey) => {
    try {
      const index = allDepositorAccounts.findIndex((a) => a.account.owner.equals(pubkey));
      let account;
      if (index !== -1 && program != null) {
        let key = allDepositorAccounts[index].publicKey;
        account = await program.account.depositor.fetch(key)
        const newAccounts = [...allDepositorAccounts];
        newAccounts[index] = { publicKey: key, account };
        console.log("PDA22", key)
        console.log("deposited22", account.depositedUsdStar.toString())
        setAllDepositorAccounts(newAccounts);
      } else if (program != null) {
        const [depositorPDA] = PublicKey.findProgramAddressSync(
          [pubkey.toBuffer()],
          program.programId,
        );
        account = await program.account.depositor.fetch(depositorPDA)
        setDepositor(account as DepositorAccount)
        console.log("PDA11", depositorPDA)
        console.log("deposited11", account.balances[0].toString())
        const newAccounts = [...allDepositorAccounts, 
          { publicKey: depositorPDA, account }];
        setAllDepositorAccounts(newAccounts);
      }
    } catch (error) {
      console.error("Error refetching collateral account:", error);
    }
  }, [allDepositorAccounts, program, setAllDepositorAccounts, setError]);

  useEffect(() => {
    if (!wallet.connected 
      || !wallet.publicKey 
      || !wallet.signTransaction
      || !wallet.signAllTransactions
      || !program) {
      /* setDepositor(null);
      setDepositorAccountPDA(null);
      setAllDepositorAccounts([]);
      setIsLoading(false);
      setError(null); */
      return;
    }
  
    // Fetch all collateral accounts
    fetchAllDepositorAccounts(false);
    if (!depositorAccountPDA) {
      setIsLoading(true);
      const [depositorPDA] = PublicKey.findProgramAddressSync(
        [wallet.publicKey.toBuffer()],
        program.programId,
      );
      console.log("depositorPDA", depositorPDA.toString())
      setDepositorAccountPDA(depositorPDA);
      
      // Fetch initial account data
      program.account.depositor
        .fetch(depositorPDA)
        .then((data: DepositorAccount) => {
          setDepositor(data);
          setError(null);
        })
        .catch((error: any) => {
          if (error.message.includes("Account does not exist")) {
            setDepositor(null);
            setError(null);
          } else {
            console.error("Error fetching account:", error);
            setError("Failed to fetch account");
          }
        })
        .finally(() => setIsLoading(false)); 
    }
    /*
    // Subscribe to account changes
    const subscriptionId = connection.onAccountChange(
      depositorAccountPDA,
      handleAccountChange,
    );

    return () => {
      connection.removeAccountChangeListener(subscriptionId);
    }; */
  }, [connection, program, setDepositor, setError,
    setDepositorAccountPDA, setIsLoading, wallet, 
    depositorAccountPDA, setAllDepositorAccounts,
    fetchAllDepositorAccounts]);

  return (
    <DepositorContext.Provider
      value={{ depositor,
        depositorAccountPDA,
        allDepositorAccounts,
        depositorIsLoading,
        depositorError,
        fetchAllDepositorAccounts,
        refetchDepositorAccount,
      }}> {children}
    </DepositorContext.Provider>
  );
}
