
import { describe, it } from "node:test";
import { BN, Program } from "@coral-xyz/anchor";
import { BankrunProvider } from "anchor-bankrun";
import { TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { createAccount, createMint, mintTo } from "spl-token-bankrun";
import { PythSolanaReceiver } from "@pythnetwork/pyth-solana-receiver";
import { startAnchor, BanksClient, ProgramTestContext } from "solana-bankrun";
import { PublicKey, Keypair, Connection } from "@solana/web3.js";

// @ts-ignore
import IDL from "../target/idl/quid.json";
import { Quid } from "../target/types/quid";
import { BankrunContextWrapper } from "../bankrun-utils/bankrunConnection";

describe("Lending Smart Contract Tests", async () => {
  let signer: Keypair; let usdBankAccount: PublicKey;
  let bankrunContextWrapper: BankrunContextWrapper;
  let provider: BankrunProvider; 
  let banksClient: BanksClient;
  let context: ProgramTestContext;
  let program: Program<Quid>;
  
  // receiver program: https://docs.pyth.network/price-feeds/contract-addresses/solana
  const pyth = new PublicKey("rec5EKMGg6MxZYaMdyBfgwp4d5rB9T1VQH5pJv5LtFJ");
  const devnetConnection = new Connection("https://api.devnet.solana.com");
  const accountInfo = await devnetConnection.getAccountInfo(pyth);

  context = await startAnchor(
    "",
    [{ name: "quid", programId: new PublicKey(IDL.address) }],
    [
      {
        address: pyth,
        info: accountInfo,
      },
    ]
  );
  provider = new BankrunProvider(context);
  bankrunContextWrapper = new BankrunContextWrapper(context);
  const connection = bankrunContextWrapper.connection.toConnection();

  const pythSolanaReceiver = new PythSolanaReceiver({
    connection,
    wallet: provider.wallet,
  });
  const PRICE_FEED_ID =
    "0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2";

  const PriceFeedAccount = pythSolanaReceiver
    .getPriceFeedAccountAddress(0, PRICE_FEED_ID)
    .toBase58();

  const PriceFeedAccountPubkey = new PublicKey(PriceFeedAccount);
  const feedAccountInfo = await devnetConnection.getAccountInfo(
    PriceFeedAccountPubkey
  );
  context.setAccount(PriceFeedAccountPubkey, feedAccountInfo);

  const remainingAccounts = [
    { pubkey: PriceFeedAccountPubkey, isSigner: false, isWritable: false },
  ];

  console.log("pricefeed:", PriceFeedAccount);
  console.log("Pyth receiver Account Info:", accountInfo.data);
  
  program = new Program<Quid>(IDL as Quid, provider);
  banksClient = context.banksClient;
  signer = provider.wallet.payer;

  const mintUSD = await createMint(
    // @ts-ignore
    banksClient,
    signer,
    signer.publicKey,
    null,
    2
  );

  [usdBankAccount] = PublicKey.findProgramAddressSync(
    [Buffer.from("vault"), mintUSD.toBuffer()],
    program.programId
  );

  const [depositorPDA] = PublicKey.findProgramAddressSync(
    [provider.wallet.publicKey.toBuffer()],
    program.programId
  );
  console.log("USD Bank Account", usdBankAccount.toBase58());

  it("Create and Fund Token Account", async () => {
    const USDTokenAccount = await createAccount(
      // @ts-ignores
      banksClient,
      signer,
      mintUSD,
      signer.publicKey
    );
    console.log("USD Token Account Created:", USDTokenAccount);

    const amount = 10_000 * 10 ** 9;
    const mintUSDTx = await mintTo(
      // @ts-ignores
      banksClient,
      signer,
      mintUSD,
      USDTokenAccount,
      signer,
      amount
    );
    console.log("Mint to USD Bank Signature:", mintUSDTx);
  });

  it("Test Deposit", async () => {
    const depositUSDstar = await program.methods
      .deposit(new BN(100000000), "")
      .accounts({
        signer: signer.publicKey,
        mint: mintUSD,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .rpc({ commitment: "confirmed" });

    const depositUSD = await program.methods
      .deposit(new BN(100000000), "XAU")
      .accounts({
        signer: signer.publicKey,
        mint: mintUSD,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .rpc({ commitment: "confirmed" });

    console.log("Deposit USD to exposure", depositUSD);
    console.log("Deposit USD to deposit", depositUSDstar);
  });

  /* This works! 
  it("Test Withdraw Deposit", async () => {
    const withdrawUSD = await program.methods
      .withdraw(new BN(-200000000), "", true)
      .accounts({
        signer: signer.publicKey,
        mint: mintUSD,
        tokenProgram: TOKEN_PROGRAM_ID,
      }).remainingAccounts(remainingAccounts)
      .rpc({ commitment: "confirmed" });

    console.log("Withdraw USD", withdrawUSD);
  }); */

  it("Test Withdraw Exposure", async () => {
    const withdrawUSD = await program.methods
      .withdraw(new BN(90000000), "XAU", true)
      .accounts({
        signer: signer.publicKey,
        mint: mintUSD,
        tokenProgram: TOKEN_PROGRAM_ID,
      }).remainingAccounts(remainingAccounts)
      .rpc({ commitment: "confirmed" });
      
    console.log("Withdraw USD", withdrawUSD);
    const accountInfo = await banksClient.getAccount(depositorPDA);
    if (!accountInfo) {
      console.error("Depositor account not found");
    } else {
      const decoded = program.coder.accounts.decode(
        "depositor", Buffer.from(accountInfo.data));
    }
  });
});
