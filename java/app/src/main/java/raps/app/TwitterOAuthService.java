package raps.app;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.util.Log;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import okhttp3.*;
import oauth.signpost.OAuthConsumer;
import oauth.signpost.OAuthProvider;
import oauth.signpost.basic.DefaultOAuthConsumer;
import oauth.signpost.basic.DefaultOAuthProvider;
import oauth.signpost.exception.OAuthException;
import se.akerfeldt.okhttp.signpost.OkHttpOAuthConsumer;
import se.akerfeldt.okhttp.signpost.SigningInterceptor;

import java.io.IOException;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

public class TwitterOAuthService {
    private static final String TAG = "TwitterOAuthService";
    
    // Twitter API v2 OAuth 2.0 endpoints
    private static final String TWITTER_API_BASE = "https://api.twitter.com/2/";
    private static final String TWITTER_OAUTH_BASE = "https://api.twitter.com/oauth/";
    private static final String REQUEST_TOKEN_URL = TWITTER_OAUTH_BASE + "request_token";
    private static final String ACCESS_TOKEN_URL = TWITTER_OAUTH_BASE + "access_token";
    private static final String AUTHORIZE_URL = TWITTER_OAUTH_BASE + "authorize";
    
    // Twitter API endpoints
    private static final String TWEET_ENDPOINT = TWITTER_API_BASE + "tweets";
    private static final String UPLOAD_MEDIA_ENDPOINT = "https://upload.twitter.com/1.1/media/upload.json";
    
    // OAuth credentials (replace with your actual credentials)
    private static final String CONSUMER_KEY = "your_twitter_consumer_key";
    private static final String CONSUMER_SECRET = "your_twitter_consumer_secret";
    private static final String CALLBACK_URL = "rapsapp://twitter_callback";
    
    private final Context context;
    private final SharedPreferences preferences;
    private final OkHttpClient httpClient;
    
    private OAuthConsumer consumer;
    private OAuthProvider provider;
    private String accessToken;
    private String accessTokenSecret;
    
    public interface TwitterAuthCallback {
        void onAuthSuccess(String username, String userId);
        void onAuthError(String error);
    }
    
    public interface TwitterPostCallback {
        void onPostSuccess(String tweetId, String tweetUrl);
        void onPostError(String error);
    }
    
    public TwitterOAuthService(Context context) {
        this.context = context;
        this.preferences = context.getSharedPreferences("twitter_auth", Context.MODE_PRIVATE);
        
        // Setup OkHttp client with OAuth signing
        this.consumer = new OkHttpOAuthConsumer(CONSUMER_KEY, CONSUMER_SECRET);
        this.provider = new DefaultOAuthProvider(REQUEST_TOKEN_URL, ACCESS_TOKEN_URL, AUTHORIZE_URL);
        
        this.httpClient = new OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .addInterceptor(new SigningInterceptor(consumer))
            .addInterceptor(new HttpLoggingInterceptor().setLevel(HttpLoggingInterceptor.Level.BODY))
            .build();
        
        // Load saved tokens
        loadSavedTokens();
    }
    
    /**
     * Check if user is already authenticated
     */
    public boolean isAuthenticated() {
        return accessToken != null && accessTokenSecret != null && 
               !accessToken.isEmpty() && !accessTokenSecret.isEmpty();
    }
    
    /**
     * Get stored username
     */
    public String getUsername() {
        return preferences.getString("username", "");
    }
    
    /**
     * Start OAuth authentication flow
     */
    public void authenticate(TwitterAuthCallback callback) {
        CompletableFuture.runAsync(() -> {
            try {
                Log.i(TAG, "Starting Twitter OAuth authentication");
                
                // Step 1: Get request token
                String authUrl = provider.retrieveRequestToken(consumer, CALLBACK_URL);
                
                // Step 2: Open Twitter authorization in browser
                Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(authUrl));
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(intent);
                
                // The callback will be handled in MainActivity when user returns
                Log.i(TAG, "Opened Twitter authorization URL: " + authUrl);
                
            } catch (OAuthException e) {
                Log.e(TAG, "OAuth error during authentication", e);
                callback.onAuthError("OAuth error: " + e.getMessage());
            }
        });
    }
    
    /**
     * Complete OAuth flow with callback data
     */
    public void handleCallback(Uri callbackUri, TwitterAuthCallback callback) {
        CompletableFuture.runAsync(() -> {
            try {
                String verifier = callbackUri.getQueryParameter("oauth_verifier");
                if (verifier == null) {
                    callback.onAuthError("Authorization cancelled or failed");
                    return;
                }
                
                Log.i(TAG, "Completing OAuth with verifier: " + verifier);
                
                // Step 3: Exchange request token for access token
                provider.retrieveAccessToken(consumer, verifier);
                
                accessToken = consumer.getToken();
                accessTokenSecret = consumer.getTokenSecret();
                
                // Save tokens
                saveTokens();
                
                // Get user info
                getUserInfo(callback);
                
            } catch (OAuthException e) {
                Log.e(TAG, "Error completing OAuth", e);
                callback.onAuthError("Failed to complete authentication: " + e.getMessage());
            }
        });
    }
    
    /**
     * Post a battle challenge tweet with media
     */
    public void postBattleChallenge(
            String challengedUser, 
            String battleText, 
            List<String> hashtags,
            String audioFilePath,
            long battleWindowHours,
            TwitterPostCallback callback) {
        
        if (!isAuthenticated()) {
            callback.onPostError("Not authenticated with Twitter");
            return;
        }
        
        CompletableFuture.runAsync(() -> {
            try {
                Log.i(TAG, "Posting battle challenge to Twitter");
                
                // Step 1: Upload audio media (if provided)
                String mediaId = null;
                if (audioFilePath != null && !audioFilePath.isEmpty()) {
                    mediaId = uploadMedia(audioFilePath);
                }
                
                // Step 2: Compose tweet text
                StringBuilder tweetText = new StringBuilder();
                tweetText.append("🎤 RAP BATTLE CHALLENGE 🎤\n\n");
                tweetText.append("@").append(challengedUser).append(" you've been challenged!\n\n");
                tweetText.append(battleText).append("\n\n");
                tweetText.append("⏰ Battle Window: ").append(battleWindowHours).append(" hours\n");
                tweetText.append("💰 Stake your claim on Solana\n\n");
                
                // Add hashtags
                for (String hashtag : hashtags) {
                    if (!hashtag.startsWith("#")) hashtag = "#" + hashtag;
                    tweetText.append(hashtag).append(" ");
                }
                
                tweetText.append("\n\n#SolanaBattles #RapBattle #Web3Music");
                
                // Step 3: Post tweet
                String tweetId = postTweet(tweetText.toString(), mediaId);
                String tweetUrl = "https://twitter.com/user/status/" + tweetId;
                
                Log.i(TAG, "Battle challenge posted successfully: " + tweetUrl);
                callback.onPostSuccess(tweetId, tweetUrl);
                
            } catch (Exception e) {
                Log.e(TAG, "Error posting battle challenge", e);
                callback.onPostError("Failed to post challenge: " + e.getMessage());
            }
        });
    }
    
    /**
     * Post a battle response tweet
     */
    public void postBattleResponse(
            long battleId,
            String responseText,
            List<String> hashtags,
            String audioFilePath,
            String originalTweetId,
            TwitterPostCallback callback) {
        
        if (!isAuthenticated()) {
            callback.onPostError("Not authenticated with Twitter");
            return;
        }
        
        CompletableFuture.runAsync(() -> {
            try {
                Log.i(TAG, "Posting battle response to Twitter");
                
                // Upload audio media
                String mediaId = null;
                if (audioFilePath != null && !audioFilePath.isEmpty()) {
                    mediaId = uploadMedia(audioFilePath);
                }
                
                // Compose response tweet
                StringBuilder tweetText = new StringBuilder();
                tweetText.append("🔥 BATTLE RESPONSE 🔥\n\n");
                tweetText.append("Challenge ACCEPTED! ").append(responseText).append("\n\n");
                tweetText.append("Battle ID: #").append(battleId).append("\n");
                tweetText.append("Let's settle this on-chain! 💀\n\n");
                
                // Add hashtags
                for (String hashtag : hashtags) {
                    if (!hashtag.startsWith("#")) hashtag = "#" + hashtag;
                    tweetText.append(hashtag).append(" ");
                }
                
                // Post as reply to original tweet
                String tweetId = postReply(tweetText.toString(), mediaId, originalTweetId);
                String tweetUrl = "https://twitter.com/user/status/" + tweetId;
                
                Log.i(TAG, "Battle response posted successfully: " + tweetUrl);
                callback.onPostSuccess(tweetId, tweetUrl);
                
            } catch (Exception e) {
                Log.e(TAG, "Error posting battle response", e);
                callback.onPostError("Failed to post response: " + e.getMessage());
            }
        });
    }
    
    /**
     * Upload media file to Twitter
     */
    private String uploadMedia(String filePath) throws IOException {
        Log.i(TAG, "Uploading media file: " + filePath);
        
        RequestBody fileBody = RequestBody.create(
            new java.io.File(filePath), 
            MediaType.parse("audio/mpeg")
        );
        
        RequestBody requestBody = new MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("media", "battle_audio.mp3", fileBody)
            .addFormDataPart("media_category", "tweet_audio")
            .build();
        
        Request request = new Request.Builder()
            .url(UPLOAD_MEDIA_ENDPOINT)
            .post(requestBody)
            .build();
        
        try (Response response = httpClient.newCall(request).execute()) {
            if (!response.isSuccessful()) {
                throw new IOException("Failed to upload media: " + response.code());
            }
            
            String responseBody = response.body().string();
            JsonObject json = JsonParser.parseString(responseBody).getAsJsonObject();
            
            return json.get("media_id_string").getAsString();
        }
    }
    
    /**
     * Post a tweet with optional media
     */
    private String postTweet(String text, String mediaId) throws IOException {
        JsonObject tweetData = new JsonObject();
        tweetData.addProperty("text", text);
        
        if (mediaId != null) {
            JsonObject media = new JsonObject();
            media.addProperty("media_id", mediaId);
            tweetData.add("media", media);
        }
        
        RequestBody body = RequestBody.create(
            tweetData.toString(), 
            MediaType.parse("application/json")
        );
        
        Request request = new Request.Builder()
            .url(TWEET_ENDPOINT)
            .post(body)
            .addHeader("Content-Type", "application/json")
            .build();
        
        try (Response response = httpClient.newCall(request).execute()) {
            if (!response.isSuccessful()) {
                throw new IOException("Failed to post tweet: " + response.code());
            }
            
            String responseBody = response.body().string();
            JsonObject json = JsonParser.parseString(responseBody).getAsJsonObject();
            JsonObject data = json.getAsJsonObject("data");
            
            return data.get("id").getAsString();
        }
    }
    
    /**
     * Post a reply tweet
     */
    private String postReply(String text, String mediaId, String replyToTweetId) throws IOException {
        JsonObject tweetData = new JsonObject();
        tweetData.addProperty("text", text);
        
        // Add reply reference
        JsonObject reply = new JsonObject();
        reply.addProperty("in_reply_to_tweet_id", replyToTweetId);
        tweetData.add("reply", reply);
        
        if (mediaId != null) {
            JsonObject media = new JsonObject();
            media.addProperty("media_id", mediaId);
            tweetData.add("media", media);
        }
        
        RequestBody body = RequestBody.create(
            tweetData.toString(), 
            MediaType.parse("application/json")
        );
        
        Request request = new Request.Builder()
            .url(TWEET_ENDPOINT)
            .post(body)
            .addHeader("Content-Type", "application/json")
            .build();
        
        try (Response response = httpClient.newCall(request).execute()) {
            if (!response.isSuccessful()) {
                throw new IOException("Failed to post reply: " + response.code());
            }
            
            String responseBody = response.body().string();
            JsonObject json = JsonParser.parseString(responseBody).getAsJsonObject();
            JsonObject data = json.getAsJsonObject("data");
            
            return data.get("id").getAsString();
        }
    }
    
    /**
     * Get authenticated user info
     */
    private void getUserInfo(TwitterAuthCallback callback) {
        try {
            Request request = new Request.Builder()
                .url("https://api.twitter.com/2/users/me")
                .get()
                .build();
            
            try (Response response = httpClient.newCall(request).execute()) {
                if (!response.isSuccessful()) {
                    callback.onAuthError("Failed to get user info: " + response.code());
                    return;
                }
                
                String responseBody = response.body().string();
                JsonObject json = JsonParser.parseString(responseBody).getAsJsonObject();
                JsonObject data = json.getAsJsonObject("data");
                
                String username = data.get("username").getAsString();
                String userId = data.get("id").getAsString();
                
                // Save user info
                preferences.edit()
                    .putString("username", username)
                    .putString("user_id", userId)
                    .apply();
                
                Log.i(TAG, "Authentication successful for user: " + username);
                callback.onAuthSuccess(username, userId);
            }
            
        } catch (IOException e) {
            Log.e(TAG, "Error getting user info", e);
            callback.onAuthError("Failed to get user info: " + e.getMessage());
        }
    }
    
    /**
     * Save OAuth tokens
     */
    private void saveTokens() {
        preferences.edit()
            .putString("access_token", accessToken)
            .putString("access_token_secret", accessTokenSecret)
            .apply();
        
        Log.i(TAG, "OAuth tokens saved");
    }
    
    /**
     * Load saved OAuth tokens
     */
    private void loadSavedTokens() {
        accessToken = preferences.getString("access_token", null);
        accessTokenSecret = preferences.getString("access_token_secret", null);
        
        if (accessToken != null && accessTokenSecret != null) {
            consumer.setTokenWithSecret(accessToken, accessTokenSecret);
            Log.i(TAG, "Loaded saved OAuth tokens");
        }
    }
    
    /**
     * Clear authentication
     */
    public void logout() {
        preferences.edit().clear().apply();
        accessToken = null;
        accessTokenSecret = null;
        Log.i(TAG, "Twitter authentication cleared");
    }
}