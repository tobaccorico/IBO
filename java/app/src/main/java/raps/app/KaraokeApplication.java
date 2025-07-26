package raps.app;

import android.app.Application;
import android.util.Log;
import com.yausername.youtubedl_android.YoutubeDL;
import com.yausername.youtubedl_android.YoutubeDLException;
import com.yausername.ffmpeg.FFmpeg;

public class KaraokeApplication extends Application {
    private static final String TAG = "RapsApp";
    
    @Override
    public void onCreate() {
        super.onCreate();
        initializeLibraries();
    }
    
    private void initializeLibraries() {
        try {
            // Initialize YoutubeDL and FFmpeg
            YoutubeDL.getInstance().init(this);
            FFmpeg.getInstance().init(this);
            Log.d(TAG, "YoutubeDL and FFmpeg initialized successfully");
            
        } catch (YoutubeDLException e) {
            Log.e(TAG, "Failed to initialize libraries", e);
        }
    }
}