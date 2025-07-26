package raps.app;

import android.os.Environment;
import android.util.Log;
import com.yausername.youtubedl_android.YoutubeDL;
import com.yausername.youtubedl_android.YoutubeDLRequest;
import com.yausername.youtubedl_android.mapper.VideoInfo;
import java.io.File;

public class YouTubeDownloadService {
    private static final String TAG = "YouTubeDownload";
    
    public static class DownloadResult {
        public final String audioFilePath;
        public final String videoTitle;
        public final boolean success;
        public final String error;
        
        public DownloadResult(String audioFilePath, String videoTitle, boolean success, String error) {
            this.audioFilePath = audioFilePath;
            this.videoTitle = videoTitle;
            this.success = success;
            this.error = error;
        }
    }
    
    public interface DownloadCallback {
        void onProgress(float progress, String status);
        void onComplete(DownloadResult result);
        void onError(String error);
    }
    
    private static void waitWithRandomDelay(int minMs, int maxMs) {
        try {
            int randomDelay = minMs + (int)(Math.random() * (maxMs - minMs));
            Log.d(TAG, "Waiting " + randomDelay + "ms to avoid rate limiting...");
            Thread.sleep(randomDelay);
        } catch (InterruptedException e) {
            Log.w(TAG, "Delay interrupted", e);
            Thread.currentThread().interrupt();
        }
    }
    
    public static void downloadAudioFromYouTube(String videoUrl, DownloadCallback callback) {
        Log.d(TAG, "=== FAST STREAM EXTRACTION APPROACH ===");
        Log.d(TAG, "Original URL: " + videoUrl);
        
        callback.onProgress(10f, "Extracting stream URL...");
        
        StreamExtractorService.getStreamUrl(videoUrl, new StreamExtractorService.StreamCallback() {
            @Override
            public void onStreamReady(StreamExtractorService.StreamInfo streamInfo) {
                Log.d(TAG, "Stream URL extracted successfully: " + streamInfo.title);
                
                // Instead of downloading, we'll use the direct stream URL
                // This is much faster and bypasses YouTube's download restrictions
                callback.onComplete(new DownloadResult(
                    streamInfo.directUrl, // Use stream URL as "file path"
                    streamInfo.title,
                    true,
                    null
                ));
            }
            
            @Override
            public void onError(String error) {
                Log.e(TAG, "Stream extraction failed: " + error);
                
                // Fallback: Try the old youtubedl-android approach as last resort
                Log.d(TAG, "Falling back to youtubedl-android...");
                callback.onProgress(50f, "Trying fallback method...");
                tryFallbackDownload(videoUrl, callback);
            }
        });
    }
    
    private static void tryFallbackDownload(String videoUrl, DownloadCallback callback) {
        // Create download directory for fallback
        File downloadDir = new File(Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS), "raps-app");
        if (!downloadDir.exists()) {
            downloadDir.mkdirs();
        }
        
        new Thread(() -> {
            try {
                // Simple fallback approach
                YoutubeDLRequest request = new YoutubeDLRequest(videoUrl);
                request.addOption("-o", downloadDir.getAbsolutePath() + "/fallback_%(id)s.%(ext)s");
                
                String processId = "fallback_" + System.currentTimeMillis();
                YoutubeDL.getInstance().execute(request, processId);
                
                String audioFilePath = findAnyAudioFile(downloadDir);
                if (audioFilePath != null) {
                    String fileName = new File(audioFilePath).getName();
                    String videoTitle = fileName.replaceAll("\\.[^.]*$", "");
                    callback.onComplete(new DownloadResult(audioFilePath, videoTitle, true, null));
                } else {
                    callback.onError("All methods failed - video may be restricted");
                }
                
            } catch (Exception e) {
                Log.e(TAG, "Fallback also failed", e);
                callback.onError("All extraction methods failed: " + e.getMessage());
            }
        }).start();
    }
    
    private static boolean tryTvClientDownload(String videoUrl, File downloadDir, DownloadCallback callback) {
        try {
            Log.d(TAG, "Attempting TV client download");
            callback.onProgress(10f, "Trying TV client...");
            
            // Random delay before request
            waitWithRandomDelay(1000, 3000);
            
            File[] filesBefore = downloadDir.listFiles();
            Log.d(TAG, "Files before TV download: " + (filesBefore != null ? filesBefore.length : 0));
            
            YoutubeDLRequest request = new YoutubeDLRequest(videoUrl);
            // Remove incompatible options
            request.addOption("-f", "140/bestaudio[ext=m4a]/bestaudio");
            request.addOption("-o", downloadDir.getAbsolutePath() + "/tv_%(id)s.%(ext)s");
            
            String processId = "tv_" + System.currentTimeMillis();
            Log.d(TAG, "Executing TV download with process ID: " + processId);
            
            YoutubeDL.getInstance().execute(request, processId);
            
            File[] filesAfter = downloadDir.listFiles();
            Log.d(TAG, "Files after TV download: " + (filesAfter != null ? filesAfter.length : 0));
            
            String audioFilePath = findAnyAudioFile(downloadDir);
            if (audioFilePath != null) {
                Log.d(TAG, "TV client SUCCESS: " + audioFilePath);
                String fileName = new File(audioFilePath).getName();
                String videoTitle = fileName.replaceAll("\\.[^.]*$", "");
                callback.onComplete(new DownloadResult(audioFilePath, videoTitle, true, null));
                return true;
            } else {
                Log.w(TAG, "TV client completed but no file found");
                return false;
            }
            
        } catch (Exception e) {
            Log.e(TAG, "TV client download failed", e);
            return false;
        }
    }
    
    private static boolean tryWebClientDownload(String videoUrl, File downloadDir, DownloadCallback callback) {
        try {
            Log.d(TAG, "Attempting web client download");
            callback.onProgress(30f, "Trying web client...");
            
            // Random delay before request
            waitWithRandomDelay(2000, 4000);
            
            YoutubeDLRequest request = new YoutubeDLRequest(videoUrl);
            // Don't specify client - let library choose
            request.addOption("-f", "worstaudio/worst"); // Try worst quality to avoid restrictions
            request.addOption("-o", downloadDir.getAbsolutePath() + "/web_%(id)s.%(ext)s");
            
            String processId = "web_" + System.currentTimeMillis();
            Log.d(TAG, "Executing web download with process ID: " + processId);
            
            YoutubeDL.getInstance().execute(request, processId);
            
            String audioFilePath = findAnyAudioFile(downloadDir);
            if (audioFilePath != null) {
                Log.d(TAG, "Web client SUCCESS: " + audioFilePath);
                String fileName = new File(audioFilePath).getName();
                String videoTitle = fileName.replaceAll("\\.[^.]*$", "");
                callback.onComplete(new DownloadResult(audioFilePath, videoTitle, true, null));
                return true;
            } else {
                Log.w(TAG, "Web client completed but no file found");
                return false;
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Web client download failed", e);
            return false;
        }
    }
    
    private static boolean tryAndroidClientDownload(String videoUrl, File downloadDir, DownloadCallback callback) {
        try {
            Log.d(TAG, "Attempting basic download");
            callback.onProgress(50f, "Trying basic download...");
            
            YoutubeDLRequest request = new YoutubeDLRequest(videoUrl);
            // Minimal options only
            request.addOption("-o", downloadDir.getAbsolutePath() + "/basic_%(id)s.%(ext)s");
            
            String processId = "basic_" + System.currentTimeMillis();
            Log.d(TAG, "Executing basic download with process ID: " + processId);
            
            YoutubeDL.getInstance().execute(request, processId);
            
            String audioFilePath = findAnyAudioFile(downloadDir);
            if (audioFilePath != null) {
                Log.d(TAG, "Basic download SUCCESS: " + audioFilePath);
                String fileName = new File(audioFilePath).getName();
                String videoTitle = fileName.replaceAll("\\.[^.]*$", "");
                callback.onComplete(new DownloadResult(audioFilePath, videoTitle, true, null));
                return true;
            } else {
                Log.w(TAG, "Basic download completed but no file found");
                return false;
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Basic download failed", e);
            return false;
        }
    }
    
    private static boolean tryEmbeddedPlayerDownload(String videoUrl, File downloadDir, DownloadCallback callback) {
        try {
            Log.d(TAG, "Attempting format list check");
            callback.onProgress(70f, "Checking available formats...");
            
            YoutubeDLRequest request = new YoutubeDLRequest(videoUrl);
            request.addOption("--list-formats");
            
            String processId = "list_" + System.currentTimeMillis();
            Log.d(TAG, "Executing format list with process ID: " + processId);
            
            YoutubeDL.getInstance().execute(request, processId);
            
            // If list-formats worked, the video is accessible - try simple download
            YoutubeDLRequest downloadRequest = new YoutubeDLRequest(videoUrl);
            downloadRequest.addOption("-f", "18/17/36/5/6"); // Try specific low-quality formats
            downloadRequest.addOption("-o", downloadDir.getAbsolutePath() + "/format_%(id)s.%(ext)s");
            
            String downloadProcessId = "format_" + System.currentTimeMillis();
            YoutubeDL.getInstance().execute(downloadRequest, downloadProcessId);
            
            String audioFilePath = findAnyAudioFile(downloadDir);
            if (audioFilePath != null) {
                Log.d(TAG, "Format-specific download SUCCESS: " + audioFilePath);
                String fileName = new File(audioFilePath).getName();
                String videoTitle = fileName.replaceAll("\\.[^.]*$", "");
                callback.onComplete(new DownloadResult(audioFilePath, videoTitle, true, null));
                return true;
            } else {
                Log.w(TAG, "Format-specific download completed but no file found");
                return false;
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Format-specific download failed", e);
            return false;
        }
    }
    
    private static boolean tryMinimalDownload(String videoUrl, File downloadDir, DownloadCallback callback) {
        try {
            Log.d(TAG, "Attempting absolute minimal download");
            callback.onProgress(90f, "Trying absolute minimal...");
            
            YoutubeDLRequest request = new YoutubeDLRequest(videoUrl);
            // Just the URL, no format selection at all
            request.addOption("-o", downloadDir.getAbsolutePath() + "/minimal_%(id)s.%(ext)s");
            
            String processId = "minimal_" + System.currentTimeMillis();
            Log.d(TAG, "Executing minimal download with process ID: " + processId);
            
            YoutubeDL.getInstance().execute(request, processId);
            
            String audioFilePath = findAnyAudioFile(downloadDir);
            if (audioFilePath != null) {
                Log.d(TAG, "Minimal download SUCCESS: " + audioFilePath);
                String fileName = new File(audioFilePath).getName();
                String videoTitle = fileName.replaceAll("\\.[^.]*$", "");
                callback.onComplete(new DownloadResult(audioFilePath, videoTitle, true, null));
                return true;
            } else {
                Log.w(TAG, "Minimal download completed but no file found");
                return false;
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Minimal download failed", e);
            return false;
        }
    }
    
    private static String normalizeYouTubeUrl(String url) {
        // Remove any spaces or invalid characters
        url = url.trim();
        
        // Handle various YouTube URL formats
        if (url.contains("youtube.com/watch?v=")) {
            return url.split("&")[0]; // Remove extra parameters
        } else if (url.contains("youtu.be/")) {
            String videoId = url.substring(url.lastIndexOf("/") + 1);
            if (videoId.contains("?")) {
                videoId = videoId.split("\\?")[0]; // Remove parameters
            }
            return "https://www.youtube.com/watch?v=" + videoId;
        } else if (url.contains("youtube.com/") && !url.contains("watch?v=")) {
            // Handle cases like "youtube.com/2xnqp6CPM8o"
            String videoId = url.substring(url.lastIndexOf("/") + 1);
            if (videoId.contains("?")) {
                videoId = videoId.split("\\?")[0];
            }
            return "https://www.youtube.com/watch?v=" + videoId;
        }
        
        return url;
    }
    
    private static String findAnyAudioFile(File directory) {
        Log.d(TAG, "Searching for audio files in: " + directory.getAbsolutePath());
        File[] files = directory.listFiles((dir, name) -> {
            String lowerName = name.toLowerCase();
            return lowerName.endsWith(".mp3") || lowerName.endsWith(".m4a") || 
                   lowerName.endsWith(".webm") || lowerName.endsWith(".ogg") ||
                   lowerName.endsWith(".aac") || lowerName.endsWith(".opus");
        });
        
        if (files != null && files.length > 0) {
            // Get the most recently created file
            File mostRecent = files[0];
            for (File file : files) {
                if (file.lastModified() > mostRecent.lastModified()) {
                    mostRecent = file;
                }
            }
            Log.d(TAG, "Found most recent audio file: " + mostRecent.getName());
            return mostRecent.getAbsolutePath();
        }
        
        Log.d(TAG, "No audio files found in directory");
        return null;
    }
}