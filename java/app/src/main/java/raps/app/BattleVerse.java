package raps.app;

import com.google.gson.annotations.SerializedName;

public class BattleVerse {
    @SerializedName("verse_number")
    private int verseNumber;
    
    @SerializedName("lyrics")
    private String lyrics;
    
    @SerializedName("start_time")
    private long startTime; // Milliseconds
    
    @SerializedName("end_time")
    private long endTime; // Milliseconds
    
    @SerializedName("confidence_score")
    private int confidenceScore; // 0-100
    
    public BattleVerse() {}
    
    public BattleVerse(int verseNumber, String lyrics, long startTime, long endTime, int confidenceScore) {
        this.verseNumber = verseNumber;
        this.lyrics = lyrics;
        this.startTime = startTime;
        this.endTime = endTime;
        this.confidenceScore = confidenceScore;
    }
    
    // Getters and setters
    public int getVerseNumber() { return verseNumber; }
    public void setVerseNumber(int verseNumber) { this.verseNumber = verseNumber; }
    
    public String getLyrics() { return lyrics; }
    public void setLyrics(String lyrics) { this.lyrics = lyrics; }
    
    public long getStartTime() { return startTime; }
    public void setStartTime(long startTime) { this.startTime = startTime; }
    
    public long getEndTime() { return endTime; }
    public void setEndTime(long endTime) { this.endTime = endTime; }
    
    public int getConfidenceScore() { return confidenceScore; }
    public void setConfidenceScore(int confidenceScore) { this.confidenceScore = confidenceScore; }
    
    public long getDuration() {
        return endTime - startTime;
    }
    
    public boolean isValid() {
        return lyrics != null && !lyrics.trim().isEmpty() 
               && lyrics.length() <= 140 // Twitter character limit
               && startTime < endTime
               && confidenceScore >= 0 && confidenceScore <= 100;
    }
    
    @Override
    public String toString() {
        return "BattleVerse{" +
                "verseNumber=" + verseNumber +
                ", lyrics='" + lyrics + '\'' +
                ", startTime=" + startTime +
                ", endTime=" + endTime +
                ", confidenceScore=" + confidenceScore +
                '}';
    }
}