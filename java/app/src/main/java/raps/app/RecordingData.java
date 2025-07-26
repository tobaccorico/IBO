package raps.app;

import java.io.Serializable;
import java.util.Date;

public class RecordingData implements Serializable {
    private String id;
    private String videoTitle;
    private String audioFilePath;
    private String recordingFilePath;
    private String lyrics;
    private Date recordingDate;
    private long duration; // in milliseconds
    
    public RecordingData() {
        this.id = String.valueOf(System.currentTimeMillis());
        this.recordingDate = new Date();
    }
    
    public RecordingData(String videoTitle, String audioFilePath, String recordingFilePath, String lyrics) {
        this();
        this.videoTitle = videoTitle;
        this.audioFilePath = audioFilePath;
        this.recordingFilePath = recordingFilePath;
        this.lyrics = lyrics;
    }
    
    // Getters and setters
    public String getId() { return id; }
    public void setId(String id) { this.id = id; }
    
    public String getVideoTitle() { return videoTitle; }
    public void setVideoTitle(String videoTitle) { this.videoTitle = videoTitle; }
    
    public String getAudioFilePath() { return audioFilePath; }
    public void setAudioFilePath(String audioFilePath) { this.audioFilePath = audioFilePath; }
    
    public String getRecordingFilePath() { return recordingFilePath; }
    public void setRecordingFilePath(String recordingFilePath) { this.recordingFilePath = recordingFilePath; }
    
    public String getLyrics() { return lyrics; }
    public void setLyrics(String lyrics) { this.lyrics = lyrics; }
    
    public Date getRecordingDate() { return recordingDate; }
    public void setRecordingDate(Date recordingDate) { this.recordingDate = recordingDate; }
    
    public long getDuration() { return duration; }
    public void setDuration(long duration) { this.duration = duration; }
}