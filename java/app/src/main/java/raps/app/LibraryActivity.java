package raps.app;

import android.app.AlertDialog;
import android.content.Intent;
import android.media.MediaPlayer;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.TextView;
import android.widget.Toast;
import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.List;
import java.util.Locale;

public class LibraryActivity extends AppCompatActivity {
    private static final String TAG = "LibraryActivity";
    
    private RecyclerView recyclerView;
    private RecordingAdapter adapter;
    private RecordingManager recordingManager;
    private MediaPlayer mediaPlayer;
    
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_library);
        
        initializeViews();
        loadRecordings();
    }
    
    private void initializeViews() {
        recyclerView = findViewById(R.id.rv_recordings);
        recyclerView.setLayoutManager(new LinearLayoutManager(this));
        
        recordingManager = new RecordingManager(this);
        
        // Back button
        findViewById(R.id.btn_back).setOnClickListener(v -> finish());
    }
    
    private void loadRecordings() {
        List<RecordingData> recordings = recordingManager.getAllRecordings();
        adapter = new RecordingAdapter(recordings);
        recyclerView.setAdapter(adapter);
    }
    
    private class RecordingAdapter extends RecyclerView.Adapter<RecordingAdapter.RecordingViewHolder> {
        private List<RecordingData> recordings;
        private SimpleDateFormat dateFormat = new SimpleDateFormat("MMM dd, yyyy HH:mm", Locale.getDefault());
        
        public RecordingAdapter(List<RecordingData> recordings) {
            this.recordings = recordings;
        }
        
        @NonNull
        @Override
        public RecordingViewHolder onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            View view = LayoutInflater.from(parent.getContext())
                    .inflate(R.layout.item_recording, parent, false);
            return new RecordingViewHolder(view);
        }
        
        @Override
        public void onBindViewHolder(@NonNull RecordingViewHolder holder, int position) {
            RecordingData recording = recordings.get(position);
            
            holder.tvTitle.setText(recording.getVideoTitle() != null ? 
                recording.getVideoTitle() : "Untitled Recording");
            holder.tvDate.setText(dateFormat.format(recording.getRecordingDate()));
            holder.tvLyrics.setText(recording.getLyrics() != null ? 
                recording.getLyrics() : "No lyrics available");
            
            // Play button
            holder.btnPlay.setOnClickListener(v -> playRecording(recording));
            
            // Delete button
            holder.btnDelete.setOnClickListener(v -> confirmDelete(recording, position));
            
            // Edit lyrics button
            holder.btnEditLyrics.setOnClickListener(v -> editLyrics(recording));
        }
        
        @Override
        public int getItemCount() {
            return recordings.size();
        }
        
        public void removeItem(int position) {
            recordings.remove(position);
            notifyItemRemoved(position);
        }
        
        class RecordingViewHolder extends RecyclerView.ViewHolder {
            TextView tvTitle, tvDate, tvLyrics;
            Button btnPlay, btnDelete, btnEditLyrics;
            
            public RecordingViewHolder(@NonNull View itemView) {
                super(itemView);
                tvTitle = itemView.findViewById(R.id.tv_recording_title);
                tvDate = itemView.findViewById(R.id.tv_recording_date);
                tvLyrics = itemView.findViewById(R.id.tv_recording_lyrics);
                btnPlay = itemView.findViewById(R.id.btn_play_recording);
                btnDelete = itemView.findViewById(R.id.btn_delete_recording);
                btnEditLyrics = itemView.findViewById(R.id.btn_edit_lyrics);
            }
        }
    }
    
    private void playRecording(RecordingData recording) {
        if (recording.getRecordingFilePath() == null) {
            Toast.makeText(this, "Recording file not found", Toast.LENGTH_SHORT).show();
            return;
        }
        
        try {
            if (mediaPlayer != null) {
                mediaPlayer.release();
            }
            
            mediaPlayer = new MediaPlayer();
            mediaPlayer.setDataSource(recording.getRecordingFilePath());
            mediaPlayer.setOnCompletionListener(mp -> {
                Toast.makeText(LibraryActivity.this, "Playback completed", Toast.LENGTH_SHORT).show();
            });
            mediaPlayer.prepare();
            mediaPlayer.start();
            
            Toast.makeText(this, "Playing recording...", Toast.LENGTH_SHORT).show();
            
        } catch (IOException e) {
            Toast.makeText(this, "Error playing recording", Toast.LENGTH_SHORT).show();
        }
    }
    
    private void confirmDelete(RecordingData recording, int position) {
        new AlertDialog.Builder(this)
                .setTitle("Delete Recording")
                .setMessage("Are you sure you want to delete this recording?")
                .setPositiveButton("Delete", (dialog, which) -> {
                    if (recordingManager.deleteRecording(recording)) {
                        adapter.removeItem(position);
                        Toast.makeText(this, "Recording deleted", Toast.LENGTH_SHORT).show();
                    } else {
                        Toast.makeText(this, "Error deleting recording", Toast.LENGTH_SHORT).show();
                    }
                })
                .setNegativeButton("Cancel", null)
                .show();
    }
    
    private void editLyrics(RecordingData recording) {
        // For now, just show a toast - we can implement this later
        Toast.makeText(this, "Lyrics editing coming soon!", Toast.LENGTH_SHORT).show();
    }
    
    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == 1001 && resultCode == RESULT_OK) {
            // Refresh the list when lyrics are updated
            loadRecordings();
        }
    }
    
    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (mediaPlayer != null) {
            mediaPlayer.release();
        }
    }
}