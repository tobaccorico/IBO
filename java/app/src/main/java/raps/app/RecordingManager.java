package raps.app;

import android.content.Context;
import android.os.Environment;
import android.util.Log;
import com.google.gson.Gson;
import com.google.gson.reflect.TypeToken;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.IOException;
import java.lang.reflect.Type;
import java.util.ArrayList;
import java.util.List;

public class RecordingManager {
    private static final String TAG = "RecordingManager";
    private static final String RECORDINGS_DIR = "raps-app-recordings";
    private static final String RECORDINGS_INDEX_FILE = "recordings_index.json";
    
    private Context context;
    private File recordingsDir;
    private Gson gson;
    
    public RecordingManager(Context context) {
        this.context = context;
        this.gson = new Gson();
        initializeDirectories();
    }
    
    private void initializeDirectories() {
        // Create recordings directory in app's external files directory
        File externalDir = context.getExternalFilesDir(null);
        recordingsDir = new File(externalDir, RECORDINGS_DIR);
        
        if (!recordingsDir.exists()) {
            recordingsDir.mkdirs();
            Log.d(TAG, "Created recordings directory: " + recordingsDir.getAbsolutePath());
        }
    }
    
    public File saveRecording(List<Short> audioData, String fileName) {
        try {
            File recordingFile = new File(recordingsDir, fileName + ".wav");
            
            // Convert short array to WAV file
            FileOutputStream fos = new FileOutputStream(recordingFile);
            
            // Write WAV header
            writeWavHeader(fos, audioData.size() * 2);
            
            // Write audio data
            for (Short sample : audioData) {
                fos.write(sample & 0xff);
                fos.write((sample >> 8) & 0xff);
            }
            
            fos.close();
            Log.d(TAG, "Recording saved: " + recordingFile.getAbsolutePath());
            return recordingFile;
            
        } catch (IOException e) {
            Log.e(TAG, "Error saving recording", e);
            return null;
        }
    }
    
    private void writeWavHeader(FileOutputStream out, int dataSize) throws IOException {
        int sampleRate = 44100;
        int channels = 1;
        int bitsPerSample = 16;
        
        // WAV header
        out.write("RIFF".getBytes());
        out.write(intToByteArray(36 + dataSize), 0, 4);
        out.write("WAVE".getBytes());
        out.write("fmt ".getBytes());
        out.write(intToByteArray(16), 0, 4); // PCM header size
        out.write(shortToByteArray((short) 1), 0, 2); // PCM format
        out.write(shortToByteArray((short) channels), 0, 2);
        out.write(intToByteArray(sampleRate), 0, 4);
        out.write(intToByteArray(sampleRate * channels * bitsPerSample / 8), 0, 4);
        out.write(shortToByteArray((short) (channels * bitsPerSample / 8)), 0, 2);
        out.write(shortToByteArray((short) bitsPerSample), 0, 2);
        out.write("data".getBytes());
        out.write(intToByteArray(dataSize), 0, 4);
    }
    
    private byte[] intToByteArray(int value) {
        return new byte[] {
            (byte)(value & 0xff),
            (byte)((value >> 8) & 0xff),
            (byte)((value >> 16) & 0xff),
            (byte)((value >> 24) & 0xff)
        };
    }
    
    private byte[] shortToByteArray(short value) {
        return new byte[] {
            (byte)(value & 0xff),
            (byte)((value >> 8) & 0xff)
        };
    }
    
    public void saveRecordingData(RecordingData recording) {
        List<RecordingData> recordings = getAllRecordings();
        
        // Update existing or add new
        boolean updated = false;
        for (int i = 0; i < recordings.size(); i++) {
            if (recordings.get(i).getId().equals(recording.getId())) {
                recordings.set(i, recording);
                updated = true;
                break;
            }
        }
        
        if (!updated) {
            recordings.add(recording);
        }
        
        saveRecordingsIndex(recordings);
    }
    
    public List<RecordingData> getAllRecordings() {
        File indexFile = new File(recordingsDir, RECORDINGS_INDEX_FILE);
        if (!indexFile.exists()) {
            return new ArrayList<>();
        }
        
        try {
            FileReader reader = new FileReader(indexFile);
            Type listType = new TypeToken<List<RecordingData>>(){}.getType();
            List<RecordingData> recordings = gson.fromJson(reader, listType);
            reader.close();
            
            return recordings != null ? recordings : new ArrayList<>();
        } catch (Exception e) {
            Log.e(TAG, "Error loading recordings index", e);
            return new ArrayList<>();
        }
    }
    
    private void saveRecordingsIndex(List<RecordingData> recordings) {
        File indexFile = new File(recordingsDir, RECORDINGS_INDEX_FILE);
        try {
            FileWriter writer = new FileWriter(indexFile);
            gson.toJson(recordings, writer);
            writer.close();
            Log.d(TAG, "Recordings index saved");
        } catch (IOException e) {
            Log.e(TAG, "Error saving recordings index", e);
        }
    }
    
    public boolean deleteRecording(RecordingData recording) {
        try {
            // Delete audio files
            if (recording.getRecordingFilePath() != null) {
                File recordingFile = new File(recording.getRecordingFilePath());
                if (recordingFile.exists()) {
                    recordingFile.delete();
                }
            }
            
            // Remove from index
            List<RecordingData> recordings = getAllRecordings();
            recordings.removeIf(r -> r.getId().equals(recording.getId()));
            saveRecordingsIndex(recordings);
            
            Log.d(TAG, "Recording deleted: " + recording.getId());
            return true;
        } catch (Exception e) {
            Log.e(TAG, "Error deleting recording", e);
            return false;
        }
    }
    
    public File getRecordingsDirectory() {
        return recordingsDir;
    }
}