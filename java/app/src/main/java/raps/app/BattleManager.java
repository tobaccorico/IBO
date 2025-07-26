package raps.app;

import android.content.Context;
import android.util.Log;
import com.google.gson.JsonObject;
import java.util.*;
import java.util.concurrent.CompletableFuture;

package raps.app;

import android.content.Context;
import android.util.Log;
import com.google.gson.JsonObject;
import java.util.*;
import java.util.concurrent.CompletableFuture;

/**
 * Enhanced BattleManager that integrates with Solana blockchain and Twitter
 */
public class BattleManager {
    private static final String TAG = "BattleManager";
    
    private final Context context;
    private final SolanaManager solanaManager;
    private final BattleIntegration battleIntegration;
    private final SpeechToTextService speechToTextService;
    private final RecordingManager recordingManager;
    private final TwitterOAuthService twitterService;
    
    // Battle state
    private BattleIntegration.BattleSession currentBattle;
    private final List<BattleStateListener> listeners;
    
    public interface BattleStateListener {
        void onBattleCreated(BattleIntegration.BattleSession battle);
        void onBattleAccepted(BattleIntegration.BattleSession battle);
        void onBattleRevealed(BattleIntegration.BattleSession battle);
        void onBattleCompleted(BattleIntegration.BattleSession battle);
        void onBattleError(String error);
        void onTwitterAuthRequired();
        void onTwitterPostSuccess(String tweetUrl);
    }
    
    public BattleManager(Context context) {
        this.context = context;
        this.listeners = new ArrayList<>();
        
        // Initialize services
        this.solanaManager = new SolanaManager(context, true); // Use localnet for dev
        this.battleIntegration = new BattleIntegration(context, solanaManager);
        this.speechToTextService = new SpeechToTextService(context);
        this.recordingManager = new RecordingManager(context);
        this.twitterService = new TwitterOAuthService(context);
    }
    
    public void addBattleStateListener(BattleStateListener listener) {
        listeners.add(listener);
    }
    
    public void removeBattleStateListener(BattleStateListener listener) {
        listeners.remove(listener);
    }
    
    /**
     * Check if user is authenticated with Twitter
     */
    public boolean isTwitterAuthenticated() {
        return twitterService.isAuthenticated();
    }
    
    /**
     * Authenticate with Twitter
     */
    public void authenticateTwitter(TwitterOAuthService.TwitterAuthCallback callback) {
        twitterService.authenticate(callback);
    }
    
    /**
     * Handle Twitter OAuth callback
     */
    public void handleTwitterCallback(android.net.Uri callbackUri, TwitterOAuthService.TwitterAuthCallback callback) {
        twitterService.handleCallback(callbackUri, callback);
    }
    
    /**
     * Initialize battle challenge flow with configuration
     */
    public CompletableFuture<Void> startBattleChallenge(BattleConfigDialog.BattleConfiguration config) {
        return CompletableFuture.runAsync(() -> {
            try {
                Log.i(TAG, "Starting battle challenge with config: " + config.challengedUser);
                
                // Check Twitter authentication
                if (!twitterService.isAuthenticated()) {
                    for (BattleStateListener listener : listeners) {
                        listener.onTwitterAuthRequired();
                    }
                    throw new RuntimeException("Twitter authentication required");
                }
                
                // Step 1: Start recording for the challenge
                String recordingPath = recordingManager.startRecording();
                
                // Wait for user to finish recording (this would be triggered by UI)
                // For now, simulate recording completion
                Thread.sleep(5000); // Simulate 5 seconds of recording
                
                recordingManager.stopRecording();
                
                // Step 2: Process recording to extract verses
                List<BattleVerse> verses = battleIntegration.processRecordingToVerses(
                    recordingPath, speechToTextService).get();
                
                if (!battleIntegration.validateBattleVerses(verses)) {
                    throw new RuntimeException("Invalid battle verses generated");
                }
                
                // Step 3: Generate hashtags from lyrics and config
                List<String> hashtags = battleIntegration.generateHashtagsFromLyrics(verses);
                hashtags.add(config.battleType.toLowerCase());
                if (config.isPublic) hashtags.add("publicbattle");
                
                // Step 4: Create battle on Solana first (to get battle ID)
                currentBattle = battleIntegration.createBattleChallenge(
                    config.challengedUser,
                    "placeholder_url", // Will update after Twitter post
                    config.stakeAmount,
                    hashtags,
                    verses,
                    recordingPath
                ).get();
                
                // Step 5: Post to Twitter with battle window info
                twitterService.postBattleChallenge(
                    config.challengedUser,
                    config.battleMessage,
                    hashtags,
                    recordingPath,
                    config.windowDurationHours,
                    new TwitterOAuthService.TwitterPostCallback() {
                        @Override
                        public void onPostSuccess(String tweetId, String tweetUrl) {
                            // Update battle with actual Twitter URL
                            updateBattleTwitterUrl(currentBattle.battleId, tweetUrl);
                            
                            for (BattleStateListener listener : listeners) {
                                listener.onBattleCreated(currentBattle);
                                listener.onTwitterPostSuccess(tweetUrl);
                            }
                            
                            Log.i(TAG, "Battle challenge created and posted to Twitter: " + tweetUrl);
                        }
                        
                        @Override
                        public void onPostError(String error) {
                            Log.e(TAG, "Failed to post to Twitter: " + error);
                            for (BattleStateListener listener : listeners) {
                                listener.onBattleError("Failed to post to Twitter: " + error);
                            }
                        }
                    }
                );
                
            } catch (Exception e) {
                Log.e(TAG, "Error starting battle challenge", e);
                for (BattleStateListener listener : listeners) {
                    listener.onBattleError("Failed to create battle: " + e.getMessage());
                }
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Accept an incoming battle challenge
     */
    public CompletableFuture<Void> acceptBattleChallenge(long battleId, String responseMessage) {
        return CompletableFuture.runAsync(() -> {
            try {
                Log.i(TAG, "Accepting battle challenge: " + battleId);
                
                // Check Twitter authentication
                if (!twitterService.isAuthenticated()) {
                    for (BattleStateListener listener : listeners) {
                        listener.onTwitterAuthRequired();
                    }
                    throw new RuntimeException("Twitter authentication required");
                }
                
                // Step 1: Start recording for response
                String recordingPath = recordingManager.startRecording();
                
                // Wait for user to finish recording
                Thread.sleep(5000); // Simulate recording
                recordingManager.stopRecording();
                
                // Step 2: Process recording to extract verses
                List<BattleVerse> verses = battleIntegration.processRecordingToVerses(
                    recordingPath, speechToTextService).get();
                
                if (!battleIntegration.validateBattleVerses(verses)) {
                    throw new RuntimeException("Invalid battle verses generated");
                }
                
                // Step 3: Accept battle on Solana
                currentBattle = battleIntegration.acceptBattleChallenge(
                    battleId,
                    "placeholder_response_url", // Will update after Twitter post
                    verses,
                    recordingPath
                ).get();
                
                // Step 4: Generate hashtags and post Twitter response
                List<String> hashtags = battleIntegration.generateHashtagsFromLyrics(verses);
                hashtags.add("battleresponse");
                hashtags.add("challengeaccepted");
                
                twitterService.postBattleResponse(
                    battleId,
                    responseMessage,
                    hashtags,
                    recordingPath,
                    extractOriginalTweetId(currentBattle.twitterUrl),
                    new TwitterOAuthService.TwitterPostCallback() {
                        @Override
                        public void onPostSuccess(String tweetId, String tweetUrl) {
                            // Update battle with response URL
                            updateBattleResponseUrl(battleId, tweetUrl);
                            
                            for (BattleStateListener listener : listeners) {
                                listener.onBattleAccepted(currentBattle);
                                listener.onTwitterPostSuccess(tweetUrl);
                            }
                            
                            Log.i(TAG, "Battle challenge accepted and posted to Twitter: " + tweetUrl);
                        }
                        
                        @Override
                        public void onPostError(String error) {
                            Log.e(TAG, "Failed to post response to Twitter: " + error);
                            for (BattleStateListener listener : listeners) {
                                listener.onBattleError("Failed to post response: " + error);
                            }
                        }
                    }
                );
                
            } catch (Exception e) {
                Log.e(TAG, "Error accepting battle challenge", e);
                for (BattleStateListener listener : listeners) {
                    listener.onBattleError("Failed to accept battle: " + e.getMessage());
                }
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Create battle configuration with current battle window
     */
    public CompletableFuture<Void> initializeBattleConfig(BattleConfigDialog.BattleConfiguration config) {
        return CompletableFuture.runAsync(() -> {
            try {
                Log.i(TAG, "Initializing battle config on Solana");
                
                // Convert timestamps to Solana slot equivalents (approximate)
                // In production, you'd want to use actual slot calculations
                long currentSlot = System.currentTimeMillis() / 400; // ~400ms per slot
                long startSlot = config.battleWindowStartTimestamp * 1000 / 400;
                long endSlot = config.battleWindowEndTimestamp * 1000 / 400;
                
                // Initialize battle config on Solana if not already done
                // This would be called once per deployment
                solanaManager.initializeBattleConfig(
                    startSlot,
                    endSlot,
                    config.stakeAmount,
                    250 // 2.5% organizer fee
                ).get();
                
                Log.i(TAG, "Battle config initialized successfully");
                
            } catch (Exception e) {
                Log.e(TAG, "Error initializing battle config", e);
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Reveal battle entry during reveal phase
     */
    public CompletableFuture<Void> revealBattleEntry() {
        return CompletableFuture.runAsync(() -> {
            try {
                if (currentBattle == null) {
                    throw new IllegalStateException("No active battle to reveal");
                }
                
                if (!currentBattle.canReveal()) {
                    throw new IllegalStateException("Battle reveal window has closed");
                }
                
                Log.i(TAG, "Revealing battle entry for battle: " + currentBattle.battleId);
                
                String txHash = battleIntegration.revealBattleEntry(currentBattle.battleId).get();
                currentBattle.revealTxHash = txHash;
                currentBattle.status = BattleIntegration.BattleStatus.REVEALED;
                
                // Notify listeners
                for (BattleStateListener listener : listeners) {
                    listener.onBattleRevealed(currentBattle);
                }
                
                Log.i(TAG, "Battle entry revealed successfully: " + txHash);
                
            } catch (Exception e) {
                Log.e(TAG, "Error revealing battle entry", e);
                for (BattleStateListener listener : listeners) {
                    listener.onBattleError("Failed to reveal battle: " + e.getMessage());
                }
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Submit a vote for a battle
     */
    public CompletableFuture<Void> submitVote(long battleId, BattleIntegration.VoteChoice vote, long stakeAmount) {
        return CompletableFuture.runAsync(() -> {
            try {
                Log.i(TAG, "Submitting vote for battle: " + battleId);
                
                String txHash = battleIntegration.submitVote(battleId, vote, stakeAmount).get();
                
                Log.i(TAG, "Vote submitted successfully: " + txHash);
                
            } catch (Exception e) {
                Log.e(TAG, "Error submitting vote", e);
                for (BattleStateListener listener : listeners) {
                    listener.onBattleError("Failed to submit vote: " + e.getMessage());
                }
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Discover battles by category
     */
    public CompletableFuture<List<BattleInfo>> discoverBattles(String category) {
        return CompletableFuture.supplyAsync(() -> {
            try {
                List<JsonObject> battles = battleIntegration.discoverBattles(category).get();
                List<BattleInfo> battleInfos = new ArrayList<>();
                
                for (JsonObject battle : battles) {
                    battleInfos.add(parseBattleInfo(battle));
                }
                
                return battleInfos;
                
            } catch (Exception e) {
                Log.e(TAG, "Error discovering battles", e);
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Get current battle information
     */
    public BattleIntegration.BattleSession getCurrentBattle() {
        return currentBattle;
    }
    
    /**
     * Check if user has an active battle
     */
    public boolean hasActiveBattle() {
        return currentBattle != null && 
               currentBattle.status != BattleIntegration.BattleStatus.COMPLETED &&
               currentBattle.status != BattleIntegration.BattleStatus.CANCELLED;
    }
    
    /**
     * Get battle status from blockchain
     */
    public CompletableFuture<BattleInfo> getBattleStatus(long battleId) {
        return CompletableFuture.supplyAsync(() -> {
            try {
                JsonObject battle = battleIntegration.getBattleInfo(battleId).get();
                return parseBattleInfo(battle);
            } catch (Exception e) {
                Log.e(TAG, "Error getting battle status", e);
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Monitor battle state changes
     */
    public void startBattleMonitoring() {
        if (currentBattle == null) return;
        
        // Monitor battle state changes on blockchain
        CompletableFuture.runAsync(() -> {
            try {
                while (hasActiveBattle()) {
                    BattleInfo info = getBattleStatus(currentBattle.battleId).get();
                    
                    // Check for state changes
                    if (info.status != currentBattle.status) {
                        updateBattleStatus(info);
                    }
                    
                    // Check for reveal deadline
                    if (currentBattle.isExpired()) {
                        handleBattleExpiration();
                        break;
                    }
                    
                    Thread.sleep(5000); // Poll every 5 seconds
                }
            } catch (Exception e) {
                Log.e(TAG, "Error monitoring battle", e);
            }
        });
    }
    
    // Private helper methods
    
    private void updateBattleTwitterUrl(long battleId, String twitterUrl) {
        // In production, this would update the battle record on Solana
        if (currentBattle != null && currentBattle.battleId == battleId) {
            currentBattle.twitterUrl = twitterUrl;
        }
    }
    
    private void updateBattleResponseUrl(long battleId, String responseUrl) {
        // In production, this would update the battle record on Solana
        if (currentBattle != null && currentBattle.battleId == battleId) {
            // Update response URL in battle data
        }
    }
    
    private String extractOriginalTweetId(String twitterUrl) {
        // Extract tweet ID from Twitter URL
        if (twitterUrl != null && twitterUrl.contains("/status/")) {
            String[] parts = twitterUrl.split("/status/");
            if (parts.length > 1) {
                return parts[1].split("[?&]")[0]; // Remove query parameters
            }
        }
        return null;
    }
    
    private void updateBattleStatus(BattleInfo info) {
        if (currentBattle == null) return;
        
        BattleIntegration.BattleStatus oldStatus = currentBattle.status;
        currentBattle.status = info.status;
        
        // Notify listeners of status change
        switch (info.status) {
            case COMPLETED:
                for (BattleStateListener listener : listeners) {
                    listener.onBattleCompleted(currentBattle);
                }
                break;
        }
        
        Log.i(TAG, "Battle status updated: " + oldStatus + " -> " + info.status);
    }
    
    private void handleBattleExpiration() {
        if (currentBattle == null) return;
        
        Log.w(TAG, "Battle has expired: " + currentBattle.battleId);
        
        for (BattleStateListener listener : listeners) {
            listener.onBattleError("Battle reveal window has expired");
        }
    }
    
    private BattleInfo parseBattleInfo(JsonObject battleJson) {
        BattleInfo info = new BattleInfo();
        
        if (battleJson.has("battle_id")) {
            info.battleId = battleJson.get("battle_id").getAsLong();
        }
        
        if (battleJson.has("challenger")) {
            info.challenger = battleJson.get("challenger").getAsString();
        }
        
        if (battleJson.has("defender")) {
            info.defender = battleJson.get("defender").getAsString();
        }
        
        if (battleJson.has("stake_amount")) {
            info.stakeAmount = battleJson.get("stake_amount").getAsLong();
        }
        
        if (battleJson.has("status")) {
            String statusStr = battleJson.get("status").getAsString();
            info.status = BattleIntegration.BattleStatus.valueOf(statusStr.toUpperCase());
        }
        
        if (battleJson.has("twitter_challenge_url")) {
            info.twitterUrl = battleJson.get("twitter_challenge_url").getAsString();
        }
        
        return info;
    }
    
    public void shutdown() {
        if (solanaManager != null) {
            solanaManager.shutdown();
        }
    }
    
    // Battle info data class
    public static class BattleInfo {
        public long battleId;
        public String challenger;
        public String defender;
        public long stakeAmount;
        public BattleIntegration.BattleStatus status;
        public String twitterUrl;
        public List<String> hashtags;
        public long createdAt;
        public long votingEndTime;
        public String winner;
    }
}
    
    public void addBattleStateListener(BattleStateListener listener) {
        listeners.add(listener);
    }
    
    public void removeBattleStateListener(BattleStateListener listener) {
        listeners.remove(listener);
    }
    
    /**
     * Initialize battle challenge flow
     */
    public CompletableFuture<Void> startBattleChallenge(String challengedUsername, long stakeAmount) {
        return CompletableFuture.runAsync(() -> {
            try {
                Log.i(TAG, "Starting battle challenge against: " + challengedUsername);
                
                // Step 1: Start recording for the challenge
                String recordingPath = recordingManager.startRecording();
                
                // Wait for user to finish recording (this would be triggered by UI)
                // For now, simulate recording completion
                Thread.sleep(5000); // Simulate 5 seconds of recording
                
                recordingManager.stopRecording();
                
                // Step 2: Process recording to extract verses
                List<BattleVerse> verses = battleIntegration.processRecordingToVerses(
                    recordingPath, speechToTextService).get();
                
                if (!battleIntegration.validateBattleVerses(verses)) {
                    throw new RuntimeException("Invalid battle verses generated");
                }
                
                // Step 3: Generate hashtags from lyrics
                List<String> hashtags = battleIntegration.generateHashtagsFromLyrics(verses);
                
                // Step 4: Create Twitter challenge post
                String twitterUrl = twitterService.createChallengePost(
                    challengedUsername, 
                    "Challenge accepted? Let's battle! #rapbattle #solana",
                    hashtags
                );
                
                // Step 5: Create battle on Solana
                currentBattle = battleIntegration.createBattleChallenge(
                    challengedUsername,
                    twitterUrl,
                    stakeAmount,
                    hashtags,
                    verses,
                    recordingPath
                ).get();
                
                // Notify listeners
                for (BattleStateListener listener : listeners) {
                    listener.onBattleCreated(currentBattle);
                }
                
                Log.i(TAG, "Battle challenge created successfully: " + currentBattle.battleId);
                
            } catch (Exception e) {
                Log.e(TAG, "Error starting battle challenge", e);
                for (BattleStateListener listener : listeners) {
                    listener.onBattleError("Failed to create battle: " + e.getMessage());
                }
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Accept an incoming battle challenge
     */
    public CompletableFuture<Void> acceptBattleChallenge(long battleId, String responseMessage) {
        return CompletableFuture.runAsync(() -> {
            try {
                Log.i(TAG, "Accepting battle challenge: " + battleId);
                
                // Step 1: Start recording for response
                String recordingPath = recordingManager.startRecording();
                
                // Wait for user to finish recording
                Thread.sleep(5000); // Simulate recording
                recordingManager.stopRecording();
                
                // Step 2: Process recording to extract verses
                List<BattleVerse> verses = battleIntegration.processRecordingToVerses(
                    recordingPath, speechToTextService).get();
                
                if (!battleIntegration.validateBattleVerses(verses)) {
                    throw new RuntimeException("Invalid battle verses generated");
                }
                
                // Step 3: Create Twitter response post
                String responseUrl = twitterService.createResponsePost(
                    battleId,
                    responseMessage,
                    battleIntegration.generateHashtagsFromLyrics(verses)
                );
                
                // Step 4: Accept battle on Solana
                currentBattle = battleIntegration.acceptBattleChallenge(
                    battleId,
                    responseUrl,
                    verses,
                    recordingPath
                ).get();
                
                // Notify listeners
                for (BattleStateListener listener : listeners) {
                    listener.onBattleAccepted(currentBattle);
                }
                
                Log.i(TAG, "Battle challenge accepted successfully");
                
            } catch (Exception e) {
                Log.e(TAG, "Error accepting battle challenge", e);
                for (BattleStateListener listener : listeners) {
                    listener.onBattleError("Failed to accept battle: " + e.getMessage());
                }
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Reveal battle entry during reveal phase
     */
    public CompletableFuture<Void> revealBattleEntry() {
        return CompletableFuture.runAsync(() -> {
            try {
                if (currentBattle == null) {
                    throw new IllegalStateException("No active battle to reveal");
                }
                
                if (!currentBattle.canReveal()) {
                    throw new IllegalStateException("Battle reveal window has closed");
                }
                
                Log.i(TAG, "Revealing battle entry for battle: " + currentBattle.battleId);
                
                String txHash = battleIntegration.revealBattleEntry(currentBattle.battleId).get();
                currentBattle.revealTxHash = txHash;
                currentBattle.status = BattleIntegration.BattleStatus.REVEALED;
                
                // Notify listeners
                for (BattleStateListener listener : listeners) {
                    listener.onBattleRevealed(currentBattle);
                }
                
                Log.i(TAG, "Battle entry revealed successfully: " + txHash);
                
            } catch (Exception e) {
                Log.e(TAG, "Error revealing battle entry", e);
                for (BattleStateListener listener : listeners) {
                    listener.onBattleError("Failed to reveal battle: " + e.getMessage());
                }
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Submit a vote for a battle
     */
    public CompletableFuture<Void> submitVote(long battleId, BattleIntegration.VoteChoice vote, long stakeAmount) {
        return CompletableFuture.runAsync(() -> {
            try {
                Log.i(TAG, "Submitting vote for battle: " + battleId);
                
                String txHash = battleIntegration.submitVote(battleId, vote, stakeAmount).get();
                
                Log.i(TAG, "Vote submitted successfully: " + txHash);
                
            } catch (Exception e) {
                Log.e(TAG, "Error submitting vote", e);
                for (BattleStateListener listener : listeners) {
                    listener.onBattleError("Failed to submit vote: " + e.getMessage());
                }
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Discover battles by category
     */
    public CompletableFuture<List<BattleInfo>> discoverBattles(String category) {
        return CompletableFuture.supplyAsync(() -> {
            try {
                List<JsonObject> battles = battleIntegration.discoverBattles(category).get();
                List<BattleInfo> battleInfos = new ArrayList<>();
                
                for (JsonObject battle : battles) {
                    battleInfos.add(parseBattleInfo(battle));
                }
                
                return battleInfos;
                
            } catch (Exception e) {
                Log.e(TAG, "Error discovering battles", e);
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Get current battle information
     */
    public BattleIntegration.BattleSession getCurrentBattle() {
        return currentBattle;
    }
    
    /**
     * Check if user has an active battle
     */
    public boolean hasActiveBattle() {
        return currentBattle != null && 
               currentBattle.status != BattleIntegration.BattleStatus.COMPLETED &&
               currentBattle.status != BattleIntegration.BattleStatus.CANCELLED;
    }
    
    /**
     * Get battle status from blockchain
     */
    public CompletableFuture<BattleInfo> getBattleStatus(long battleId) {
        return CompletableFuture.supplyAsync(() -> {
            try {
                JsonObject battle = battleIntegration.getBattleInfo(battleId).get();
                return parseBattleInfo(battle);
            } catch (Exception e) {
                Log.e(TAG, "Error getting battle status", e);
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Monitor battle state changes
     */
    public void startBattleMonitoring() {
        if (currentBattle == null) return;
        
        // Monitor battle state changes on blockchain
        CompletableFuture.runAsync(() -> {
            try {
                while (hasActiveBattle()) {
                    BattleInfo info = getBattleStatus(currentBattle.battleId).get();
                    
                    // Check for state changes
                    if (info.status != currentBattle.status) {
                        updateBattleStatus(info);
                    }
                    
                    // Check for reveal deadline
                    if (currentBattle.isExpired()) {
                        handleBattleExpiration();
                        break;
                    }
                    
                    Thread.sleep(5000); // Poll every 5 seconds
                }
            } catch (Exception e) {
                Log.e(TAG, "Error monitoring battle", e);
            }
        });
    }
    
    private void updateBattleStatus(BattleInfo info) {
        if (currentBattle == null) return;
        
        BattleIntegration.BattleStatus oldStatus = currentBattle.status;
        currentBattle.status = info.status;
        
        // Notify listeners of status change
        switch (info.status) {
            case COMPLETED:
                for (BattleStateListener listener : listeners) {
                    listener.onBattleCompleted(currentBattle);
                }
                break;
        }
        
        Log.i(TAG, "Battle status updated: " + oldStatus + " -> " + info.status);
    }
    
    private void handleBattleExpiration() {
        if (currentBattle == null) return;
        
        Log.w(TAG, "Battle has expired: " + currentBattle.battleId);
        
        for (BattleStateListener listener : listeners) {
            listener.onBattleError("Battle reveal window has expired");
        }
    }
    
    private BattleInfo parseBattleInfo(JsonObject battleJson) {
        BattleInfo info = new BattleInfo();
        
        if (battleJson.has("battle_id")) {
            info.battleId = battleJson.get("battle_id").getAsLong();
        }
        
        if (battleJson.has("challenger")) {
            info.challenger = battleJson.get("challenger").getAsString();
        }
        
        if (battleJson.has("defender")) {
            info.defender = battleJson.get("defender").getAsString();
        }
        
        if (battleJson.has("stake_amount")) {
            info.stakeAmount = battleJson.get("stake_amount").getAsLong();
        }
        
        if (battleJson.has("status")) {
            String statusStr = battleJson.get("status").getAsString();
            info.status = BattleIntegration.BattleStatus.valueOf(statusStr.toUpperCase());
        }
        
        if (battleJson.has("twitter_challenge_url")) {
            info.twitterUrl = battleJson.get("twitter_challenge_url").getAsString();
        }
        
        return info;
    }
    
    public void shutdown() {
        if (solanaManager != null) {
            solanaManager.shutdown();
        }
    }
    
    // Battle info data class
    public static class BattleInfo {
        public long battleId;
        public String challenger;
        public String defender;
        public long stakeAmount;
        public BattleIntegration.BattleStatus status;
        public String twitterUrl;
        public List<String> hashtags;
        public long createdAt;
        public long votingEndTime;
        public String winner;
    }
}