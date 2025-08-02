// internal/transcription/realtime.go
package transcription

import (
	"context"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"github.com/gen2brain/malgo"
	"github.com/ggerganov/whisper.cpp/bindings/go/pkg/whisper"
	"github.com/kkdai/youtube/v2"
)

// RealtimeTranscriber handles real-time transcription with word timestamps
type RealtimeTranscriber struct {
	whisperModel   whisper.Model
	whisperContext whisper.Context
	audioContext   *malgo.AllocatedContext
	device         *malgo.Device
	db             *TranscriptionDB
	
	// Audio processing
	audioBuffer    []float32
	bufferMutex    sync.Mutex
	isRecording    bool
	
	// Current session
	currentRecording *Recording
	wordChannel      chan WordTimestamp
	
	// YouTube downloader
	ytClient youtube.Client
}

// TranscriptionConfig holds configuration for transcription
type TranscriptionConfig struct {
	ModelPath      string
	DatabasePath   string
	SampleRate     uint32
	BufferDuration time.Duration
}

// NewRealtimeTranscriber creates a new real-time transcriber
func NewRealtimeTranscriber(config TranscriptionConfig) (*RealtimeTranscriber, error) {
	// Initialize Whisper model
	model, err := whisper.New(config.ModelPath)
	if err != nil {
		return nil, fmt.Errorf("failed to load whisper model: %v", err)
	}

	ctx, err := model.NewContext()
	if err != nil {
		return nil, fmt.Errorf("failed to create whisper context: %v", err)
	}

	// Set Whisper parameters for word-level timestamps
	ctx.SetWordTimestamps(true)
	ctx.SetMaxSegmentLength(1) // Force word-level segmentation
	
	// Initialize audio context
	audioCtx, err := malgo.InitContext(nil, malgo.ContextConfig{}, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to init audio context: %v", err)
	}

	// Initialize database
	db, err := NewTranscriptionDB(config.DatabasePath)
	if err != nil {
		return nil, fmt.Errorf("failed to init database: %v", err)
	}

	rt := &RealtimeTranscriber{
		whisperModel:   model,
		whisperContext: ctx,
		audioContext:   audioCtx,
		db:             db,
		audioBuffer:    make([]float32, 0, int(config.SampleRate)*30), // 30 second buffer
		wordChannel:    make(chan WordTimestamp, 100),
		ytClient:       youtube.Client{},
	}

	// Initialize audio capture device
	deviceConfig := malgo.DefaultDeviceConfig(malgo.Capture)
	deviceConfig.Capture.Format = malgo.FormatF32
	deviceConfig.Capture.Channels = 1
	deviceConfig.SampleRate = config.SampleRate
	deviceConfig.Alsa.NoMMap = 1

	// Setup audio callback
	onRecvFrames := func(pOutputSample, pInputSamples []byte, framecount uint32) {
		if !rt.isRecording {
			return
		}

		// Convert bytes to float32
		samples := bytesToFloat32(pInputSamples)
		
		rt.bufferMutex.Lock()
		rt.audioBuffer = append(rt.audioBuffer, samples...)
		rt.bufferMutex.Unlock()
	}

	captureCallbacks := malgo.DeviceCallbacks{
		Data: onRecvFrames,
	}

	device, err := malgo.InitDevice(rt.audioContext.Context, deviceConfig, captureCallbacks)
	if err != nil {
		return nil, fmt.Errorf("failed to init capture device: %v", err)
	}

	rt.device = device
	return rt, nil
}

// StartBattleRecording starts recording for a rap battle
func (rt *RealtimeTranscriber) StartBattleRecording(artist, song, ticker, battleID string) error {
	// Create or get existing recording
	recording, err := rt.db.CreateRecording(artist, song, ticker, battleID)
	if err != nil {
		return err
	}

	rt.currentRecording = recording
	rt.isRecording = true

	// Start audio capture
	if err := rt.device.Start(); err != nil {
		return err
	}

	// Start transcription goroutine
	go rt.transcriptionLoop()

	// Start word processing goroutine
	go rt.processWords()

	return nil
}

// StopRecording stops the current recording
func (rt *RealtimeTranscriber) StopRecording() error {
	rt.isRecording = false
	
	if err := rt.device.Stop(); err != nil {
		return err
	}

	// Process any remaining audio
	rt.processRemainingAudio()

	// Close word channel
	close(rt.wordChannel)

	return nil
}

// transcriptionLoop continuously processes audio chunks
func (rt *RealtimeTranscriber) transcriptionLoop() {
	ticker := time.NewTicker(2 * time.Second) // Process every 2 seconds
	defer ticker.Stop()

	startTime := time.Now()

	for rt.isRecording {
		select {
		case <-ticker.C:
			rt.bufferMutex.Lock()
			if len(rt.audioBuffer) == 0 {
				rt.bufferMutex.Unlock()
				continue
			}

			// Copy buffer for processing
			audioData := make([]float32, len(rt.audioBuffer))
			copy(audioData, rt.audioBuffer)
			rt.audioBuffer = rt.audioBuffer[:0] // Clear buffer
			rt.bufferMutex.Unlock()

			// Process audio segment
			if err := rt.processAudioSegment(audioData, time.Since(startTime).Seconds()); err != nil {
				fmt.Printf("Error processing audio segment: %v\n", err)
			}
		}
	}
}

// processAudioSegment transcribes an audio segment with word timestamps
func (rt *RealtimeTranscriber) processAudioSegment(audioData []float32, baseTime float64) error {
	// Process audio through Whisper
	if err := rt.whisperContext.Process(audioData, nil, nil); err != nil {
		return err
	}

	// Get segments with word-level timestamps
	for i := 0; i < rt.whisperContext.Segment_Count(); i++ {
		segment := rt.whisperContext.Segment_Text(i)
		startTime := rt.whisperContext.Segment_Start(i)
		endTime := rt.whisperContext.Segment_End(i)

		// Get word-level timestamps
		tokens := rt.whisperContext.Segment_Tokens(i)
		for j := 0; j < len(tokens); j++ {
			token := tokens[j]
			word := rt.whisperContext.Token_Text(token.Id)
			
			if word != "" && word != " " {
				wordTimestamp := WordTimestamp{
					RecordingID: rt.currentRecording.ID,
					Word:        word,
					StartTime:   baseTime + token.T0,
					EndTime:     baseTime + token.T1,
					Confidence:  token.P,
				}
				
				// Send to processing channel
				rt.wordChannel <- wordTimestamp
			}
		}
	}

	return nil
}

// processWords handles storing words in the database
func (rt *RealtimeTranscriber) processWords() {
	batch := make([]WordTimestamp, 0, 50)
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case word, ok := <-rt.wordChannel:
			if !ok {
				// Channel closed, flush remaining batch
				if len(batch) > 0 {
					rt.db.AddWordTimestamps(rt.currentRecording.ID, batch)
				}
				return
			}
			
			batch = append(batch, word)
			
			// Flush batch if it's full
			if len(batch) >= 50 {
				if err := rt.db.AddWordTimestamps(rt.currentRecording.ID, batch); err != nil {
					fmt.Printf("Error saving word batch: %v\n", err)
				}
				batch = batch[:0]
			}

		case <-ticker.C:
			// Periodic flush
			if len(batch) > 0 {
				if err := rt.db.AddWordTimestamps(rt.currentRecording.ID, batch); err != nil {
					fmt.Printf("Error saving word batch: %v\n", err)
				}
				batch = batch[:0]
			}
		}
	}
}

// processRemainingAudio processes any audio left in the buffer
func (rt *RealtimeTranscriber) processRemainingAudio() {
	rt.bufferMutex.Lock()
	defer rt.bufferMutex.Unlock()

	if len(rt.audioBuffer) > 0 {
		// Get final timestamp
		duration := rt.currentRecording.Duration
		if duration == 0 {
			// Estimate based on buffer size and sample rate
			duration = float64(len(rt.audioBuffer)) / 16000.0
		}

		rt.processAudioSegment(rt.audioBuffer, duration)
	}
}

// DownloadAndTranscribe downloads a YouTube video and transcribes it
func (rt *RealtimeTranscriber) DownloadAndTranscribe(ctx context.Context, videoURL, artist, song, ticker string) error {
	// Download audio from YouTube
	video, err := rt.ytClient.GetVideo(videoURL)
	if err != nil {
		return fmt.Errorf("failed to get video metadata: %v", err)
	}

	// Get audio format
	format := video.Formats.Type("audio").Best()
	if format == nil {
		return fmt.Errorf("no audio format found")
	}

	stream, _, err := rt.ytClient.GetStream(ctx, video, format)
	if err != nil {
		return fmt.Errorf("failed to get audio stream: %v", err)
	}
	defer stream.Close()

	// Create temporary file
	tmpFile, err := os.CreateTemp("", "audio-*.m4a")
	if err != nil {
		return err
	}
	defer os.Remove(tmpFile.Name())

	// Download audio
	_, err = io.Copy(tmpFile, stream)
	if err != nil {
		return err
	}
	tmpFile.Close()

	// Transcribe the downloaded audio
	return rt.TranscribeFile(tmpFile.Name(), artist, song, ticker, "")
}

// TranscribeFile transcribes an audio file with word timestamps
func (rt *RealtimeTranscriber) TranscribeFile(filename, artist, song, ticker, battleID string) error {
	// Create recording entry
	recording, err := rt.db.CreateRecording(artist, song, ticker, battleID)
	if err != nil {
		return err
	}

	// Process file through Whisper
	if err := rt.whisperContext.Process_File(filename); err != nil {
		return err
	}

	// Extract word timestamps
	var words []WordTimestamp
	for i := 0; i < rt.whisperContext.Segment_Count(); i++ {
		tokens := rt.whisperContext.Segment_Tokens(i)
		
		for j := 0; j < len(tokens); j++ {
			token := tokens[j]
			word := rt.whisperContext.Token_Text(token.Id)
			
			if word != "" && word != " " {
				words = append(words, WordTimestamp{
					RecordingID: recording.ID,
					Word:        word,
					StartTime:   token.T0,
					EndTime:     token.T1,
					Confidence:  token.P,
				})
			}
		}
	}

	// Save to database
	return rt.db.AddWordTimestamps(recording.ID, words)
}

// GetLyricSync returns synchronized lyrics for a recording
func (rt *RealtimeTranscriber) GetLyricSync(recordingID int64, currentTime float64) ([]WordTimestamp, error) {
	// Get words around current time (±2 seconds window)
	return rt.db.GetWordsInTimeRange(recordingID, currentTime-2, currentTime+2)
}

// SearchLyrics searches for lyrics across all recordings
func (rt *RealtimeTranscriber) SearchLyrics(searchTerm string) ([]struct {
	Recording Recording
	Words     []WordTimestamp
}, error) {
	return rt.db.SearchWords(searchTerm)
}

// Close cleans up resources
func (rt *RealtimeTranscriber) Close() error {
	if rt.device != nil {
		rt.device.Uninit()
	}
	
	if rt.audioContext != nil {
		rt.audioContext.Uninit()
	}
	
	if rt.whisperContext != nil {
		rt.whisperContext.Free()
	}
	
	if rt.whisperModel != nil {
		rt.whisperModel.Close()
	}
	
	return rt.db.Close()
}

// Helper functions

func bytesToFloat32(b []byte) []float32 {
	samples := make([]float32, len(b)/4)
	for i := 0; i < len(samples); i++ {
		samples[i] = float32FromBytes(b[i*4 : (i+1)*4])
	}
	return samples
}

func float32FromBytes(b []byte) float32 {
	bits := uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
	return *(*float32)(unsafe.Pointer(&bits))
}