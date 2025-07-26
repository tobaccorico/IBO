package raps.app;

import android.app.Dialog;
import android.content.Context;
import android.os.Bundle;
import android.view.View;
import android.widget.*;
import androidx.annotation.NonNull;
import com.wdullaer.materialdatetimepicker.date.DatePickerDialog;
import com.wdullaer.materialdatetimepicker.time.TimePickerDialog;
import java.util.Calendar;
import java.util.Date;

public class BattleConfigDialog extends Dialog {
    private static final String TAG = "BattleConfigDialog";
    
    // UI Components
    private EditText etChallengedUser;
    private EditText etBattleMessage;
    private EditText etStakeAmount;
    private TextView tvBattleWindowStart;
    private TextView tvBattleWindowEnd;
    private TextView tvWindowDuration;
    private Button btnSetStartTime;
    private Button btnSetEndTime;
    private CheckBox cbQuickDurations;
    private RadioGroup rgQuickDurations;
    private RadioButton rb1Hour, rb6Hours, rb24Hours, rb7Days;
    private Spinner spinnerBattleType;
    private Switch switchPublicBattle;
    private Button btnCreateBattle;
    private Button btnCancel;
    
    // State
    private Calendar battleWindowStart;
    private Calendar battleWindowEnd;
    private BattleConfigCallback callback;
    
    public interface BattleConfigCallback {
        void onBattleConfigured(BattleConfiguration config);
        void onCancelled();
    }
    
    public static class BattleConfiguration {
        public String challengedUser;
        public String battleMessage;
        public long stakeAmount;
        public long battleWindowStartTimestamp; // Unix timestamp
        public long battleWindowEndTimestamp;   // Unix timestamp
        public long windowDurationHours;
        public String battleType;
        public boolean isPublic;
        
        public BattleConfiguration() {
            // Set defaults
            this.stakeAmount = 1000000; // 1 USD* in micro units
            this.isPublic = true;
            this.battleType = "Musical";
        }
        
        public boolean isValid() {
            return challengedUser != null && !challengedUser.trim().isEmpty() &&
                   stakeAmount > 0 &&
                   battleWindowStartTimestamp > 0 &&
                   battleWindowEndTimestamp > battleWindowStartTimestamp &&
                   windowDurationHours > 0;
        }
        
        public long getWindowDurationSeconds() {
            return (battleWindowEndTimestamp - battleWindowStartTimestamp);
        }
        
        public long getWindowDurationHours() {
            return getWindowDurationSeconds() / 3600;
        }
    }
    
    public BattleConfigDialog(@NonNull Context context, BattleConfigCallback callback) {
        super(context);
        this.callback = callback;
        this.battleWindowStart = Calendar.getInstance();
        this.battleWindowEnd = Calendar.getInstance();
        
        // Set default battle window (start now, end in 24 hours)
        this.battleWindowStart.add(Calendar.MINUTE, 5); // Start in 5 minutes
        this.battleWindowEnd.add(Calendar.HOUR, 24);    // End in 24 hours
    }
    
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.dialog_battle_config);
        
        initializeViews();
        setupEventListeners();
        updateTimeDisplays();
        setupBattleTypeSpinner();
    }
    
    private void initializeViews() {
        etChallengedUser = findViewById(R.id.etChallengedUser);
        etBattleMessage = findViewById(R.id.etBattleMessage);
        etStakeAmount = findViewById(R.id.etStakeAmount);
        tvBattleWindowStart = findViewById(R.id.tvBattleWindowStart);
        tvBattleWindowEnd = findViewById(R.id.tvBattleWindowEnd);
        tvWindowDuration = findViewById(R.id.tvWindowDuration);
        btnSetStartTime = findViewById(R.id.btnSetStartTime);
        btnSetEndTime = findViewById(R.id.btnSetEndTime);
        cbQuickDurations = findViewById(R.id.cbQuickDurations);
        rgQuickDurations = findViewById(R.id.rgQuickDurations);
        rb1Hour = findViewById(R.id.rb1Hour);
        rb6Hours = findViewById(R.id.rb6Hours);
        rb24Hours = findViewById(R.id.rb24Hours);
        rb7Days = findViewById(R.id.rb7Days);
        spinnerBattleType = findViewById(R.id.spinnerBattleType);
        switchPublicBattle = findViewById(R.id.switchPublicBattle);
        btnCreateBattle = findViewById(R.id.btnCreateBattle);
        btnCancel = findViewById(R.id.btnCancel);
        
        // Set default values
        etStakeAmount.setText("1000000"); // 1 USD* default
        etBattleMessage.setText("Let's settle this with bars! 🎤🔥");
        switchPublicBattle.setChecked(true);
        rb24Hours.setChecked(true); // Default to 24 hours
    }
    
    private void setupEventListeners() {
        btnSetStartTime.setOnClickListener(v -> showDateTimePicker(true));
        btnSetEndTime.setOnClickListener(v -> showDateTimePicker(false));
        
        cbQuickDurations.setOnCheckedChangeListener((buttonView, isChecked) -> {
            rgQuickDurations.setVisibility(isChecked ? View.VISIBLE : View.GONE);
            btnSetStartTime.setEnabled(!isChecked);
            btnSetEndTime.setEnabled(!isChecked);
            
            if (isChecked) {
                updateQuickDuration();
            }
        });
        
        rgQuickDurations.setOnCheckedChangeListener((group, checkedId) -> {
            if (cbQuickDurations.isChecked()) {
                updateQuickDuration();
            }
        });
        
        btnCreateBattle.setOnClickListener(v -> createBattle());
        btnCancel.setOnClickListener(v -> {
            if (callback != null) callback.onCancelled();
            dismiss();
        });
        
        // Real-time validation
        etChallengedUser.addTextChangedListener(new SimpleTextWatcher() {
            @Override
            public void onTextChanged(CharSequence s, int start, int before, int count) {
                validateInput();
            }
        });
        
        etStakeAmount.addTextChangedListener(new SimpleTextWatcher() {
            @Override
            public void onTextChanged(CharSequence s, int start, int before, int count) {
                validateInput();
            }
        });
    }
    
    private void setupBattleTypeSpinner() {
        String[] battleTypes = {
            "Musical - Hip Hop/Rap Battle",
            "Musical - Freestyle Cypher", 
            "Musical - Beat Battle",
            "Creative - Poetry Battle",
            "Creative - Comedy Battle",
            "Gaming - Esports Challenge",
            "Sports - Athletic Challenge",
            "Professional - Business Pitch",
            "Educational - Debate Challenge",
            "General - Open Challenge"
        };
        
        ArrayAdapter<String> adapter = new ArrayAdapter<>(
            getContext(), 
            android.R.layout.simple_spinner_item, 
            battleTypes
        );
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spinnerBattleType.setAdapter(adapter);
    }
    
    private void showDateTimePicker(boolean isStartTime) {
        Calendar current = isStartTime ? battleWindowStart : battleWindowEnd;
        
        // Show date picker first
        DatePickerDialog datePickerDialog = DatePickerDialog.newInstance(
            (view, year, monthOfYear, dayOfMonth) -> {
                current.set(Calendar.YEAR, year);
                current.set(Calendar.MONTH, monthOfYear);
                current.set(Calendar.DAY_OF_MONTH, dayOfMonth);
                
                // Then show time picker
                TimePickerDialog timePickerDialog = TimePickerDialog.newInstance(
                    (timeView, hourOfDay, minute, second) -> {
                        current.set(Calendar.HOUR_OF_DAY, hourOfDay);
                        current.set(Calendar.MINUTE, minute);
                        current.set(Calendar.SECOND, 0);
                        
                        updateTimeDisplays();
                        validateInput();
                    },
                    current.get(Calendar.HOUR_OF_DAY),
                    current.get(Calendar.MINUTE),
                    false
                );
                timePickerDialog.show(((MainActivity) getContext()).getFragmentManager(), "TimePicker");
            },
            current.get(Calendar.YEAR),
            current.get(Calendar.MONTH),
            current.get(Calendar.DAY_OF_MONTH)
        );
        
        // Set minimum date to now
        Calendar minDate = Calendar.getInstance();
        datePickerDialog.setMinDate(minDate);
        
        // Set maximum date to 30 days from now
        Calendar maxDate = Calendar.getInstance();
        maxDate.add(Calendar.DAY_OF_MONTH, 30);
        datePickerDialog.setMaxDate(maxDate);
        
        datePickerDialog.show(((MainActivity) getContext()).getFragmentManager(), "DatePicker");
    }
    
    private void updateQuickDuration() {
        Calendar now = Calendar.getInstance();
        battleWindowStart.setTime(now.getTime());
        battleWindowStart.add(Calendar.MINUTE, 5); // Start in 5 minutes
        
        battleWindowEnd.setTime(battleWindowStart.getTime());
        
        int checkedId = rgQuickDurations.getCheckedRadioButtonId();
        if (checkedId == R.id.rb1Hour) {
            battleWindowEnd.add(Calendar.HOUR, 1);
        } else if (checkedId == R.id.rb6Hours) {
            battleWindowEnd.add(Calendar.HOUR, 6);
        } else if (checkedId == R.id.rb24Hours) {
            battleWindowEnd.add(Calendar.HOUR, 24);
        } else if (checkedId == R.id.rb7Days) {
            battleWindowEnd.add(Calendar.DAY_OF_MONTH, 7);
        }
        
        updateTimeDisplays();
        validateInput();
    }
    
    private void updateTimeDisplays() {
        java.text.SimpleDateFormat formatter = new java.text.SimpleDateFormat("MMM dd, yyyy 'at' HH:mm");
        
        tvBattleWindowStart.setText("Start: " + formatter.format(battleWindowStart.getTime()));
        tvBattleWindowEnd.setText("End: " + formatter.format(battleWindowEnd.getTime()));
        
        // Calculate and display duration
        long durationMillis = battleWindowEnd.getTimeInMillis() - battleWindowStart.getTimeInMillis();
        long durationHours = durationMillis / (1000 * 60 * 60);
        long durationDays = durationHours / 24;
        
        String durationText;
        if (durationDays > 0) {
            durationText = String.format("Duration: %d days, %d hours", durationDays, durationHours % 24);
        } else {
            durationText = String.format("Duration: %d hours", durationHours);
        }
        tvWindowDuration.setText(durationText);
    }
    
    private void validateInput() {
        boolean isValid = true;
        
        // Validate challenged user
        String challengedUser = etChallengedUser.getText().toString().trim();
        if (challengedUser.isEmpty()) {
            etChallengedUser.setError("Username required");
            isValid = false;
        } else {
            etChallengedUser.setError(null);
        }
        
        // Validate stake amount
        String stakeAmountStr = etStakeAmount.getText().toString().trim();
        if (stakeAmountStr.isEmpty()) {
            etStakeAmount.setError("Stake amount required");
            isValid = false;
        } else {
            try {
                long stakeAmount = Long.parseLong(stakeAmountStr);
                if (stakeAmount < 100000) { // Minimum 0.1 USD*
                    etStakeAmount.setError("Minimum stake: 100,000 micro USD*");
                    isValid = false;
                } else {
                    etStakeAmount.setError(null);
                }
            } catch (NumberFormatException e) {
                etStakeAmount.setError("Invalid amount");
                isValid = false;
            }
        }
        
        // Validate time window
        if (battleWindowStart.getTimeInMillis() <= System.currentTimeMillis()) {
            isValid = false;
        }
        
        if (battleWindowEnd.getTimeInMillis() <= battleWindowStart.getTimeInMillis()) {
            isValid = false;
        }
        
        // Update button state
        btnCreateBattle.setEnabled(isValid);
    }
    
    private void createBattle() {
        BattleConfiguration config = new BattleConfiguration();
        config.challengedUser = etChallengedUser.getText().toString().trim();
        config.battleMessage = etBattleMessage.getText().toString().trim();
        config.stakeAmount = Long.parseLong(etStakeAmount.getText().toString().trim());
        config.battleWindowStartTimestamp = battleWindowStart.getTimeInMillis() / 1000; // Convert to Unix timestamp
        config.battleWindowEndTimestamp = battleWindowEnd.getTimeInMillis() / 1000;
        config.windowDurationHours = config.getWindowDurationHours();
        config.battleType = spinnerBattleType.getSelectedItem().toString().split(" - ")[0];
        config.isPublic = switchPublicBattle.isChecked();
        
        if (config.isValid() && callback != null) {
            callback.onBattleConfigured(config);
            dismiss();
        } else {
            Toast.makeText(getContext(), "Please check all fields", Toast.LENGTH_SHORT).show();
        }
    }
    
    // Simple TextWatcher implementation
    private abstract class SimpleTextWatcher implements android.text.TextWatcher {
        @Override
        public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
        
        @Override
        public void afterTextChanged(android.text.Editable s) {}
    }
}