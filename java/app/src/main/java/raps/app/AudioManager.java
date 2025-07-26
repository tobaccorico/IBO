package raps.app;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaPlayer;
import android.media.MediaRecorder;
import android.net.Uri;
import android.util.Log;
import androidx.core.app.ActivityCompat;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

public class AudioManager {
    private static final String TAG = "AudioManager";
    private static final int SAMPLE_RATE = 44100;
    private static final int BUFFER_SIZE = AudioRecord.getMinBufferSize(
        SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
    
    private MediaPlayer mediaPlayer;
    private AudioRecord audioRecord;
    private boolean isRecording = false;
    private List<Short> recordedAudio;
    private Context context;
    
    // Battle timing tracking
    private long battleStartTime = 0;
    private int currentCrowInterval = 0;
    private static final int CROW_INTERVAL_MS = 45000; // 45 seconds
    private static final int MAX_BATTLE_DURATION_MS = 140000; // 2:20 for Twitter video limit
    private BattleTimingCallback battleCallback;
    
    public AudioManager(Context context) {
        this.context = context;
    }
    
    public interface RecordingCallback {
        void onRecordingStarted();
        void onRecordingStopped(List<Short> audioData);
        void onRecordingError(String error);
    }
    
    public interface BattleTimingCallback {
        void onCrowSound(int intervalNumber); // Marks 45-second intervals
        void onVerseCompleted(String verse, int verseNumber, long startTime, long endTime);
        void onBattleTimeLimit(); // Called at 2:20 mark
    }
    
    // Enhanced playAudio method that handles both URLs and local files
    public void playAudio(String audioSource, MediaPlayer.OnCompletionListener completionListener) {
        try {
            if (mediaPlayer != null) {
                mediaPlayer.release();
            }
            
            mediaPlayer = new MediaPlayer();
            
            // Check if it's a URL or local file path
            if (audioSource.startsWith("http://") || audioSource.startsWith("https://")) {
                Log.d(TAG, "Playing audio from URL: " + audioSource.substring(0, Math.min(50, audioSource.length())));
                mediaPlayer.setDataSource(audioSource);
            } else {
                Log.d(TAG, "Playing audio from local file: " + audioSource);
                mediaPlayer.setDataSource(audioSource);
            }
            
            mediaPlayer.setOnCompletionListener(completionListener);
            mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                Log.e(TAG, "MediaPlayer error: what=" + what + ", extra=" + extra);
                if (completionListener != null) {
                    completionListener.onCompletion(mp);
                }
                return true;
            });
            
            mediaPlayer.prepareAsync();
            mediaPlayer.setOnPreparedListener(mp -> {
                Log.d(TAG, "MediaPlayer prepared, starting playback");
                mp.start();
            });
            
        } catch (IOException e) {
            Log.e(TAG, "Error playing audio from: " + audioSource, e);
        }
    }
    
    // Start recording with battle timing features
    public void startBattleRecording(RecordingCallback callback, BattleTimingCallback battleCallback) {
        this.battleCallback = battleCallback;
        this.battleStartTime = System.currentTimeMillis();
        this.currentCrowInterval = 0;
        
        // Start regular recording
        startRecording(callback);
        
        // Start battle timing thread
        new Thread(this::manageBattleTiming).start();
    }
    
    private void manageBattleTiming() {
        Log.d(TAG, "Battle timing thread started");
        
        while (isRecording) {
            long elapsedTime = System.currentTimeMillis() - battleStartTime;
            
            // Check for crow sound intervals (every 45 seconds)
            int expectedInterval = (int) (elapsedTime / CROW_INTERVAL_MS);
            if (expectedInterval > currentCrowInterval && expectedInterval < 4) { // Max 4 intervals
                currentCrowInterval = expectedInterval;
                Log.d(TAG, "Crow interval " + currentCrowInterval + " reached");
                
                if (battleCallback != null) {
                    battleCallback.onCrowSound(currentCrowInterval);
                }
            }
            
            // Check for maximum battle duration (2:20)
            if (elapsedTime >= MAX_BATTLE_DURATION_MS) {
                Log.d(TAG, "Battle time limit reached");
                if (battleCallback != null) {
                    battleCallback.onBattleTimeLimit();
                }
                break;
            }
            
            try {
                Thread.sleep(1000); // Check every second
            } catch (InterruptedException e) {
                Log.w(TAG, "Battle timing thread interrupted", e);
                Thread.currentThread().interrupt();
                break;
            }
        }
        
        Log.d(TAG, "Battle timing thread finished");
    }
    
    // Process recorded audio to extract verses with timestamps
    public List<VerseSegment> extractVerseSegments(List<Short> audioData) {
        List<VerseSegment> verses = new ArrayList<>();
        
        // Simple segmentation based on crow intervals
        // In practice, this would use more sophisticated audio analysis
        long segmentDuration = CROW_INTERVAL_MS;
        int samplesPerSegment = (int) (SAMPLE_RATE * segmentDuration / 1000);
        
        for (int i = 0; i < Math.min(4, audioData.size() / samplesPerSegment); i++) {
            int startSample = i * samplesPerSegment;
            int endSample = Math.min((i + 1) * samplesPerSegment, audioData.size());
            
            long startTime = battleStartTime + (i * segmentDuration);
            long endTime = startTime + segmentDuration;
            
            List<Short> segmentData = audioData.subList(startSample, endSample);
            
            VerseSegment verse = new VerseSegment(
                i + 1,
                startTime,
                endTime,
                segmentData,
                "" // Lyrics will be filled by transcription
            );
            
            verses.add(verse);
            Log.d(TAG, "Extracted verse " + (i + 1) + " from " + startTime + " to " + endTime);
        }
        
        return verses;
    }
    
    // Validate verse for Twitter character limit
    public boolean isVerseValidForTwitter(String lyrics) {
        return lyrics != null && lyrics.length() <= 140;
    }
    
    // Start recording microphone input
    public void startRecording(RecordingCallback callback) {
        if (isRecording) return;
        
        // Check for RECORD_AUDIO permission
        if (ActivityCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) 
            != PackageManager.PERMISSION_GRANTED) {
            callback.onRecordingError("RECORD_AUDIO permission not granted");
            return;
        }
        
        recordedAudio = new ArrayList<>();
        
        try {
            audioRecord = new AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                BUFFER_SIZE
            );
            
            if (audioRecord.getState() != AudioRecord.STATE_INITIALIZED) {
                callback.onRecordingError("AudioRecord initialization failed");
                return;
            }
            
            audioRecord.startRecording();
            isRecording = true;
            callback.onRecordingStarted();
            
            // Record in background thread
            new Thread(() -> {
                short[] buffer = new short[BUFFER_SIZE];
                Log.d(TAG, "Recording thread started");
                int totalSamples = 0;
                
                while (isRecording) {
                    int read = audioRecord.read(buffer, 0, buffer.length);
                    if (read > 0) {
                        totalSamples += read;
                        for (int i = 0; i < read; i++) {
                            recordedAudio.add(buffer[i]);
                        }
                        
                        // Log every 10000 samples to avoid spam
                        if (totalSamples % 10000 == 0) {
                            Log.d(TAG, "Recorded " + totalSamples + " samples so far");
                        }
                    } else {
                        Log.w(TAG, "AudioRecord.read returned: " + read);
                    }
                }
                
                Log.d(TAG, "Recording thread finished. Total samples: " + totalSamples);
            }).start();
            
        } catch (Exception e) {
            Log.e(TAG, "Error starting recording", e);
            callback.onRecordingError("Failed to start recording: " + e.getMessage());
        }
    }
    
    // Stop recording
    public void stopRecording(RecordingCallback callback) {
        if (!isRecording) return;
        
        isRecording = false;
        
        if (audioRecord != null) {
            audioRecord.stop();
            audioRecord.release();
            audioRecord = null;
        }
        
        if (callback != null) {
            callback.onRecordingStopped(new ArrayList<>(recordedAudio));
        }
    }
    
    // Stop audio playback
    public void stopPlayback() {
        if (mediaPlayer != null && mediaPlayer.isPlaying()) {
            mediaPlayer.stop();
        }
    }
    
    // Clean up resources
    public void release() {
        stopRecording(null);
        if (mediaPlayer != null) {
            mediaPlayer.release();
            mediaPlayer = null;
        }
    }
    
    // Data class for verse segments
    public static class VerseSegment {
        public final int verseNumber;
        public final long startTime;
        public final long endTime;
        public final List<Short> audioData;
        public String lyrics;
        
        public VerseSegment(int verseNumber, long startTime, long endTime, 
                           List<Short> audioData, String lyrics) {
            this.verseNumber = verseNumber;
            this.startTime = startTime;
            this.endTime = endTime;
            this.audioData = audioData;
            this.lyrics = lyrics;
        }
        
        public long getDurationMs() {
            return endTime - startTime;
        }
        
        public boolean isValidForTwitter() {
            return lyrics != null && lyrics.length() <= 140;
        }
    }
}