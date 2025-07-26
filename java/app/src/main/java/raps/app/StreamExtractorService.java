package raps.app;

import android.util.Log;
import org.json.JSONObject;
import org.json.JSONArray;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class StreamExtractorService {
    private static final String TAG = "StreamExtractor";
    
    public static class StreamInfo {
        public final String directUrl;
        public final String title;
        public final String videoId;
        public final boolean success;
        public final String error;
        
        public StreamInfo(String directUrl, String title, String videoId, boolean success, String error) {
            this.directUrl = directUrl;
            this.title = title;
            this.videoId = videoId;
            this.success = success;
            this.error = error;
        }
    }
    
    public interface StreamCallback {
        void onStreamReady(StreamInfo streamInfo);
        void onError(String error);
    }
    
    public static void getStreamUrl(String youtubeUrl, StreamCallback callback) {
        Log.d(TAG, "=== FAST STREAM EXTRACTION ===");
        Log.d(TAG, "Input URL: " + youtubeUrl);
        
        new Thread(() -> {
            try {
                String videoId = extractVideoId(youtubeUrl);
                if (videoId == null) {
                    callback.onError("Invalid YouTube URL");
                    return;
                }
                
                Log.d(TAG, "Video ID: " + videoId);
                
                // Try multiple extraction methods
                StreamInfo result = null;
                
                // Method 1: Direct YouTube API approach
                result = tryDirectApiExtraction(videoId);
                if (result != null && result.success) {
                    callback.onStreamReady(result);
                    return;
                }
                
                // Method 2: YouTube page scraping
                result = tryPageScraping(videoId);
                if (result != null && result.success) {
                    callback.onStreamReady(result);
                    return;
                }
                
                // Method 3: Invidious API (privacy-focused YouTube proxy)
                result = tryInvidiousApi(videoId);
                if (result != null && result.success) {
                    callback.onStreamReady(result);
                    return;
                }
                
                callback.onError("All stream extraction methods failed");
                
            } catch (Exception e) {
                Log.e(TAG, "Stream extraction failed", e);
                callback.onError("Stream extraction error: " + e.getMessage());
            }
        }).start();
    }
    
    private static String extractVideoId(String url) {
        // Handle various YouTube URL formats
        Pattern pattern = Pattern.compile("(?:youtube\\.com/watch\\?v=|youtu\\.be/|youtube\\.com/embed/)([^&\\?/]+)");
        Matcher matcher = pattern.matcher(url);
        if (matcher.find()) {
            return matcher.group(1);
        }
        return null;
    }
    
    private static StreamInfo tryDirectApiExtraction(String videoId) {
        try {
            Log.d(TAG, "Trying direct API extraction for: " + videoId);
            
            // Use YouTube's embed endpoint which is less restricted
            String embedUrl = "https://www.youtube.com/embed/" + videoId;
            HttpURLConnection connection = (HttpURLConnection) new URL(embedUrl).openConnection();
            connection.setRequestProperty("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
            connection.setConnectTimeout(5000);
            connection.setReadTimeout(10000);
            
            if (connection.getResponseCode() == 200) {
                BufferedReader reader = new BufferedReader(new InputStreamReader(connection.getInputStream()));
                StringBuilder response = new StringBuilder();
                String line;
                while ((line = reader.readLine()) != null) {
                    response.append(line);
                }
                reader.close();
                
                // Extract stream URLs from embedded player config
                String pageContent = response.toString();
                String streamUrl = extractStreamUrlFromEmbed(pageContent);
                String title = extractTitleFromEmbed(pageContent);
                
                if (streamUrl != null) {
                    Log.d(TAG, "Direct API SUCCESS: " + streamUrl.substring(0, Math.min(100, streamUrl.length())));
                    return new StreamInfo(streamUrl, title != null ? title : "Unknown Title", videoId, true, null);
                }
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Direct API extraction failed", e);
        }
        
        return null;
    }
    
    private static StreamInfo tryPageScraping(String videoId) {
        try {
            Log.d(TAG, "Trying page scraping for: " + videoId);
            
            String watchUrl = "https://www.youtube.com/watch?v=" + videoId;
            HttpURLConnection connection = (HttpURLConnection) new URL(watchUrl).openConnection();
            connection.setRequestProperty("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
            connection.setConnectTimeout(5000);
            connection.setReadTimeout(10000);
            
            if (connection.getResponseCode() == 200) {
                BufferedReader reader = new BufferedReader(new InputStreamReader(connection.getInputStream()));
                StringBuilder response = new StringBuilder();
                String line;
                while ((line = reader.readLine()) != null) {
                    response.append(line);
                }
                reader.close();
                
                String pageContent = response.toString();
                String streamUrl = extractStreamUrlFromPage(pageContent);
                String title = extractTitleFromPage(pageContent);
                
                if (streamUrl != null) {
                    Log.d(TAG, "Page scraping SUCCESS: " + streamUrl.substring(0, Math.min(100, streamUrl.length())));
                    return new StreamInfo(streamUrl, title != null ? title : "Unknown Title", videoId, true, null);
                }
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Page scraping failed", e);
        }
        
        return null;
    }
    
    private static StreamInfo tryInvidiousApi(String videoId) {
        try {
            Log.d(TAG, "Trying Invidious API for: " + videoId);
            
            // Try multiple Invidious instances
            String[] invidiousInstances = {
                "https://invidious.io",
                "https://y.com.sb",
                "https://invidious.sethforprivacy.com"
            };
            
            for (String instance : invidiousInstances) {
                try {
                    String apiUrl = instance + "/api/v1/videos/" + videoId;
                    HttpURLConnection connection = (HttpURLConnection) new URL(apiUrl).openConnection();
                    connection.setConnectTimeout(3000);
                    connection.setReadTimeout(5000);
                    
                    if (connection.getResponseCode() == 200) {
                        BufferedReader reader = new BufferedReader(new InputStreamReader(connection.getInputStream()));
                        StringBuilder response = new StringBuilder();
                        String line;
                        while ((line = reader.readLine()) != null) {
                            response.append(line);
                        }
                        reader.close();
                        
                        JSONObject json = new JSONObject(response.toString());
                        String title = json.optString("title", "Unknown Title");
                        
                        JSONArray adaptiveFormats = json.optJSONArray("adaptiveFormats");
                        if (adaptiveFormats != null) {
                            // Look for audio-only streams
                            for (int i = 0; i < adaptiveFormats.length(); i++) {
                                JSONObject format = adaptiveFormats.getJSONObject(i);
                                String type = format.optString("type", "");
                                if (type.contains("audio")) {
                                    String streamUrl = format.optString("url");
                                    if (streamUrl != null && !streamUrl.isEmpty()) {
                                        Log.d(TAG, "Invidious SUCCESS: " + streamUrl.substring(0, Math.min(100, streamUrl.length())));
                                        return new StreamInfo(streamUrl, title, videoId, true, null);
                                    }
                                }
                            }
                        }
                    }
                } catch (Exception e) {
                    Log.w(TAG, "Invidious instance failed: " + instance, e);
                    continue; // Try next instance
                }
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Invidious API failed", e);
        }
        
        return null;
    }
    
    private static String extractStreamUrlFromEmbed(String content) {
        // Look for stream URLs in embed player config
        Pattern[] patterns = {
            Pattern.compile("\"url\":\"([^\"]*audioonly[^\"]*)\","),
            Pattern.compile("\"url\":\"([^\"]*audio[^\"]*)\","),
            Pattern.compile("\"signatureCipher\":\"([^\"]*audio[^\"]*)\",")
        };
        
        for (Pattern pattern : patterns) {
            Matcher matcher = pattern.matcher(content);
            if (matcher.find()) {
                String url = matcher.group(1);
                return url.replace("\\u0026", "&").replace("\\/", "/");
            }
        }
        return null;
    }
    
    private static String extractTitleFromEmbed(String content) {
        Pattern pattern = Pattern.compile("\"title\":\"([^\"]+)\"");
        Matcher matcher = pattern.matcher(content);
        if (matcher.find()) {
            return matcher.group(1).replace("\\u0026", "&");
        }
        return null;
    }
    
    private static String extractStreamUrlFromPage(String content) {
        // Look for player response in page source
        Pattern pattern = Pattern.compile("var ytInitialPlayerResponse = (\\{.*?\\});");
        Matcher matcher = pattern.matcher(content);
        if (matcher.find()) {
            try {
                JSONObject playerResponse = new JSONObject(matcher.group(1));
                JSONObject streamingData = playerResponse.optJSONObject("streamingData");
                if (streamingData != null) {
                    JSONArray adaptiveFormats = streamingData.optJSONArray("adaptiveFormats");
                    if (adaptiveFormats != null) {
                        for (int i = 0; i < adaptiveFormats.length(); i++) {
                            JSONObject format = adaptiveFormats.getJSONObject(i);
                            String mimeType = format.optString("mimeType", "");
                            if (mimeType.contains("audio")) {
                                return format.optString("url");
                            }
                        }
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "Failed to parse player response", e);
            }
        }
        return null;
    }
    
    private static String extractTitleFromPage(String content) {
        Pattern pattern = Pattern.compile("<title>([^<]+)</title>");
        Matcher matcher = pattern.matcher(content);
        if (matcher.find()) {
            String title = matcher.group(1);
            return title.replace(" - YouTube", "").trim();
        }
        return null;
    }
}