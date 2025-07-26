package raps.app;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.widget.*;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import com.google.android.material.floatingactionbutton.FloatingActionButton;
import java.util.List;

public class MainActivity extends AppCompatActivity implements BattleManager.BattleStateListener {
    private static final String TAG = "MainActivity";
    private static final int PERMISSION_REQUEST_CODE = 100;
    
    // UI Components
    private Button btnStartBattle;
    private Button btnAcceptBattle;
    private Button btnRevealBattle;
    private Button btnDiscoverBattles;
    private Button btnConnectTwitter;
    private EditText etChallengedUser;
    private EditText etStakeAmount;
    private TextView tvBattleStatus;
    private TextView tvWalletInfo;
    private TextView tvTwitterStatus;
    private ProgressBar progressBar;
    private ListView lvActiveBattles;
    
    // Core services
    private BattleManager battleManager;
    private AudioManager audioManager;
    private RecordingManager recordingManager;
    
    // State
    private boolean isRecording = false;
    private String currentRecordingPath;
    private BattleConfigDialog battleConfigDialog;
    
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        
        initializeUI();
        requestPermissions();
        initializeServices();
        setupBattleFlow();
        handleTwitterCallback();
    }
    
    private void initializeUI() {
        btnStartBattle = findViewById(R.id.btnStartBattle);
        btnAcceptBattle = findViewById(R.id.btnAcceptBattle);
        btnRevealBattle = findViewById(R.id.btnRevealBattle);
        btnDiscoverBattles = findViewById(R.id.btnDiscoverBattles);
        btnConnectTwitter = findViewById(R.id.btnConnectTwitter);
        etChallengedUser = findViewById(R.id.etChallengedUser);
        etStakeAmount = findViewById(R.id.etStakeAmount);
        tvBattleStatus = findViewById(R.id.tvBattleStatus);
        tvWalletInfo = findViewById(R.id.tvWalletInfo);
        tvTwitterStatus = findViewById(R.id.tvTwitterStatus);
        progressBar = findViewById(R.id.progressBar);
        lvActiveBattles = findViewById(R.id.lvActiveBattles);
        
        // Set default values
        etStakeAmount.setText("1000000"); // 1 USD* (6 decimals)
        tvBattleStatus.setText("Ready to battle");
        tvTwitterStatus.setText("Twitter: Not connected");
        
        // Initially disable battle actions
        updateBattleUI(false);
    }
    
    private void requestPermissions() {
        String[] permissions = {
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.WRITE_EXTERNAL_STORAGE,
            Manifest.permission.READ_EXTERNAL_STORAGE,
            Manifest.permission.INTERNET
        };
        
        boolean allGranted = true;
        for (String permission : permissions) {
            if (ContextCompat.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED) {
                allGranted = false;
                break;
            }
        }
        
        if (!allGranted) {
            ActivityCompat.requestPermissions(this, permissions, PERMISSION_REQUEST_CODE);
        }
    }
    
    private void initializeServices() {
        try {
            battleManager = new BattleManager(this);
            battleManager.addBattleStateListener(this);
            
            audioManager = new AudioManager(this);
            recordingManager = new RecordingManager(this);
            
            // Initialize wallet (in production, use proper wallet integration)
            initializeWallet();
            
            // Check Twitter authentication status
            updateTwitterStatus();
            
            Log.i(TAG, "Services initialized successfully");
        } catch (Exception e) {
            Log.e(TAG, "Error initializing services", e);
            showError("Failed to initialize app services");
        }
    }
    
    private void initializeWallet() {
        // In production, integrate with Phantom, Solflare, or other Solana wallets
        // For demo purposes, use hardcoded keys (NEVER do this in production!)
        String demoPublicKey = "11111111111111111111111111111112"; // System program
        String demoPrivateKey = "demo_private_key";
        
        battleManager.solanaManager.setUserWallet(demoPublicKey, demoPrivateKey);
        tvWalletInfo.setText("Wallet: " + demoPublicKey.substring(0, 8) + "...");
    }
    
    private void updateTwitterStatus() {
        if (battleManager.isTwitterAuthenticated()) {
            String username = battleManager.twitterService.getUsername();
            tvTwitterStatus.setText("Twitter: @" + username);
            btnConnectTwitter.setText("Disconnect Twitter");
            btnStartBattle.setEnabled(true);
        } else {
            tvTwitterStatus.setText("Twitter: Not connected");
            btnConnectTwitter.setText("Connect Twitter");
            btnStartBattle.setEnabled(false);
        }
    }
    
    private void setupBattleFlow() {
        btnStartBattle.setOnClickListener(v -> showBattleConfigDialog());
        btnAcceptBattle.setOnClickListener(v -> showAcceptBattleDialog());
        btnRevealBattle.setOnClickListener(v -> revealBattleEntry());
        btnDiscoverBattles.setOnClickListener(v -> discoverBattles());
        btnConnectTwitter.setOnClickListener(v -> handleTwitterConnection());
        
        FloatingActionButton fabRecord = findViewById(R.id.fabRecord);
        fabRecord.setOnClickListener(v -> toggleRecording());
    }
    
    private void handleTwitterConnection() {
        if (battleManager.isTwitterAuthenticated()) {
            // Disconnect
            battleManager.twitterService.logout();
            updateTwitterStatus();
            showInfo("Twitter disconnected");
        } else {
            // Connect
            showProgress("Connecting to Twitter...");
            battleManager.authenticateTwitter(new TwitterOAuthService.TwitterAuthCallback() {
                @Override
                public void onAuthSuccess(String username, String userId) {
                    runOnUiThread(() -> {
                        hideProgress();
                        updateTwitterStatus();
                        showSuccess("Connected to Twitter as @" + username);
                    });
                }
                
                @Override
                public void onAuthError(String error) {
                    runOnUiThread(() -> {
                        hideProgress();
                        showError("Twitter connection failed: " + error);
                    });
                }
            });
        }
    }
    
    private void handleTwitterCallback() {
        Intent intent = getIntent();
        Uri data = intent.getData();
        
        if (data != null && data.getScheme() != null && data.getScheme().equals("rapsapp")) {
            if (data.getHost().equals("twitter_callback")) {
                Log.i(TAG, "Handling Twitter OAuth callback");
                
                battleManager.handleTwitterCallback(data, new TwitterOAuthService.TwitterAuthCallback() {
                    @Override
                    public void onAuthSuccess(String username, String userId) {
                        runOnUiThread(() -> {
                            updateTwitterStatus();
                            showSuccess("Successfully connected to Twitter as @" + username);
                        });
                    }
                    
                    @Override
                    public void onAuthError(String error) {
                        runOnUiThread(() -> {
                            showError("Twitter authentication failed: " + error);
                        });
                    }
                });
            }
        }
    }
    
    private void showBattleConfigDialog() {
        if (!battleManager.isTwitterAuthenticated()) {
            showError("Please connect to Twitter first");
            return;
        }
        
        battleConfigDialog = new BattleConfigDialog(this, new BattleConfigDialog.BattleConfigCallback() {
            @Override
            public void onBattleConfigured(BattleConfigDialog.BattleConfiguration config) {
                startBattleChallenge(config);
            }
            
            @Override
            public void onCancelled() {
                // Dialog dismissed
            }
        });
        
        battleConfigDialog.show();
    }
    
    private void startBattleChallenge(BattleConfigDialog.BattleConfiguration config) {
        showProgress("Creating battle challenge...");
        updateBattleUI(false);
        
        battleManager.startBattleChallenge(config)
            .thenRun(() -> runOnUiThread(() -> {
                hideProgress();
                showSuccess("Battle challenge created successfully!");
                updateBattleStatus();
            }))
            .exceptionally(throwable -> {
                runOnUiThread(() -> {
                    hideProgress();
                    updateBattleUI(true);
                    showError("Failed to create battle: " + throwable.getMessage());
                });
                return null;
            });
    }
    
    private void showAcceptBattleDialog() {
        if (!battleManager.isTwitterAuthenticated()) {
            showError("Please connect to Twitter first");
            return;
        }
        
        // Show dialog to enter battle ID to accept
        EditText input = new EditText(this);
        input.setHint("Enter Battle ID");
        
        new androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Accept Battle Challenge")
            .setView(input)
            .setPositiveButton("Accept", (dialog, which) -> {
                String battleIdStr = input.getText().toString().trim();
                if (!battleIdStr.isEmpty()) {
                    try {
                        long battleId = Long.parseLong(battleIdStr);
                        acceptBattleChallenge(battleId);
                    } catch (NumberFormatException e) {
                        showError("Invalid battle ID");
                    }
                }
            })
            .setNegativeButton("Cancel", null)
            .show();
    }
    
    private void acceptBattleChallenge(long battleId) {
        showProgress("Accepting battle challenge...");
        updateBattleUI(false);
        
        battleManager.acceptBattleChallenge(battleId, "Let's do this! 🔥")
            .thenRun(() -> runOnUiThread(() -> {
                hideProgress();
                showSuccess("Battle challenge accepted!");
                updateBattleStatus();
            }))
            .exceptionally(throwable -> {
                runOnUiThread(() -> {
                    hideProgress();
                    updateBattleUI(true);
                    showError("Failed to accept battle: " + throwable.getMessage());
                });
                return null;
            });
    }
    
    private void revealBattleEntry() {
        if (!battleManager.hasActiveBattle()) {
            showError("No active battle to reveal");
            return;
        }
        
        BattleIntegration.BattleSession battle = battleManager.getCurrentBattle();
        if (!battle.canReveal()) {
            showError("Battle reveal window has closed");
            return;
        }
        
        showProgress("Revealing battle entry...");
        
        battleManager.revealBattleEntry()
            .thenRun(() -> runOnUiThread(() -> {
                hideProgress();
                showSuccess("Battle entry revealed!");
                updateBattleStatus();
            }))
            .exceptionally(throwable -> {
                runOnUiThread(() -> {
                    hideProgress();
                    showError("Failed to reveal battle: " + throwable.getMessage());
                });
                return null;
            });
    }
    
    private void discoverBattles() {
        showProgress("Discovering battles...");
        
        battleManager.discoverBattles("musical")
            .thenAccept(battles -> runOnUiThread(() -> {
                hideProgress();
                showBattlesDialog(battles);
            }))
            .exceptionally(throwable -> {
                runOnUiThread(() -> {
                    hideProgress();
                    showError("Failed to discover battles: " + throwable.getMessage());
                });
                return null;
            });
    }
    
    private void showBattlesDialog(List<BattleManager.BattleInfo> battles) {
        if (battles.isEmpty()) {
            showInfo("No battles found in this category");
            return;
        }
        
        String[] battleTitles = new String[battles.size()];
        for (int i = 0; i < battles.size(); i++) {
            BattleManager.BattleInfo battle = battles.get(i);
            battleTitles[i] = "Battle #" + battle.battleId + " - " + 
                            battle.challenger + " vs " + battle.defender +
                            " (" + battle.stakeAmount + " USD*)";
        }
        
        new androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Available Battles")
            .setItems(battleTitles, (dialog, which) -> {
                BattleManager.BattleInfo selectedBattle = battles.get(which);
                showBattleDetails(selectedBattle);
            })
            .setNegativeButton("Close", null)
            .show();
    }
    
    private void showBattleDetails(BattleManager.BattleInfo battle) {
        String details = "Battle ID: " + battle.battleId + "\n" +
                        "Challenger: " + battle.challenger + "\n" +
                        "Defender: " + battle.defender + "\n" +
                        "Stake: " + battle.stakeAmount + " USD*\n" +
                        "Status: " + battle.status + "\n" +
                        "Twitter: " + battle.twitterUrl;
        
        new androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Battle Details")
            .setMessage(details)
            .setPositiveButton("Vote", (dialog, which) -> showVoteDialog(battle))
            .setNeutralButton("Accept", (dialog, which) -> acceptBattleChallenge(battle.battleId))
            .setNegativeButton("Close", null)
            .show();
    }
    
    private void showVoteDialog(BattleManager.BattleInfo battle) {
        String[] options = {"Vote for Challenger", "Vote for Defender", "Vote Tie"};
        
        new androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Submit Vote")
            .setItems(options, (dialog, which) -> {
                BattleIntegration.VoteChoice vote = switch (which) {
                    case 0 -> BattleIntegration.VoteChoice.CHALLENGER;
                    case 1 -> BattleIntegration.VoteChoice.DEFENDER;
                    default -> BattleIntegration.VoteChoice.TIE;
                };
                submitVote(battle.battleId, vote);
            })
            .setNegativeButton("Cancel", null)
            .show();
    }
    
    private void submitVote(long battleId, BattleIntegration.VoteChoice vote) {
        showProgress("Submitting vote...");
        
        battleManager.submitVote(battleId, vote, 0) // No stake for vote
            .thenRun(() -> runOnUiThread(() -> {
                hideProgress();
                showSuccess("Vote submitted successfully!");
            }))
            .exceptionally(throwable -> {
                runOnUiThread(() -> {
                    hideProgress();
                    showError("Failed to submit vote: " + throwable.getMessage());
                });
                return null;
            });
    }
    
    private void toggleRecording() {
        if (isRecording) {
            stopRecording();
        } else {
            startRecording();
        }
    }
    
    private void startRecording() {
        try {
            currentRecordingPath = recordingManager.startRecording();
            isRecording = true;
            
            FloatingActionButton fabRecord = findViewById(R.id.fabRecord);
            fabRecord.setImageResource(android.R.drawable.ic_media_pause);
            
            showInfo("Recording started...");
            
        } catch (Exception e) {
            Log.e(TAG, "Error starting recording", e);
            showError("Failed to start recording");
        }
    }
    
    private void stopRecording() {
        try {
            recordingManager.stopRecording();
            isRecording = false;
            
            FloatingActionButton fabRecord = findViewById(R.id.fabRecord);
            fabRecord.setImageResource(android.R.drawable.ic_btn_speak_now);
            
            showInfo("Recording stopped: " + currentRecordingPath);
            
        } catch (Exception e) {
            Log.e(TAG, "Error stopping recording", e);
            showError("Failed to stop recording");
        }
    }
    
    private void updateBattleStatus() {
        if (battleManager.hasActiveBattle()) {
            BattleIntegration.BattleSession battle = battleManager.getCurrentBattle();
            tvBattleStatus.setText("Battle #" + battle.battleId + " - " + battle.status);
            
            // Update UI based on battle state
            btnRevealBattle.setEnabled(battle.canReveal());
            updateBattleUI(true);
            
            // Start monitoring battle state
            battleManager.startBattleMonitoring();
        } else {
            tvBattleStatus.setText("No active battle");
            updateBattleUI(true);
        }
    }
    
    private void updateBattleUI(boolean enabled) {
        btnStartBattle.setEnabled(enabled && !battleManager.hasActiveBattle() && battleManager.isTwitterAuthenticated());
        btnAcceptBattle.setEnabled(enabled && battleManager.isTwitterAuthenticated());
        btnDiscoverBattles.setEnabled(enabled);
    }
    
    // BattleStateListener implementation
    
    @Override
    public void onBattleCreated(BattleIntegration.BattleSession battle) {
        runOnUiThread(() -> {
            showSuccess("Battle challenge created! ID: " + battle.battleId);
            updateBattleStatus();
        });
    }
    
    @Override
    public void onBattleAccepted(BattleIntegration.BattleSession battle) {
        runOnUiThread(() -> {
            showSuccess("Battle challenge accepted!");
            updateBattleStatus();
        });
    }
    
    @Override
    public void onBattleRevealed(BattleIntegration.BattleSession battle) {
        runOnUiThread(() -> {
            showSuccess("Battle entry revealed!");
            updateBattleStatus();
        });
    }
    
    @Override
    public void onBattleCompleted(BattleIntegration.BattleSession battle) {
        runOnUiThread(() -> {
            showSuccess("Battle completed!");
            updateBattleStatus();
        });
    }
    
    @Override
    public void onBattleError(String error) {
        runOnUiThread(() -> showError(error));
    }
    
    @Override
    public void onTwitterAuthRequired() {
        runOnUiThread(() -> {
            showError("Twitter authentication required");
            handleTwitterConnection();
        });
    }
    
    @Override
    public void onTwitterPostSuccess(String tweetUrl) {
        runOnUiThread(() -> {
            showSuccess("Posted to Twitter successfully!");
            // Optionally open Twitter URL
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(tweetUrl));
            startActivity(intent);
        });
    }
    
    // UI Helper methods
    
    private void showProgress(String message) {
        progressBar.setVisibility(View.VISIBLE);
        tvBattleStatus.setText(message);
    }
    
    private void hideProgress() {
        progressBar.setVisibility(View.GONE);
    }
    
    private void showError(String message) {
        Toast.makeText(this, "Error: " + message, Toast.LENGTH_LONG).show();
        Log.e(TAG, message);
    }
    
    private void showSuccess(String message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
        Log.i(TAG, message);
    }
    
    private void showInfo(String message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
        Log.i(TAG, message);
    }
    
    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (battleManager != null) {
            battleManager.removeBattleStateListener(this);
            battleManager.shutdown();
        }
        if (recordingManager != null) {
            recordingManager.cleanup();
        }
    }
    
    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        
        if (requestCode == PERMISSION_REQUEST_CODE) {
            boolean allGranted = true;
            for (int result : grantResults) {
                if (result != PackageManager.PERMISSION_GRANTED) {
                    allGranted = false;
                    break;
                }
            }
            
            if (!allGranted) {
                showError("All permissions are required for the app to function properly");
                finish();
            }
        }
    }
    
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleTwitterCallback();
    }
}
    
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        
        initializeUI();
        requestPermissions();
        initializeServices();
        setupBattleFlow();
    }
    
    private void initializeUI() {
        btnStartBattle = findViewById(R.id.btnStartBattle);
        btnAcceptBattle = findViewById(R.id.btnAcceptBattle);
        btnRevealBattle = findViewById(R.id.btnRevealBattle);
        btnDiscoverBattles = findViewById(R.id.btnDiscoverBattles);
        etChallengedUser = findViewById(R.id.etChallengedUser);
        etStakeAmount = findViewById(R.id.etStakeAmount);
        tvBattleStatus = findViewById(R.id.tvBattleStatus);
        tvWalletInfo = findViewById(R.id.tvWalletInfo);
        progressBar = findViewById(R.id.progressBar);
        lvActiveBattles = findViewById(R.id.lvActiveBattles);
        
        // Set default values
        etStakeAmount.setText("1000000"); // 1 USD* (6 decimals)
        tvBattleStatus.setText("Ready to battle");
        
        // Initially disable battle actions
        updateBattleUI(false);
    }
    
    private void requestPermissions() {
        String[] permissions = {
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.WRITE_EXTERNAL_STORAGE,
            Manifest.permission.READ_EXTERNAL_STORAGE,
            Manifest.permission.INTERNET
        };
        
        boolean allGranted = true;
        for (String permission : permissions) {
            if (ContextCompat.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED) {
                allGranted = false;
                break;
            }
        }
        
        if (!allGranted) {
            ActivityCompat.requestPermissions(this, permissions, PERMISSION_REQUEST_CODE);
        }
    }
    
    private void initializeServices() {
        try {
            battleManager = new BattleManager(this);
            battleManager.addBattleStateListener(this);
            
            audioManager = new AudioManager(this);
            recordingManager = new RecordingManager(this);
            
            // Initialize wallet (in production, use proper wallet integration)
            initializeWallet();
            
            Log.i(TAG, "Services initialized successfully");
        } catch (Exception e) {
            Log.e(TAG, "Error initializing services", e);
            showError("Failed to initialize app services");
        }
    }
    
    private void initializeWallet() {
        // In production, integrate with Phantom, Solflare, or other Solana wallets
        // For demo purposes, use hardcoded keys (NEVER do this in production!)
        String demoPublicKey = "11111111111111111111111111111112"; // System program
        String demoPrivateKey = "demo_private_key";
        
        battleManager.solanaManager.setUserWallet(demoPublicKey, demoPrivateKey);
        tvWalletInfo.setText("Wallet: " + demoPublicKey.substring(0, 8) + "...");
    }
    
    private void setupBattleFlow() {
        btnStartBattle.setOnClickListener(v -> startBattleChallenge());
        btnAcceptBattle.setOnClickListener(v -> showAcceptBattleDialog());
        btnRevealBattle.setOnClickListener(v -> revealBattleEntry());
        btnDiscoverBattles.setOnClickListener(v -> discoverBattles());
        
        FloatingActionButton fabRecord = findViewById(R.id.fabRecord);
        fabRecord.setOnClickListener(v -> toggleRecording());
    }
    
    private void startBattleChallenge() {
        String challengedUser = etChallengedUser.getText().toString().trim();
        String stakeAmountStr = etStakeAmount.getText().toString().trim();
        
        if (challengedUser.isEmpty()) {
            showError("Please enter a username to challenge");
            return;
        }
        
        if (stakeAmountStr.isEmpty()) {
            showError("Please enter stake amount");
            return;
        }
        
        try {
            long stakeAmount = Long.parseLong(stakeAmountStr);
            
            showProgress("Creating battle challenge...");
            updateBattleUI(false);
            
            battleManager.startBattleChallenge(challengedUser, stakeAmount)
                .thenRun(() -> runOnUiThread(() -> {
                    hideProgress();
                    showSuccess("Battle challenge created successfully!");
                    updateBattleStatus();
                }))
                .exceptionally(throwable -> {
                    runOnUiThread(() -> {
                        hideProgress();
                        updateBattleUI(true);
                        showError("Failed to create battle: " + throwable.getMessage());
                    });
                    return null;
                });
                
        } catch (NumberFormatException e) {
            showError("Invalid stake amount");
        }
    }
    
    private void showAcceptBattleDialog() {
        // Show dialog to enter battle ID to accept
        EditText input = new EditText(this);
        input.setHint("Enter Battle ID");
        
        new androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Accept Battle Challenge")
            .setView(input)
            .setPositiveButton("Accept", (dialog, which) -> {
                String battleIdStr = input.getText().toString().trim();
                if (!battleIdStr.isEmpty()) {
                    try {
                        long battleId = Long.parseLong(battleIdStr);
                        acceptBattleChallenge(battleId);
                    } catch (NumberFormatException e) {
                        showError("Invalid battle ID");
                    }
                }
            })
            .setNegativeButton("Cancel", null)
            .show();
    }
    
    private void acceptBattleChallenge(long battleId) {
        showProgress("Accepting battle challenge...");
        updateBattleUI(false);
        
        battleManager.acceptBattleChallenge(battleId, "Let's do this! 🔥")
            .thenRun(() -> runOnUiThread(() -> {
                hideProgress();
                showSuccess("Battle challenge accepted!");
                updateBattleStatus();
            }))
            .exceptionally(throwable -> {
                runOnUiThread(() -> {
                    hideProgress();
                    updateBattleUI(true);
                    showError("Failed to accept battle: " + throwable.getMessage());
                });
                return null;
            });
    }
    
    private void revealBattleEntry() {
        if (!battleManager.hasActiveBattle()) {
            showError("No active battle to reveal");
            return;
        }
        
        BattleIntegration.BattleSession battle = battleManager.getCurrentBattle();
        if (!battle.canReveal()) {
            showError("Battle reveal window has closed");
            return;
        }
        
        showProgress("Revealing battle entry...");
        
        battleManager.revealBattleEntry()
            .thenRun(() -> runOnUiThread(() -> {
                hideProgress();
                showSuccess("Battle entry revealed!");
                updateBattleStatus();
            }))
            .exceptionally(throwable -> {
                runOnUiThread(() -> {
                    hideProgress();
                    showError("Failed to reveal battle: " + throwable.getMessage());
                });
                return null;
            });
    }
    
    private void discoverBattles() {
        showProgress("Discovering battles...");
        
        battleManager.discoverBattles("musical")
            .thenAccept(battles -> runOnUiThread(() -> {
                hideProgress();
                showBattlesDialog(battles);
            }))
            .exceptionally(throwable -> {
                runOnUiThread(() -> {
                    hideProgress();
                    showError("Failed to discover battles: " + throwable.getMessage());
                });
                return null;
            });
    }
    
    private void showBattlesDialog(List<BattleManager.BattleInfo> battles) {
        if (battles.isEmpty()) {
            showInfo("No battles found in this category");
            return;
        }
        
        String[] battleTitles = new String[battles.size()];
        for (int i = 0; i < battles.size(); i++) {
            BattleManager.BattleInfo battle = battles.get(i);
            battleTitles[i] = "Battle #" + battle.battleId + " - " + 
                            battle.challenger + " vs " + battle.defender +
                            " (" + battle.stakeAmount + " USD*)";
        }
        
        new androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Available Battles")
            .setItems(battleTitles, (dialog, which) -> {
                BattleManager.BattleInfo selectedBattle = battles.get(which);
                showBattleDetails(selectedBattle);
            })
            .setNegativeButton("Close", null)
            .show();
    }
    
    private void showBattleDetails(BattleManager.BattleInfo battle) {
        String details = "Battle ID: " + battle.battleId + "\n" +
                        "Challenger: " + battle.challenger + "\n" +
                        "Defender: " + battle.defender + "\n" +
                        "Stake: " + battle.stakeAmount + " USD*\n" +
                        "Status: " + battle.status + "\n" +
                        "Twitter: " + battle.twitterUrl;
        
        new androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Battle Details")
            .setMessage(details)
            .setPositiveButton("Vote", (dialog, which) -> showVoteDialog(battle))
            .setNeutralButton("Accept", (dialog, which) -> acceptBattleChallenge(battle.battleId))
            .setNegativeButton("Close", null)
            .show();
    }
    
    private void showVoteDialog(BattleManager.BattleInfo battle) {
        String[] options = {"Vote for Challenger", "Vote for Defender", "Vote Tie"};
        
        new androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Submit Vote")
            .setItems(options, (dialog, which) -> {
                BattleIntegration.VoteChoice vote = switch (which) {
                    case 0 -> BattleIntegration.VoteChoice.CHALLENGER;
                    case 1 -> BattleIntegration.VoteChoice.DEFENDER;
                    default -> BattleIntegration.VoteChoice.TIE;
                };
                submitVote(battle.battleId, vote);
            })
            .setNegativeButton("Cancel", null)
            .show();
    }
    
    private void submitVote(long battleId, BattleIntegration.VoteChoice vote) {
        showProgress("Submitting vote...");
        
        battleManager.submitVote(battleId, vote, 0) // No stake for vote
            .thenRun(() -> runOnUiThread(() -> {
                hideProgress();
                showSuccess("Vote submitted successfully!");
            }))
            .exceptionally(throwable -> {
                runOnUiThread(() -> {
                    hideProgress();
                    showError("Failed to submit vote: " + throwable.getMessage());
                });
                return null;
            });
    }
    
    private void toggleRecording() {
        if (isRecording) {
            stopRecording();
        } else {
            startRecording();
        }
    }
    
    private void startRecording() {
        try {
            currentRecordingPath = recordingManager.startRecording();
            isRecording = true;
            
            FloatingActionButton fabRecord = findViewById(R.id.fabRecord);
            fabRecord.setImageResource(android.R.drawable.ic_media_pause);
            
            showInfo("Recording started...");
            
        } catch (Exception e) {
            Log.e(TAG, "Error starting recording", e);
            showError("Failed to start recording");
        }
    }
    
    private void stopRecording() {
        try {
            recordingManager.stopRecording();
            isRecording = false;
            
            FloatingActionButton fabRecord = findViewById(R.id.fabRecord);
            fabRecord.setImageResource(android.R.drawable.ic_btn_speak_now);
            
            showInfo("Recording stopped: " + currentRecordingPath);
            
        } catch (Exception e) {
            Log.e(TAG, "Error stopping recording", e);
            showError("Failed to stop recording");
        }
    }
    
    private void updateBattleStatus() {
        if (battleManager.hasActiveBattle()) {
            BattleIntegration.BattleSession battle = battleManager.getCurrentBattle();
            tvBattleStatus.setText("Battle #" + battle.battleId + " - " + battle.status);
            
            // Update UI based on battle state
            btnRevealBattle.setEnabled(battle.canReveal());
            updateBattleUI(true);
            
            // Start monitoring battle state
            battleManager.startBattleMonitoring();
        } else {
            tvBattleStatus.setText("No active battle");
            updateBattleUI(true);
        }
    }
    
    private void updateBattleUI(boolean enabled) {
        btnStartBattle.setEnabled(enabled && !battleManager.hasActiveBattle());
        btnAcceptBattle.setEnabled(enabled);
        btnDiscoverBattles.setEnabled(enabled);
    }
    
    // BattleStateListener implementation
    
    @Override
    public void onBattleCreated(BattleIntegration.BattleSession battle) {
        runOnUiThread(() -> {
            showSuccess("Battle challenge created! ID: " + battle.battleId);
            updateBattleStatus();
        });
    }
    
    @Override
    public void onBattleAccepted(BattleIntegration.BattleSession battle) {
        runOnUiThread(() -> {
            showSuccess("Battle challenge accepted!");
            updateBattleStatus();
        });
    }
    
    @Override
    public void onBattleRevealed(BattleIntegration.BattleSession battle) {
        runOnUiThread(() -> {
            showSuccess("Battle entry revealed!");
            updateBattleStatus();
        });
    }
    
    @Override
    public void onBattleCompleted(BattleIntegration.BattleSession battle) {
        runOnUiThread(() -> {
            showSuccess("Battle completed!");
            updateBattleStatus();
        });
    }
    
    @Override
    public void onBattleError(String error) {
        runOnUiThread(() -> showError(error));
    }
    
    // UI Helper methods
    
    private void showProgress(String message) {
        progressBar.setVisibility(View.VISIBLE);
        tvBattleStatus.setText(message);
    }
    
    private void hideProgress() {
        progressBar.setVisibility(View.GONE);
    }
    
    private void showError(String message) {
        Toast.makeText(this, "Error: " + message, Toast.LENGTH_LONG).show();
        Log.e(TAG, message);
    }
    
    private void showSuccess(String message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
        Log.i(TAG, message);
    }
    
    private void showInfo(String message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
        Log.i(TAG, message);
    }
    
    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (battleManager != null) {
            battleManager.removeBattleStateListener(this);
            battleManager.shutdown();
        }
        if (recordingManager != null) {
            recordingManager.cleanup();
        }
    }
    
    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        
        if (requestCode == PERMISSION_REQUEST_CODE) {
            boolean allGranted = true;
            for (int result : grantResults) {
                if (result != PackageManager.PERMISSION_GRANTED) {
                    allGranted = false;
                    break;
                }
            }
            
            if (!allGranted) {
                showError("All permissions are required for the app to function properly");
                finish();
            }
        }
    }
}