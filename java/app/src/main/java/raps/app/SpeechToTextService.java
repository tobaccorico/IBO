package raps.app;

import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.util.Log;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

public class SpeechToTextService {
    private static final String TAG = "SpeechToText";
    private SpeechRecognizer speechRecognizer;
    private Context context;
    
    public interface TranscriptionCallback {
        void onTranscriptionResult(String text, float confidence);
        void onTranscriptionError(String error);
        void onTranscriptionPartialResult(String partialText);
    }
    
    public SpeechToTextService(Context context) {
        this.context = context;
        this.speechRecognizer = SpeechRecognizer.createSpeechRecognizer(context);
    }
    
    public void transcribeAudio(List<Short> audioData, TranscriptionCallback callback) {
        // Convert audio data to file for speech recognition
        File tempAudioFile = saveAudioToTempFile(audioData);
        
        if (tempAudioFile == null) {
            callback.onTranscriptionError("Failed to create temporary audio file");
            return;
        }
        
        // Use Android's built-in speech recognizer
        Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, 
                       RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault());
        intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
        
        speechRecognizer.setRecognitionListener(new RecognitionListener() {
            @Override
            public void onResults(Bundle results) {
                ArrayList<String> matches = results.getStringArrayList(
                    SpeechRecognizer.RESULTS_RECOGNITION);
                float[] confidenceScores = results.getFloatArray(
                    SpeechRecognizer.CONFIDENCE_SCORES);
                
                if (matches != null && !matches.isEmpty()) {
                    String bestMatch = matches.get(0);
                    float confidence = confidenceScores != null && confidenceScores.length > 0 
                        ? confidenceScores[0] : 0.5f;
                    callback.onTranscriptionResult(bestMatch, confidence);
                }
            }
            
            @Override
            public void onPartialResults(Bundle partialResults) {
                ArrayList<String> matches = partialResults.getStringArrayList(
                    SpeechRecognizer.RESULTS_RECOGNITION);
                if (matches != null && !matches.isEmpty()) {
                    callback.onTranscriptionPartialResult(matches.get(0));
                }
            }
            
            @Override
            public void onError(int error) {
                String errorMessage = getErrorMessage(error);
                callback.onTranscriptionError(errorMessage);
            }
            
            @Override public void onReadyForSpeech(Bundle params) {}
            @Override public void onBeginningOfSpeech() {}
            @Override public void onRmsChanged(float rmsdB) {}
            @Override public void onBufferReceived(byte[] buffer) {}
            @Override public void onEndOfSpeech() {}
            @Override public void onEvent(int eventType, Bundle params) {}
        });
        
        speechRecognizer.startListening(intent);
    }
    
    private File saveAudioToTempFile(List<Short> audioData) {
        try {
            File tempFile = File.createTempFile("recorded_audio", ".wav", context.getCacheDir());
            
            // Convert short list to byte array and save as WAV
            byte[] audioBytes = new byte[audioData.size() * 2];
            for (int i = 0; i < audioData.size(); i++) {
                short sample = audioData.get(i);
                audioBytes[i * 2] = (byte) (sample & 0xff);
                audioBytes[i * 2 + 1] = (byte) ((sample >> 8) & 0xff);
            }
            
            FileOutputStream fos = new FileOutputStream(tempFile);
            fos.write(audioBytes);
            fos.close();
            
            return tempFile;
        } catch (IOException e) {
            Log.e(TAG, "Error creating temp audio file", e);
            return null;
        }
    }
    
    private String getErrorMessage(int error) {
        switch (error) {
            case SpeechRecognizer.ERROR_AUDIO: return "Audio recording error";
            case SpeechRecognizer.ERROR_CLIENT: return "Client side error";
            case SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS: return "Insufficient permissions";
            case SpeechRecognizer.ERROR_NETWORK: return "Network error";
            case SpeechRecognizer.ERROR_NETWORK_TIMEOUT: return "Network timeout";
            case SpeechRecognizer.ERROR_NO_MATCH: return "No speech input";
            case SpeechRecognizer.ERROR_RECOGNIZER_BUSY: return "Recognition service busy";
            case SpeechRecognizer.ERROR_SERVER: return "Server error";
            case SpeechRecognizer.ERROR_SPEECH_TIMEOUT: return "No speech input";
            default: return "Unknown error";
        }
    }
    
    public void release() {
        if (speechRecognizer != null) {
            speechRecognizer.destroy();
        }
    }
}