package raps.app;

import android.content.Context;
import android.util.Log;
import com.google.gson.JsonObject;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.CompletableFuture;

public class BattleIntegration {
    private static final String TAG = "BattleIntegration";
    
    private final SolanaManager solanaManager;
    private final Context context;
    private final SecureRandom random;
    
    // Battle state tracking
    private final Map<Long, BattleSession> activeBattles;
    
    public BattleIntegration(Context context, SolanaManager solanaManager) {
        this.context = context;
        this.solanaManager = solanaManager;
        this.random = new SecureRandom();
        this.activeBattles = new HashMap<>();
    }
    
    /**
     * Create a new battle challenge with commit-reveal scheme
     */
    public CompletableFuture<BattleSession> createBattleChallenge(
            String challengedUsername,
            String twitterChallengeUrl,
            long stakeAmount,
            List<String> hashtags,
            List<BattleVerse> preparedVerses,
            String recordingUri) {
        
        return CompletableFuture.supplyAsync(() -> {
            try {
                // Generate commit hash for verses
                long nonce = random.nextLong();
                String commitHash = generateCommitHash(preparedVerses, recordingUri, nonce);
                
                // Create battle session
                BattleSession session = new BattleSession();
                session.challengedUser = challengedUsername;
                session.twitterUrl = twitterChallengeUrl;
                session.stakeAmount = stakeAmount;
                session.hashtags = hashtags;
                session.preparedVerses = preparedVerses;
                session.recordingUri = recordingUri;
                session.nonce = nonce;
                session.commitHash = commitHash;
                session.isChallenger = true;
                
                // Send transaction to Solana
                String txHash = solanaManager.createBattleChallenge(
                    challengedUsername, 
                    twitterChallengeUrl, 
                    stakeAmount, 
                    hashtags, 
                    commitHash
                ).get();
                
                session.creationTxHash = txHash;
                session.status = BattleStatus.PENDING_ACCEPTANCE;
                
                // Store session
                activeBattles.put(session.battleId, session);
                
                Log.i(TAG, "Battle challenge created: " + txHash);
                return session;
                
            } catch (Exception e) {
                Log.e(TAG, "Error creating battle challenge", e);
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Accept an existing battle challenge
     */
    public CompletableFuture<BattleSession> acceptBattleChallenge(
            long battleId,
            String responseUrl,
            List<BattleVerse> preparedVerses,
            String recordingUri) {
        
        return CompletableFuture.supplyAsync(() -> {
            try {
                // Generate commit hash for defender verses
                long nonce = random.nextLong();
                String commitHash = generateCommitHash(preparedVerses, recordingUri, nonce);
                
                // Create battle session as defender
                BattleSession session = new BattleSession();
                session.battleId = battleId;
                session.preparedVerses = preparedVerses;
                session.recordingUri = recordingUri;
                session.nonce = nonce;
                session.commitHash = commitHash;
                session.isChallenger = false;
                
                // Send acceptance transaction
                String txHash = solanaManager.acceptBattleChallenge(
                    battleId, 
                    responseUrl, 
                    commitHash
                ).get();
                
                session.acceptanceTxHash = txHash;
                session.status = BattleStatus.MATCHED;
                
                // Store session
                activeBattles.put(battleId, session);
                
                Log.i(TAG, "Battle challenge accepted: " + txHash);
                return session;
                
            } catch (Exception e) {
                Log.e(TAG, "Error accepting battle challenge", e);
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Reveal battle entry during reveal phase
     */
    public CompletableFuture<String> revealBattleEntry(long battleId) {
        return CompletableFuture.supplyAsync(() -> {
            try {
                BattleSession session = activeBattles.get(battleId);
                if (session == null) {
                    throw new IllegalStateException("No active battle session found for ID: " + battleId);
                }
                
                // Send reveal transaction
                String txHash = solanaManager.revealBattleEntry(
                    battleId,
                    session.preparedVerses,
                    session.recordingUri,
                    session.nonce
                ).get();
                
                session.revealTxHash = txHash;
                session.status = BattleStatus.REVEALED;
                
                Log.i(TAG, "Battle entry revealed: " + txHash);
                return txHash;
                
            } catch (Exception e) {
                Log.e(TAG, "Error revealing battle entry", e);
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Submit a community vote
     */
    public CompletableFuture<String> submitVote(long battleId, VoteChoice vote, long stakeAmount) {
        return CompletableFuture.supplyAsync(() -> {
            try {
                int voteValue = vote == VoteChoice.CHALLENGER ? 0 : 
                               vote == VoteChoice.DEFENDER ? 1 : 2;
                
                String txHash = solanaManager.submitVote(battleId, voteValue, stakeAmount).get();
                
                Log.i(TAG, "Vote submitted: " + txHash);
                return txHash;
                
            } catch (Exception e) {
                Log.e(TAG, "Error submitting vote", e);
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Get battle information from blockchain
     */
    public CompletableFuture<JsonObject> getBattleInfo(long battleId) {
        return solanaManager.getBattleAccount(battleId);
    }
    
    /**
     * Get battles by category for discovery
     */
    public CompletableFuture<List<JsonObject>> discoverBattles(String category) {
        return solanaManager.getBattlesByCategory(category);
    }
    
    /**
     * Process recording with speech-to-text to create battle verses
     */
    public CompletableFuture<List<BattleVerse>> processRecordingToVerses(
            String audioFilePath, 
            SpeechToTextService speechService) {
        
        return CompletableFuture.supplyAsync(() -> {
            try {
                // Get transcription with timestamps
                List<WordTimestamp> transcription = speechService.transcribeWithTimestamps(audioFilePath);
                
                // Group words into verses (sentences or natural breaks)
                List<BattleVerse> verses = new ArrayList<>();
                List<WordTimestamp> currentVerse = new ArrayList<>();
                
                for (WordTimestamp word : transcription) {
                    currentVerse.add(word);
                    
                    // End verse on sentence endings or after certain duration
                    if (word.getWord().endsWith(".") || word.getWord().endsWith("!") || 
                        word.getWord().endsWith("?") || currentVerse.size() >= 20) {
                        
                        if (!currentVerse.isEmpty()) {
                            verses.add(createVerseFromWords(verses.size() + 1, currentVerse));
                            currentVerse.clear();
                        }
                    }
                }
                
                // Add remaining words as final verse
                if (!currentVerse.isEmpty()) {
                    verses.add(createVerseFromWords(verses.size() + 1, currentVerse));
                }
                
                return verses;
                
            } catch (Exception e) {
                Log.e(TAG, "Error processing recording to verses", e);
                throw new RuntimeException(e);
            }
        });
    }
    
    /**
     * Generate hashtags from lyrics using basic NLP
     */
    public List<String> generateHashtagsFromLyrics(List<BattleVerse> verses) {
        Set<String> hashtags = new HashSet<>();
        
        // Combine all lyrics
        StringBuilder allLyrics = new StringBuilder();
        for (BattleVerse verse : verses) {
            allLyrics.append(verse.getLyrics()).append(" ");
        }
        
        String lyrics = allLyrics.toString().toLowerCase();
        
        // Add basic music-related hashtags based on content
        if (lyrics.contains("rap") || lyrics.contains("rhyme")) {
            hashtags.add("rapbattle");
            hashtags.add("hiphop");
        }
        if (lyrics.contains("freestyle")) hashtags.add("freestyle");
        if (lyrics.contains("beat")) hashtags.add("beatbattle");
        if (lyrics.contains("bars")) hashtags.add("bars");
        if (lyrics.contains("flow")) hashtags.add("spitfire");
        
        // Add skill level indicators
        if (lyrics.contains("professional") || lyrics.contains("expert")) {
            hashtags.add("professional");
        }
        if (lyrics.contains("beginner") || lyrics.contains("learning")) {
            hashtags.add("beginner");
        }
        
        // Add general battle tag
        hashtags.add("battle");
        hashtags.add("cypher");
        
        return new ArrayList<>(hashtags);
    }
    
    /**
     * Validate battle verses before submission
     */
    public boolean validateBattleVerses(List<BattleVerse> verses) {
        if (verses == null || verses.isEmpty() || verses.size() > 4) {
            return false;
        }
        
        for (BattleVerse verse : verses) {
            if (!verse.isValid()) {
                return false;
            }
        }
        
        return true;
    }
    
    // Private helper methods
    
    private String generateCommitHash(List<BattleVerse> verses, String recordingUri, long nonce) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            
            // Add verse data
            for (BattleVerse verse : verses) {
                digest.update(verse.getLyrics().getBytes());
                digest.update(longToBytes(verse.getStartTime()));
                digest.update(longToBytes(verse.getEndTime()));
            }
            
            // Add recording URI and nonce
            digest.update(recordingUri.getBytes());
            digest.update(longToBytes(nonce));
            
            byte[] hash = digest.digest();
            return bytesToHex(hash);
            
        } catch (Exception e) {
            throw new RuntimeException("Error generating commit hash", e);
        }
    }
    
    private BattleVerse createVerseFromWords(int verseNumber, List<WordTimestamp> words) {
        if (words.isEmpty()) {
            return new BattleVerse(verseNumber, "", 0, 0, 0);
        }
        
        StringBuilder lyrics = new StringBuilder();
        for (WordTimestamp word : words) {
            if (lyrics.length() > 0) lyrics.append(" ");
            lyrics.append(word.getWord());
        }
        
        long startTime = words.get(0).getStartTime();
        long endTime = words.get(words.size() - 1).getEndTime();
        
        // Calculate confidence score based on word confidence
        int totalConfidence = 0;
        for (WordTimestamp word : words) {
            totalConfidence += word.getConfidence();
        }
        int avgConfidence = totalConfidence / words.size();
        
        return new BattleVerse(verseNumber, lyrics.toString(), startTime, endTime, avgConfidence);
    }
    
    private byte[] longToBytes(long value) {
        byte[] result = new byte[8];
        for (int i = 7; i >= 0; i--) {
            result[i] = (byte)(value & 0xFF);
            value >>= 8;
        }
        return result;
    }
    
    private String bytesToHex(byte[] bytes) {
        StringBuilder result = new StringBuilder();
        for (byte b : bytes) {
            result.append(String.format("%02x", b));
        }
        return result.toString();
    }
    
    public BattleSession getBattleSession(long battleId) {
        return activeBattles.get(battleId);
    }
    
    public void removeBattleSession(long battleId) {
        activeBattles.remove(battleId);
    }
    
    public List<BattleSession> getActiveBattleSessions() {
        return new ArrayList<>(activeBattles.values());
    }
    
    // Inner classes and enums
    
    public static class BattleSession {
        public long battleId;
        public String challengedUser;
        public String twitterUrl;
        public long stakeAmount;
        public List<String> hashtags;
        public List<BattleVerse> preparedVerses;
        public String recordingUri;
        public long nonce;
        public String commitHash;
        public boolean isChallenger;
        public BattleStatus status;
        public String creationTxHash;
        public String acceptanceTxHash;
        public String revealTxHash;
        public long createdAt;
        public long revealDeadline;
        
        public BattleSession() {
            this.createdAt = System.currentTimeMillis();
            this.status = BattleStatus.CREATED;
        }
        
        public boolean canReveal() {
            return status == BattleStatus.MATCHED && 
                   System.currentTimeMillis() < revealDeadline;
        }
        
        public boolean isExpired() {
            return System.currentTimeMillis() > revealDeadline;
        }
    }
    
    public enum BattleStatus {
        CREATED,
        PENDING_ACCEPTANCE,
        MATCHED,
        ACTIVE,
        REVEALED,
        VOTING_PHASE,
        COMPLETED,
        CANCELLED
    }
    
    public enum VoteChoice {
        CHALLENGER,
        DEFENDER,
        TIE
    }
}