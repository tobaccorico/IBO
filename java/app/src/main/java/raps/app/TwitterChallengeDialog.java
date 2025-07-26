package raps.app;

import android.app.Dialog;
import android.content.Context;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.LayoutInflater;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;
import androidx.annotation.NonNull;
import java.util.List;

public class TwitterChallengeDialog extends Dialog {
    private static final String TAG = "TwitterChallenge";
    
    private Context context;
    private RecordingData recording;
    private List<AudioManager.VerseSegment> verses;
    private TwitterIntegrationService twitterService;
    private BattleManager battleManager;
    
    // UI elements
    private EditText etChallengedUser;
    private EditText etStakeAmount;
    private LinearLayout llVerseContainer;
    private Button btnChallenge;
    private Button btnGenerateVideo;
    private ProgressBar progressBar;
    private TextView tvStatus;
    private TextView tvCharacterCount;
    
    public TwitterChallengeDialog(@NonNull Context context, RecordingData recording, 
                                 List<AudioManager.VerseSegment> verses) {
        super(context);
        this.context = context;
        this.recording = recording;
        this.verses = verses;
        this.twitterService = new TwitterIntegrationService(context);
        this.battleManager = new BattleManager(context);
        
        initializeDialog();
    }
    
    private void initializeDialog() {
        setContentView(R.layout.dialog_twitter_challenge);
        setTitle("🔥 Challenge a Rapper");
        
        initializeViews();
        setupListeners();
        populateVerses();
    }
    
    private void initializeViews() {
        etChallengedUser = findViewById(R.id.et_challenged_user);
        etStakeAmount = findViewById(R.id.et_stake_amount);
        llVerseContainer = findViewById(R.id.ll_verse_container);
        btnChallenge = findViewById(R.id.btn_challenge);
        btnGenerateVideo = findViewById(R.id.btn_generate_video);
        progressBar = findViewById(R.id.progress_bar);
        tvStatus = findViewById(R.id.tv_status);
        tvCharacterCount = findViewById(R.id.tv_character_count);
        
        // Set default stake amount
        etStakeAmount.setText("100"); // Default 100 USD worth of tokens
        
        progressBar.setVisibility(View.GONE);
        tvStatus.setText("Ready to challenge!");
    }
    
    private void setupListeners() {
        btnChallenge.setOnClickListener(v -> initiateChallenge());
        btnGenerateVideo.setOnClickListener(v -> generateVideo());
        
        // Character count tracker for verses
        setupCharacterCountTracking();
    }
    
    private void setupCharacterCountTracking() {
        // This will be set up after verses are populated
    }
    
    private void populateVerses() {
        llVerseContainer.removeAllViews();
        LayoutInflater inflater = LayoutInflater.from(context);
        
        for (int i = 0; i < verses.size(); i++) {
            AudioManager.VerseSegment verse = verses.get(i);
            View verseView = inflater.inflate(R.layout.item_verse_edit, llVerseContainer, false);
            
            TextView tvVerseNumber = verseView.findViewById(R.id.tv_verse_number);
            EditText etVerseLyrics = verseView.findViewById(R.id.et_verse_lyrics);
            TextView tvVerseCharCount = verseView.findViewById(R.id.tv_verse_char_count);
            
            tvVerseNumber.setText("Verse " + (i + 1));
            etVerseLyrics.setText(verse.lyrics);
            updateCharacterCount(etVerseLyrics, tvVerseCharCount);
            
            // Set up character count tracking for this verse
            etVerseLyrics.addTextChangedListener(new TextWatcher() {
                @Override
                public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
                
                @Override
                public void onTextChanged(CharSequence s, int start, int before, int count) {
                    updateCharacterCount(etVerseLyrics, tvVerseCharCount);
                    updateVerseInList(verse, s.toString());
                }
                
                @Override
                public void afterTextChanged(Editable s) {}
            });
            
            llVerseContainer.addView(verseView);
        }
        
        updateOverallStatus();
    }
    
    private void updateCharacterCount(EditText editText, TextView countView) {
        int count = editText.getText().toString().length();
        countView.setText(count + "/140");
        
        if (count > 140) {
            countView.setTextColor(context.getColor(android.R.color.holo_red_dark));
        } else if (count > 120) {
            countView.setTextColor(context.getColor(android.R.color.holo_orange_dark));
        } else {
            countView.setTextColor(context.getColor(android.R.color.darker_gray));
        }
    }
    
    private void updateVerseInList(AudioManager.VerseSegment verse, String newLyrics) {
        verse.lyrics = newLyrics;
        updateOverallStatus();
    }
    
    private void updateOverallStatus() {
        boolean allValid = true;
        int totalChars = 0;
        
        for (AudioManager.VerseSegment verse : verses) {
            if (verse.lyrics == null || verse.lyrics.length() > 140) {
                allValid = false;
            }
            totalChars += verse.lyrics != null ? verse.lyrics.length() : 0;
        }
        
        tvCharacterCount.setText("Total: " + totalChars + " chars across " + verses.size() + " verses");
        
        if (allValid) {
            tvStatus.setText("✅ All verses ready for Twitter!");
            btnChallenge.setEnabled(true);
        } else {
            tvStatus.setText("⚠️ Some verses are too long for Twitter");
            btnChallenge.setEnabled(false);
        }
    }
    
    private void initiateChallenge() {
        String challengedUser = etChallengedUser.getText().toString().trim();
        String stakeAmountStr = etStakeAmount.getText().toString().trim();
        
        // Validation
        if (challengedUser.isEmpty()) {
            Toast.makeText(context, "Enter a Twitter username to challenge", Toast.LENGTH_SHORT).show();
            return;
        }
        
        if (challengedUser.startsWith("@")) {
            challengedUser = challengedUser.substring(1); // Remove @ symbol
        }
        
        long stakeAmount;
        try {
            stakeAmount = Long.parseLong(stakeAmountStr);
            if (stakeAmount <= 0) {
                throw new NumberFormatException("Stake must be positive");
            }
        } catch (NumberFormatException e) {
            Toast.makeText(context, "Enter a valid stake amount", Toast.LENGTH_SHORT).show();
            return;
        }
        
        // Disable UI and show progress
        btnChallenge.setEnabled(false);
        progressBar.setVisibility(View.VISIBLE);
        tvStatus.setText("Posting challenge to Twitter...");
        
        // Create Twitter challenge
        TwitterIntegrationService.TwitterChallenge challenge = new TwitterIntegrationService.TwitterChallenge(
            "", // Challenge URL will be generated
            "", // Tweet URL will be generated
            twitterService.getCurrentUsername(),
            challengedUser,
            recording,
            verses,
            System.currentTimeMillis()
        );
        
        twitterService.postBattleChallenge(recording, verses, challengedUser, 
            new TwitterIntegrationService.TwitterCallback() {
                @Override
                public void onLoginSuccess(String username) {
                    // Not used in this context
                }
                
                @Override
                public void onLoginError(String error) {
                    runOnUiThread(() -> {
                        progressBar.setVisibility(View.GONE);
                        btnChallenge.setEnabled(true);
                        tvStatus.setText("❌ Error: " + error);
                        Toast.makeText(context, "Challenge failed: " + error, Toast.LENGTH_LONG).show();
                    });
                }
                
                @Override
                public void onTweetPosted(String tweetUrl) {
                    runOnUiThread(() -> {
                        progressBar.setVisibility(View.GONE);
                        tvStatus.setText("🔥 Challenge posted to Twitter!");
                        
                        // Create battle in battle manager
                        challenge.setTweetUrl(tweetUrl);
                        BattleManager.BattleState battle = battleManager.createBattleFromChallenge(challenge, stakeAmount);
                        
                        Toast.makeText(context, 
                            "Challenge posted! Battle ID: " + battle.getBattleId(), 
                            Toast.LENGTH_LONG).show();
                        
                        dismiss(); // Close dialog
                    });
                }
                
                @Override
                public void onChallengeDetectepackage raps.app;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;
import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import java.io.File;
import java.util.ArrayList;
import java.util.List;

public class MainActivity extends AppCompatActivity {
    private static final String TAG = "KARAOKEFLOW";
    private static final int PERMISSION_REQUEST_CODE = 1001;
    
    // UI components
    private EditText etYouTubeUrl;
    private Button btnDownload, btnStartKaraoke, btnStopKaraoke, btnMyLibrary, btnPlayRecording;
    private ProgressBar progressBar;
    private TextView tvStatus, tvTranscribedLyrics;
    private EditText etEditLyrics;
    
    // Core services
    private AudioManager audioManager;
    private SpeechToTextService speechToTextService;
    private RealtimeSpeechService realtimeSpeechService;
    private RecordingManager recordingManager;
    
    // State
    private String downloadedAudioPath;
    private String currentVideoTitle;
    private boolean isKaraokeActive = false;
    private RecordingData currentRecording;
    private AudioManager.RecordingCallback recordingCallback;
    private List<WordTimestamp> currentWordTimestamps;
    
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        
        initializeViews();
        initializeServices();
        requestPermissions();
        setupListeners();
    }
    
    private void initializeViews() {
        etYouTubeUrl = findViewById(R.id.et_youtube_url);
        btnDownload = findViewById(R.id.btn_download);
        btnStartKaraoke = findViewById(R.id.btn_start_karaoke);
        btnStopKaraoke = findViewById(R.id.btn_stop_karaoke);
        btnMyLibrary = findViewById(R.id.btn_my_library);
        btnPlayRecording = findViewById(R.id.btn_play_recording);
        progressBar = findViewById(R.id.progress_bar);
        tvStatus = findViewById(R.id.tv_status);
        tvTranscribedLyrics = findViewById(R.id.tv_transcribed_lyrics);
        etEditLyrics = findViewById(R.id.et_edit_lyrics);
        
        btnStartKaraoke.setEnabled(false);
        btnStopKaraoke.setEnabled(false);
        btnPlayRecording.setEnabled(false);
    }
    
    private void initializeServices() {
        audioManager = new AudioManager(this);
        speechToTextService = new SpeechToTextService(this);
        realtimeSpeechService = new RealtimeSpeechService(this);
        recordingManager = new RecordingManager(this);
        currentWordTimestamps = new ArrayList<>();
    }
    
    private void setupListeners() {
        btnDownload.setOnClickListener(v -> downloadYouTubeAudio());
        btnStartKaraoke.setOnClickListener(v -> startKaraoke());
        btnStopKaraoke.setOnClickListener(v -> stopKaraoke());
        btnMyLibrary.setOnClickListener(v -> openLibrary());
        btnPlayRecording.setOnClickListener(v -> playCurrentRecording());
        
        // TEMPORARY: Long press download button to use test mode
        btnDownload.setOnLongClickListener(v -> {
            useTestAudio();
            return true;
        });
    }
    
    private void useTestAudio() {
        // Create a dummy audio file path for testing
        downloadedAudioPath = "test_audio.mp3";
        currentVideoTitle = "Test Audio";
        btnStartKaraoke.setEnabled(true);
        tvStatus.setText("Test mode: Ready for karaoke!");
        Toast.makeText(this, "Test mode activated - you can now test recording", Toast.LENGTH_LONG).show();
    }
    
    private void downloadYouTubeAudio() {
        String url = etYouTubeUrl.getText().toString().trim();
        if (url.isEmpty()) {
            Toast.makeText(this, "Please enter a YouTube URL", Toast.LENGTH_SHORT).show();
            return;
        }
        
        btnDownload.setEnabled(false);
        progressBar.setVisibility(View.VISIBLE);
        tvStatus.setText("Downloading audio...");
        
        YouTubeDownloadService.downloadAudioFromYouTube(url, new YouTubeDownloadService.DownloadCallback() {
            @Override
            public void onProgress(float progress, String status) {
                runOnUiThread(() -> {
                    progressBar.setProgress((int) progress);
                    tvStatus.setText(status);
                });
            }
            
            @Override
            public void onComplete(YouTubeDownloadService.DownloadResult result) {
                runOnUiThread(() -> {
                    downloadedAudioPath = result.audioFilePath;
                    currentVideoTitle = result.videoTitle;
                    btnDownload.setEnabled(true);
                    btnStartKaraoke.setEnabled(true);
                    progressBar.setVisibility(View.GONE);
                    tvStatus.setText("Download complete: " + result.videoTitle);
                    Toast.makeText(MainActivity.this, "Ready for karaoke!", Toast.LENGTH_SHORT).show();
                });
            }
            
            @Override
            public void onError(String error) {
                runOnUiThread(() -> {
                    btnDownload.setEnabled(true);
                    progressBar.setVisibility(View.GONE);
                    tvStatus.setText("Download failed: " + error);
                    Toast.makeText(MainActivity.this, "Download failed", Toast.LENGTH_SHORT).show();
                });
            }
        });
    }
    
    private void startKaraoke() {
        if (downloadedAudioPath == null) {
            Toast.makeText(this, "No audio file available", Toast.LENGTH_SHORT).show();
            return;
        }
        
        isKaraokeActive = true;
        btnStartKaraoke.setEnabled(false);
        btnStopKaraoke.setEnabled(true);
        tvStatus.setText("Karaoke started - sing along!");
        
        // Start audio playback
        audioManager.playAudio(downloadedAudioPath, mp -> {
            // Audio playback completed
            runOnUiThread(() -> {
                if (isKaraokeActive) {
                    stopKaraoke();
                }
            });
        });
        
        // Start real-time speech recognition
        Log.d(TAG, "Starting real-time speech recognition");
        realtimeSpeechService.startRealtimeTranscription(new RealtimeSpeechService.RealtimeTranscriptionCallback() {
            @Override
            public void onTranscriptionUpdate(String text) {
                runOnUiThread(() -> {
                    tvTranscribedLyrics.setText(text);
                    etEditLyrics.setText(text);
                });
            }
            
            @Override
            public void onPartialUpdate(String partialText) {
                runOnUiThread(() -> {
                    tvTranscribedLyrics.setText(partialText + "...");
                });
            }
            
            @Override
            public void onWordDetected(WordTimestamp wordTimestamp) {
                Log.d(TAG, "Word detected: " + wordTimestamp);
                currentWordTimestamps.add(wordTimestamp);
            }
            
            @Override
            public void onTranscriptionComplete(String finalText, List<WordTimestamp> timestamps) {
                Log.d(TAG, "Transcription complete: " + finalText);
                Log.d(TAG, "Total word timestamps: " + timestamps.size());
                
                runOnUiThread(() -> {
                    tvTranscribedLyrics.setText(finalText);
                    etEditLyrics.setText(finalText);
                    
                    // Update recording with lyrics and timestamps
                    if (currentRecording != null) {
                        currentRecording.setLyrics(finalText);
                        // TODO: Save word timestamps to recording data
                        recordingManager.saveRecordingData(currentRecording);
                        Log.d(TAG, "Recording data saved with lyrics and timestamps");
                    }
                });
            }
            
            @Override
            public void onError(String error) {
                Log.e(TAG, "Real-time transcription error: " + error);
                runOnUiThread(() -> {
                    tvStatus.setText("Transcription error: " + error);
                });
            }
        });
        
        // Start recording user's voice
        Log.d(TAG, "About to start recording with callback");
        
        // Create the callback once and reuse it
        recordingCallback = new AudioManager.RecordingCallback() {
            @Override
            public void onRecordingStarted() {
                Log.d(TAG, "Recording started callback received");
                runOnUiThread(() -> tvStatus.setText("Recording your voice..."));
            }
            
            @Override
            public void onRecordingStopped(List<Short> audioData) {
                Log.d(TAG, "Recording stopped. Audio data size: " + (audioData != null ? audioData.size() : "null"));
                
                runOnUiThread(() -> {
                    tvStatus.setText("Processing recording...");
                });
                
                if (audioData == null || audioData.isEmpty()) {
                    Log.e(TAG, "No audio data received");
                    runOnUiThread(() -> {
                        tvStatus.setText("No audio data recorded");
                    });
                    return;
                }
                
                // Save the recording first
                String fileName = "recording_" + System.currentTimeMillis();
                Log.d(TAG, "Saving recording with filename: " + fileName);
                
                File recordingFile = recordingManager.saveRecording(audioData, fileName);
                
                if (recordingFile != null) {
                    Log.d(TAG, "Recording saved successfully: " + recordingFile.getAbsolutePath());
                    
                    // Create recording data object
                    currentRecording = new RecordingData(currentVideoTitle, downloadedAudioPath, 
                                                        recordingFile.getAbsolutePath(), "");
                    
                    runOnUiThread(() -> {
                        btnPlayRecording.setEnabled(true);
                        tvStatus.setText("Recording saved! Finishing transcription...");
                    });
                    
                    // Finish real-time transcription
                    realtimeSpeechService.finishTranscription(new RealtimeSpeechService.RealtimeTranscriptionCallback() {
                        @Override
                        public void onTranscriptionUpdate(String text) {}
                        @Override public void onPartialUpdate(String partialText) {}
                        @Override public void onWordDetected(WordTimestamp wordTimestamp) {}
                        
                        @Override
                        public void onTranscriptionComplete(String finalText, List<WordTimestamp> timestamps) {
                            Log.d(TAG, "Final transcription complete: " + finalText);
                            Log.d(TAG, "Final word timestamps: " + timestamps.size());
                            
                            runOnUiThread(() -> {
                                tvTranscribedLyrics.setText(finalText);
                                etEditLyrics.setText(finalText);
                                
                                // Update recording with final lyrics and timestamps
                                if (currentRecording != null) {
                                    currentRecording.setLyrics(finalText);
                                    recordingManager.saveRecordingData(currentRecording);
                                    Log.d(TAG, "Recording data saved with final transcription");
                                }
                                
                                tvStatus.setText("Transcription complete!");
                            });
                        }
                        
                        @Override
                        public void onError(String error) {
                            Log.e(TAG, "Final transcription error: " + error);
                        }
                    });
                } else {
                    Log.e(TAG, "Failed to save recording");
                    runOnUiThread(() -> {
                        tvStatus.setText("Failed to save recording");
                    });
                    
                    // Still stop transcription
                    realtimeSpeechService.stopRealtimeTranscription();
                    return;
                }
                
                // Remove the old transcription code since we're now using real-time
            }
            
            @Override
            public void onRecordingError(String error) {
                Log.e(TAG, "Recording error: " + error);
                runOnUiThread(() -> {
                    tvStatus.setText("Recording error: " + error);
                });
            }
        };
        
        audioManager.startRecording(recordingCallback);
    }
    
    private void stopKaraoke() {
        Log.d(TAG, "stopKaraoke() called");
        isKaraokeActive = false;
        btnStartKaraoke.setEnabled(true);
        btnStopKaraoke.setEnabled(false);
        
        Log.d(TAG, "Stopping audio playback");
        audioManager.stopPlayback();
        
        Log.d(TAG, "Stopping real-time transcription");
        realtimeSpeechService.stopRealtimeTranscription();
        
        Log.d(TAG, "Stopping recording with same callback instance");
        audioManager.stopRecording(recordingCallback);
        
        tvStatus.setText("Karaoke stopped");
    }
    
    private void openLibrary() {
        Intent intent = new Intent(this, LibraryActivity.class);
        startActivity(intent);
    }
    
    private void playCurrentRecording() {
        if (currentRecording != null && currentRecording.getRecordingFilePath() != null) {
            try {
                MediaPlayer player = new MediaPlayer();
                player.setDataSource(currentRecording.getRecordingFilePath());
                player.setOnCompletionListener(mp -> {
                    mp.release();
                    runOnUiThread(() -> Toast.makeText(MainActivity.this, 
                        "Recording playback completed", Toast.LENGTH_SHORT).show());
                });
                player.prepare();
                player.start();
                Toast.makeText(this, "Playing your recording...", Toast.LENGTH_SHORT).show();
            } catch (Exception e) {
                Toast.makeText(this, "Error playing recording", Toast.LENGTH_SHORT).show();
            }
        }
    }
    
    private void requestPermissions() {
        String[] permissions = {
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.WRITE_EXTERNAL_STORAGE,
            Manifest.permission.READ_EXTERNAL_STORAGE
        };
        
        ActivityCompat.requestPermissions(this, permissions, PERMISSION_REQUEST_CODE);
    }
    
    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == PERMISSION_REQUEST_CODE) {
            boolean allPermissionsGranted = true;
            for (int result : grantResults) {
                if (result != PackageManager.PERMISSION_GRANTED) {
                    allPermissionsGranted = false;
                    break;
                }
            }
            
            if (!allPermissionsGranted) {
                Toast.makeText(this, "Permissions required for app to function", Toast.LENGTH_LONG).show();
            }
        }
    }
    
    @Override
    protected void onDestroy() {
        super.onDestroy();
        audioManager.release();
        speechToTextService.release();
        realtimeSpeechService.release();
    }
}d(TwitterIntegrationService.TwitterChallenge detectedChallenge) {
                    // Not used in this context
                }
                
                @Override
                public void onBattleUpdated(TwitterIntegrationService.TwitterBattle battle) {
                    // Not used in this context
                }
            });
    }
    
    private void generateVideo() {
        btnGenerateVideo.setEnabled(false);
        progressBar.setVisibility(View.VISIBLE);
        tvStatus.setText("🎬 Generating video with Gemini...");
        
        battleManager.generateVideoFromTranscript("preview", "user", verses, 
            new BattleManager.VideoGenerationCallback() {
                @Override
                public void onVideoGenerated(String videoUrl) {
                    runOnUiThread(() -> {
                        progressBar.setVisibility(View.GONE);
                        btnGenerateVideo.setEnabled(true);
                        tvStatus.setText("✅ Video generated! URL: " + videoUrl);
                        
                        Toast.makeText(context, 
                            "Video generated! Check the URL in status", 
                            Toast.LENGTH_LONG).show();
                    });
                }
                
                @Override
                public void onVideoError(String error) {
                    runOnUiThread(() -> {
                        progressBar.setVisibility(View.GONE);
                        btnGenerateVideo.setEnabled(true);
                        tvStatus.setText("❌ Video generation failed: " + error);
                        
                        Toast.makeText(context, 
                            "Video generation failed: " + error, 
                            Toast.LENGTH_LONG).show();
                    });
                }
            });
    }
    
    private void runOnUiThread(Runnable action) {
        if (context instanceof android.app.Activity) {
            ((android.app.Activity) context).runOnUiThread(action);
        }
    }
}