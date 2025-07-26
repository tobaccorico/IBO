package raps.app;

import java.io.Serializable;

public class WordTimestamp implements Serializable {
    private String word;
    private long startTimeMs;
    private long endTimeMs;
    private float confidence;
    private String language;
    
    public WordTimestamp(String word, long startTimeMs, long endTimeMs, float confidence, String language) {
        this.word = word;
        this.startTimeMs = startTimeMs;
        this.endTimeMs = endTimeMs;
        this.confidence = confidence;
        this.language = language;
    }
    
    // Getters and setters
    public String getWord() { return word; }
    public void setWord(String word) { this.word = word; }
    
    public long getStartTimeMs() { return startTimeMs; }
    public void setStartTimeMs(long startTimeMs) { this.startTimeMs = startTimeMs; }
    
    public long getEndTimeMs() { return endTimeMs; }
    public void setEndTimeMs(long endTimeMs) { this.endTimeMs = endTimeMs; }
    
    public float getConfidence() { return confidence; }
    public void setConfidence(float confidence) { this.confidence = confidence; }
    
    public String getLanguage() { return language; }
    public void setLanguage(String language) { this.language = language; }
    
    @Override
    public String toString() {
        return String.format("%s [%dms-%dms] (%.2f, %s)", 
            word, startTimeMs, endTimeMs, confidence, language);
    }
}