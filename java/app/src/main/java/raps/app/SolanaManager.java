package com.quid.mobile.solana;

import android.content.Context;
import android.net.Uri;

import com.solana.api.Connection;
import com.solana.core.PublicKey;
import com.solana.core.Transaction;
import com.solana.mobilewalletadapter.clientlib.*;
import com.solana.networking.HttpNetworkingRouter;
import com.solana.networking.RPCEndpoint;

import java.util.concurrent.CompletableFuture;

import javax.inject.Inject;
import javax.inject.Singleton;

@Singleton
public class SolanaManager {

    private final Context context;
    private final MobileWalletAdapter walletAdapter;
    private final Connection connection;
    private final PublicKey quidProgramId;
    private final PublicKey rapsProgramId;

    private WalletState walletState;
    private PublicKey userPublicKey;

    public enum WalletState {
        DISCONNECTED,
        CONNECTING,
        CONNECTED,
        ERROR
    }

    @Inject
    public SolanaManager(Context context) {
        this.context = context;

        this.walletAdapter = new MobileWalletAdapter(
            "Quid Battle Protocol",
            Uri.parse("https://quid.battle"),
            Uri.parse("https://quid.battle/icon.png"),
            RpcCluster.Devnet
        );

        RPCEndpoint rpcEndpoint = "mainnet".equals(BuildConfig.NETWORK)
            ? RPCEndpoint.mainnetBetaSolana
            : RPCEndpoint.devnetSolana;

        this.connection = new Connection(new HttpNetworkingRouter(rpcEndpoint));
        this.quidProgramId = new PublicKey("QgV3iN5rSkBU8jaZy8AszQt5eoYwKLmBgXEK5cehAKX");
        this.rapsProgramId = new PublicKey("ReChatBattleContract1234567890123456789012345678");
        this.walletState = WalletState.DISCONNECTED;
    }

    public void connectWallet() {
        walletState = WalletState.CONNECTING;

        walletAdapter.connect(context, authResult -> {
            if (authResult instanceof AuthorizationResult.Success) {
                AuthorizationResult.Success success = (AuthorizationResult.Success) authResult;
                userPublicKey = new PublicKey(success.getPublicKey());
                walletState = WalletState.CONNECTED;
            } else if (authResult instanceof AuthorizationResult.Failure) {
                walletState = WalletState.ERROR;
            }
        });
    }

    public void disconnectWallet() {
        walletAdapter.disconnect();
        userPublicKey = null;
        walletState = WalletState.DISCONNECTED;
    }

    public CompletableFuture<String> signAndSendTransaction(Transaction transaction) {
        CompletableFuture<String> future = new CompletableFuture<>();

        connection.getRecentBlockhash(result -> {
            transaction.setRecentBlockhash(result.blockhash);

            walletAdapter.signAndSendTransaction(context, transaction, txResult -> {
                if (txResult instanceof SignAndSendTransactionResult.Success) {
                    future.complete(((SignAndSendTransactionResult.Success) txResult).getSignature());
                } else {
                    future.completeExceptionally(
                        new Exception("Transaction failed")
                    );
                }
            });
        });

        return future;
    }

    public CompletableFuture<byte[]> signMessage(String message) {
        CompletableFuture<byte[]> future = new CompletableFuture<>();

        walletAdapter.signMessage(context, message.getBytes(), result -> {
            if (result instanceof SignMessageResult.Success) {
                future.complete(((SignMessageResult.Success) result).getSignature());
            } else {
                future.completeExceptionally(
                    new Exception("Signing failed")
                );
            }
        });

        return future;
    }

    public boolean isConnected() {
        return walletState == WalletState.CONNECTED;
    }

    public PublicKey requireConnection() {
        if (userPublicKey == null) {
            throw new IllegalStateException("Wallet not connected");
        }
        return userPublicKey;
    }

    public void cleanup() {
        walletAdapter.disconnect();
    }
}
