package raps.app;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.util.Log;
import org.json.JSONObject;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class TwitterIntegrationService {
    private static final String TAG = "TwitterIntegration";
    private Context context;
    private boolean isLoggedIn = false;
    private String currentUsername;
    private String accessToken;
    
    public interface TwitterCallback {
        void onLoginSuccess(String username);
        void onLoginError(String error);
        void onTweetPosted(String tweetUrl);
        void onChallengeDetected(TwitterChallenge challenge);
        void onBattleUpdated(TwitterBattle battle);
    }
    
    public TwitterIntegrationService(Context context) {
        this.context = context;
    }
    
    // Initialize Twitter OAuth flow
    public void initiateLogin(TwitterCallback callback) {
        Log.d(TAG, "Initiating Twitter login");
        
        // In a real implementation, this would use Twitter OAuth 2.0
        // For now, we'll simulate the flow
        
        Intent intent = new Intent(Intent.ACTION_VIEW, 
            Uri.parse("https://twitter.com/oauth/authorize?response_type=code&client_id=YOUR_CLIENT_ID"));
        context.startActivity(intent);
        
        // Simulate successful login after a delay
        new Thread(() -> {
            try {
                Thread.sleep(3000); // Simulate OAuth flow
                isLoggedIn = true;
                currentUsername = "demo_user"; // Would come from OAuth response
                accessToken = "demo_token";
                
                callback.onLoginSuccess(currentUsername);
            } catch (InterruptedException e) {
                callback.onLoginError("Login interrupted");
            }
        }).start();
    }
    
    // Post battle challenge to Twitter
    public void postBattleChallenge(RecordingData recording, List<AudioManager.VerseSegment> verses, 
                                   String challengedUser, TwitterCallback callback) {
        if (!isLoggedIn) {
            callback.onLoginError("Not logged in to Twitter");
            return;
        }
        
        new Thread(() -> {
            try {
                // Create challenge tweet content
                String tweetContent = createChallengeTweet(recording, verses, challengedUser);
                
                // Generate unique challenge URL for commit-reveal
                String challengeUrl = generateChallengeUrl(recording, tweetContent);
                
                // Post tweet (simulated)
                String tweetUrl = postTweet(tweetContent);
                
                if (tweetUrl != null) {
                    Log.d(TAG, "Challenge posted: " + tweetUrl);
                    
                    // Store challenge data for commit-reveal
                    TwitterChallenge challenge = new TwitterChallenge(
                        challengeUrl,
                        tweetUrl,
                        currentUsername,
                        challengedUser,
                        recording,
                        verses,
                        System.currentTimeMillis()
                    );
                    
                    saveChallengeData(challenge);
                    callback.onTweetPosted(tweetUrl);
                    
                } else {
                    callback.onLoginError("Failed to post challenge");
                }
                
            } catch (Exception e) {
                Log.e(TAG, "Error posting challenge", e);
                callback.onLoginError("Error posting challenge: " + e.getMessage());
            }
        }).start();
    }
    
    // Create challenge tweet content with verse previews
    private String createChallengeTweet(RecordingData recording, List<AudioManager.VerseSegment> verses, 
                                       String challengedUser) {
        StringBuilder tweet = new StringBuilder();
        
        // Challenge header
        tweet.append("🎤 RE-CHAT BATTLE CHALLENGE! 🔥\n");
        tweet.append("@").append(challengedUser).append(" think you can handle these bars?\n\n");
        
        // Add first verse preview (if under 140 chars)
        if (!verses.isEmpty() && verses.get(0).lyrics != null) {
            String firstVerse = verses.get(0).lyrics;
            if (firstVerse.length() <= 140) {
                tweet.append("🎯 Verse 1: ").append(firstVerse).append("\n\n");
            }
        }
        
        // Challenge footer
        tweet.append("💰 Stakes: TBD\n");
        tweet.append("⏰ 24hrs to accept\n");
        tweet.append("#ReChat #RapBattle #Web3");
        
        // Ensure tweet is under Twitter's character limit
        if (tweet.length() > 280) {
            // Truncate if too long
            String truncated = tweet.substring(0, 277) + "...";
            return truncated;
        }
        
        return tweet.toString();
    }
    
    // Generate unique challenge URL for commit-reveal mechanism
    private String generateChallengeUrl(RecordingData recording, String tweetContent) {
        // Create deterministic hash based on recording and content
        String data = recording.getId() + tweetContent + System.currentTimeMillis();
        int hash = data.hashCode();
        
        // Format as challenge URL
        return "https://rechat.app/challenge/" + Math.abs(hash);
    }
    
    // Post tweet (simulated - in real app would use Twitter API)
    private String postTweet(String content) {
        try {
            Log.d(TAG, "Posting tweet: " + content.substring(0, Math.min(50, content.length())));
            
            // Simulate API call delay
            Thread.sleep(2000);
            
            // Generate fake tweet URL
            long tweetId = System.currentTimeMillis();
            return "https://twitter.com/" + currentUsername + "/status/" + tweetId;
            
        } catch (InterruptedException e) {
            Log.e(TAG, "Tweet posting interrupted", e);
            return null;
        }
    }
    
    // Monitor Twitter for challenges mentioning current user
    public void startChallengeMonitoring(TwitterCallback callback) {
        if (!isLoggedIn) {
            Log.w(TAG, "Cannot monitor challenges - not logged in");
            return;
        }
        
        Log.d(TAG, "Starting challenge monitoring for @" + currentUsername);
        
        new Thread(() -> {
            while (isLoggedIn) {
                try {
                    // Check for new mentions (simulated)
                    List<TwitterChallenge> newChallenges = checkForNewChallenges();
                    
                    for (TwitterChallenge challenge : newChallenges) {
                        Log.d(TAG, "New challenge detected: " + challenge.getTweetUrl());
                        callback.onChallengeDetected(challenge);
                    }
                    
                    // Check every 30 seconds
                    Thread.sleep(30000);
                    
                } catch (InterruptedException e) {
                    Log.w(TAG, "Challenge monitoring interrupted", e);
                    Thread.currentThread().interrupt();
                    break;
                } catch (Exception e) {
                    Log.e(TAG, "Error in challenge monitoring", e);
                }
            }
        }).start();
    }
    
    // Check for new challenges (simulated)
    private List<TwitterChallenge> checkForNewChallenges() {
        List<TwitterChallenge> challenges = new ArrayList<>();
        
        // In real implementation, this would:
        // 1. Query Twitter API for mentions of current user
        // 2. Parse tweets for Re-Chat challenge format
        // 3. Extract challenge URLs and battle data
        // 4. Verify against blockchain contract state
        
        // For now, return empty list (no new challenges)
        return challenges;
    }
    
    // Accept a Twitter challenge
    public void acceptChallenge(TwitterChallenge challenge, TwitterCallback callback) {
        new Thread(() -> {
            try {
                // Create acceptance tweet
                String acceptanceTweet = createAcceptanceTweet(challenge);
                
                // Post acceptance
                String tweetUrl = postTweet(acceptanceTweet);
                
                if (tweetUrl != null) {
                    // Update challenge status
                    challenge.setAccepted(true);
                    challenge.setAcceptanceUrl(tweetUrl);
                    challenge.setAcceptedAt(System.currentTimeMillis());
                    
                    saveChallengeData(challenge);
                    callback.onTweetPosted(tweetUrl);
                    
                    Log.d(TAG, "Challenge accepted: " + tweetUrl);
                } else {
                    callback.onLoginError("Failed to post acceptance");
                }
                
            } catch (Exception e) {
                Log.e(TAG, "Error accepting challenge", e);
                callback.onLoginError("Error accepting challenge: " + e.getMessage());
            }
        }).start();
    }
    
    private String createAcceptanceTweet(TwitterChallenge challenge) {
        StringBuilder tweet = new StringBuilder();
        
        tweet.append("🔥 CHALLENGE ACCEPTED! 🔥\n");
        tweet.append("@").append(challenge.getChallengerUsername())
             .append(" you just awakened the beast!\n\n");
        tweet.append("💰 Stakes matched\n");
        tweet.append("⚡ Let the battle begin!\n\n");
        tweet.append("Original: ").append(challenge.getTweetUrl()).append("\n");
        tweet.append("#ReChat #RapBattle #Web3");
        
        return tweet.toString();
    }
    
    // Get current user's battle history
    public List<TwitterBattle> getBattleHistory() {
        // In real implementation, this would query stored battle data
        // and sync with blockchain contract state
        return new ArrayList<>();
    }
    
    // Post battle response with verses
    public void postBattleResponse(TwitterChallenge challenge, RecordingData response, 
                                  List<AudioManager.VerseSegment> verses, TwitterCallback callback) {
        new Thread(() -> {
            try {
                String responseTweet = createResponseTweet(challenge, response, verses);
                String tweetUrl = postTweet(responseTweet);
                
                if (tweetUrl != null) {
                    // Create battle record
                    TwitterBattle battle = new TwitterBattle(
                        challenge,
                        response,
                        verses,
                        tweetUrl,
                        System.currentTimeMillis()
                    );
                    
                    saveBattleData(battle);
                    callback.onBattleUpdated(battle);
                    
                } else {
                    callback.onLoginError("Failed to post response");
                }
                
            } catch (Exception e) {
                Log.e(TAG, "Error posting response", e);
                callback.onLoginError("Error posting response: " + e.getMessage());
            }
        }).start();
    }
    
    private String createResponseTweet(TwitterChallenge challenge, RecordingData response, 
                                      List<AudioManager.VerseSegment> verses) {
        StringBuilder tweet = new StringBuilder();
        
        tweet.append("🎤 RESPONSE DROPPED! 🔥\n");
        tweet.append("@").append(challenge.getChallengerUsername())
             .append(" here's your reality check:\n\n");
        
        // Add best verse
        if (!verses.isEmpty() && verses.get(0).lyrics != null) {
            String verse = verses.get(0).lyrics;
            if (verse.length() <= 140) {
                tweet.append("🎯 ").append(verse).append("\n\n");
            }
        }
        
        tweet.append("🏆 May the best bars win!\n");
        tweet.append("Original: ").append(challenge.getTweetUrl()).append("\n");
        tweet.append("#ReChat #RapBattle #Bars");
        
        return tweet.toString();
    }
    
    // Extract challenge data from tweet URL
    public TwitterChallenge parseChallengeFromUrl(String tweetUrl) {
        try {
            // Extract tweet ID from URL
            Pattern pattern = Pattern.compile("twitter\\.com/[^/]+/status/(\\d+)");
            Matcher matcher = pattern.matcher(tweetUrl);
            
            if (matcher.find()) {
                String tweetId = matcher.group(1);
                
                // Fetch tweet content (simulated)
                String tweetContent = fetchTweetContent(tweetId);
                
                if (tweetContent.contains("RE-CHAT BATTLE CHALLENGE")) {
                    return parseChallengeContent(tweetContent, tweetUrl);
                }
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Error parsing challenge URL", e);
        }
        
        return null;
    }
    
    private String fetchTweetContent(String tweetId) {
        // In real implementation, would use Twitter API
        // For now, return simulated content
        return "🎤 RE-CHAT BATTLE CHALLENGE! 🔥\n@opponent think you can handle these bars?";
    }
    
    private TwitterChallenge parseChallengeContent(String content, String tweetUrl) {
        // Parse challenge content to extract battle data
        // This is simplified - real implementation would be more robust
        
        Pattern userPattern = Pattern.compile("@(\\w+)");
        Matcher userMatcher = userPattern.matcher(content);
        
        String challengedUser = "";
        if (userMatcher.find()) {
            challengedUser = userMatcher.group(1);
        }
        
        return new TwitterChallenge(
            generateChallengeUrl(null, content),
            tweetUrl,
            extractUsernameFromUrl(tweetUrl),
            challengedUser,
            null, // Recording data not available from URL
            new ArrayList<>(), // Verses not available from URL
            System.currentTimeMillis()
        );
    }
    
    private String extractUsernameFromUrl(String tweetUrl) {
        Pattern pattern = Pattern.compile("twitter\\.com/([^/]+)/status");
        Matcher matcher = pattern.matcher(tweetUrl);
        
        if (matcher.find()) {
            return matcher.group(1);
        }
        
        return "unknown";
    }
    
    // Save challenge data locally
    private void saveChallengeData(TwitterChallenge challenge) {
        // In real implementation, would save to local database
        // and potentially sync with blockchain
        Log.d(TAG, "Saving challenge data: " + challenge.getChallengeUrl());
    }
    
    // Save battle data locally
    private void saveBattleData(TwitterBattle battle) {
        // In real implementation, would save to local database
        // and sync with blockchain contract
        Log.d(TAG, "Saving battle data: " + battle.getResponseUrl());
    }
    
    public boolean isLoggedIn() {
        return isLoggedIn;
    }
    
    public String getCurrentUsername() {
        return currentUsername;
    }
    
    public void logout() {
        isLoggedIn = false;
        currentUsername = null;
        accessToken = null;
        Log.d(TAG, "Logged out from Twitter");
    }
    
    public void release() {
        logout();
    }
    
    // Data classes for Twitter integration
    public static class TwitterChallenge {
        private String challengeUrl;
        private String tweetUrl;
        private String challengerUsername;
        private String challengedUsername;
        private RecordingData challengeRecording;
        private List<AudioManager.VerseSegment> verses;
        private long createdAt;
        private boolean accepted = false;
        private String acceptanceUrl;
        private long acceptedAt;
        
        public TwitterChallenge(String challengeUrl, String tweetUrl, String challengerUsername,
                               String challengedUsername, RecordingData recording,
                               List<AudioManager.VerseSegment> verses, long createdAt) {
            this.challengeUrl = challengeUrl;
            this.tweetUrl = tweetUrl;
            this.challengerUsername = challengerUsername;
            this.challengedUsername = challengedUsername;
            this.challengeRecording = recording;
            this.verses = verses;
            this.createdAt = createdAt;
        }
        
        // Getters and setters
        public String getChallengeUrl() { return challengeUrl; }
        public String getTweetUrl() { return tweetUrl; }
        public String getChallengerUsername() { return challengerUsername; }
        public String getChallengedUsername() { return challengedUsername; }
        public RecordingData getChallengeRecording() { return challengeRecording; }
        public List<AudioManager.VerseSegment> getVerses() { return verses; }
        public long getCreatedAt() { return createdAt; }
        public boolean isAccepted() { return accepted; }
        public String getAcceptanceUrl() { return acceptanceUrl; }
        public long getAcceptedAt() { return acceptedAt; }
        
        public void setAccepted(boolean accepted) { this.accepted = accepted; }
        public void setAcceptanceUrl(String url) { this.acceptanceUrl = url; }
        public void setAcceptedAt(long timestamp) { this.acceptedAt = timestamp; }
    }
    
    public static class TwitterBattle {
        private TwitterChallenge originalChallenge;
        private RecordingData responseRecording;
        private List<AudioManager.VerseSegment> responseVerses;
        private String responseUrl;
        private long respondedAt;
        private String winner; // Determined by community voting
        private boolean completed = false;
        
        public TwitterBattle(TwitterChallenge challenge, RecordingData response,
                            List<AudioManager.VerseSegment> verses, String responseUrl, long respondedAt) {
            this.originalChallenge = challenge;
            this.responseRecording = response;
            this.responseVerses = verses;
            this.responseUrl = responseUrl;
            this.respondedAt = respondedAt;
        }
        
        // Getters
        public TwitterChallenge getOriginalChallenge() { return originalChallenge; }
        public RecordingData getResponseRecording() { return responseRecording; }
        public List<AudioManager.VerseSegment> getResponseVerses() { return responseVerses; }
        public String getResponseUrl() { return responseUrl; }
        public long getRespondedAt() { return respondedAt; }
        public String getWinner() { return winner; }
        public boolean isCompleted() { return completed; }
        
        public void setWinner(String winner) { this.winner = winner; }
        public void setCompleted(boolean completed) { this.completed = completed; }
    }
}