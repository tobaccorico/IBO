package raps.app;

import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.util.Log;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public class RealtimeSpeechService {
    private static final String TAG = "RealtimeSpeech";
    
    private Context context;
    private Map<String, SpeechRecognizer> recognizers;
    private Map<String, Long> sessionStartTimes;
    private List<WordTimestamp> wordTimestamps;
    private StringBuilder fullTranscription;
    private boolean isListening = false;
    
    public interface RealtimeTranscriptionCallback {
        void onTranscriptionUpdate(String text);
        void onPartialUpdate(String partialText);
        void onWordDetected(WordTimestamp wordTimestamp);
        void onTranscriptionComplete(String finalText, List<WordTimestamp> timestamps);
        void onError(String error);
    }
    
    public RealtimeSpeechService(Context context) {
        this.context = context;
        this.recognizers = new ConcurrentHashMap<>();
        this.sessionStartTimes = new ConcurrentHashMap<>();
        this.wordTimestamps = new ArrayList<>();
        this.fullTranscription = new StringBuilder();
    }
    
    public void startRealtimeTranscription(RealtimeTranscriptionCallback callback) {
        if (isListening) {
            Log.w(TAG, "Already listening, stopping previous session");
            stopRealtimeTranscription();
        }
        
        isListening = true;
        wordTimestamps.clear();
        fullTranscription.setLength(0);
        
        List<String> enabledLanguages = getEnabledInputLanguages();
        Log.d(TAG, "Starting transcription for languages: " + enabledLanguages);
        
        for (String language : enabledLanguages) {
            startRecognitionForLanguage(language, callback);
        }
    }
    
    private void startRecognitionForLanguage(String language, RealtimeTranscriptionCallback callback) {
        try {
            SpeechRecognizer recognizer = SpeechRecognizer.createSpeechRecognizer(context);
            recognizers.put(language, recognizer);
            sessionStartTimes.put(language, System.currentTimeMillis());
            
            Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
            intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
            intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, language);
            intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
            intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5);
            intent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1000);
            intent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1000);
            
            // Enable word-level timing if supported
            intent.putExtra("android.speech.extra.GET_AUDIO_FORMAT", true);
            intent.putExtra("android.speech.extra.AUDIO_SOURCE", android.media.MediaRecorder.AudioSource.MIC);
            
            recognizer.setRecognitionListener(new RecognitionListener() {
                @Override
                public void onReadyForSpeech(Bundle params) {
                    Log.d(TAG, "Speech recognizer ready for language: " + language);
                }
                
                @Override
                public void onBeginningOfSpeech() {
                    Log.d(TAG, "Speech began for language: " + language);
                }
                
                @Override
                public void onRmsChanged(float rmsdB) {
                    // Audio level monitoring (optional)
                }
                
                @Override
                public void onBufferReceived(byte[] buffer) {
                    // Raw audio data (optional)
                }
                
                @Override
                public void onEndOfSpeech() {
                    Log.d(TAG, "Speech ended for language: " + language);
                }
                
                @Override
                public void onError(int error) {
                    String errorMsg = getErrorMessage(error);
                    Log.e(TAG, "Recognition error for " + language + ": " + errorMsg);
                    
                    // Remove failed recognizer
                    recognizers.remove(language);
                    sessionStartTimes.remove(language);
                    
                    // If this was the last recognizer, report error
                    if (recognizers.isEmpty()) {
                        callback.onError("All recognition sessions failed: " + errorMsg);
                    }
                }
                
                @Override
                public void onResults(Bundle results) {
                    processResults(results, language, false, callback);
                }
                
                @Override
                public void onPartialResults(Bundle partialResults) {
                    processResults(partialResults, language, true, callback);
                }
                
                @Override
                public void onEvent(int eventType, Bundle params) {
                    Log.d(TAG, "Recognition event " + eventType + " for language: " + language);
                }
            });
            
            Log.d(TAG, "Starting speech recognition for language: " + language);
            recognizer.startListening(intent);
            
        } catch (Exception e) {
            Log.e(TAG, "Failed to start recognition for language: " + language, e);
        }
    }
    
    private void processResults(Bundle results, String language, boolean isPartial, RealtimeTranscriptionCallback callback) {
        ArrayList<String> matches = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        float[] confidenceScores = results.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES);
        
        if (matches != null && !matches.isEmpty()) {
            String bestMatch = matches.get(0);
            float confidence = confidenceScores != null && confidenceScores.length > 0 ? confidenceScores[0] : 0.5f;
            
            Log.d(TAG, (isPartial ? "Partial" : "Final") + " result for " + language + ": " + bestMatch);
            
            if (isPartial) {
                callback.onPartialUpdate(bestMatch + " (" + language + ")");
            } else {
                // Process final results with word-level timestamps
                processWordsWithTimestamps(bestMatch, language, confidence, callback);
                
                // Update full transcription
                if (fullTranscription.length() > 0) {
                    fullTranscription.append(" ");
                }
                fullTranscription.append(bestMatch);
                
                callback.onTranscriptionUpdate(fullTranscription.toString());
            }
        }
    }
    
    private void processWordsWithTimestamps(String text, String language, float confidence, RealtimeTranscriptionCallback callback) {
        String[] words = text.split("\\s+");
        long sessionStart = sessionStartTimes.get(language);
        long currentTime = System.currentTimeMillis();
        
        // Estimate word timing (since Android doesn't provide exact word timestamps)
        long totalDuration = currentTime - sessionStart;
        long avgWordDuration = words.length > 0 ? totalDuration / words.length : 1000;
        
        for (int i = 0; i < words.length; i++) {
            String word = words[i].trim();
            if (!word.isEmpty()) {
                long wordStart = sessionStart + (i * avgWordDuration);
                long wordEnd = wordStart + avgWordDuration;
                
                WordTimestamp wordTimestamp = new WordTimestamp(word, wordStart, wordEnd, confidence, language);
                wordTimestamps.add(wordTimestamp);
                
                Log.d(TAG, "Word detected: " + wordTimestamp);
                callback.onWordDetected(wordTimestamp);
            }
        }
    }
    
    public void stopRealtimeTranscription() {
        if (!isListening) return;
        
        Log.d(TAG, "Stopping realtime transcription");
        isListening = false;
        
        // Stop all recognizers
        for (SpeechRecognizer recognizer : recognizers.values()) {
            try {
                recognizer.stopListening();
                recognizer.destroy();
            } catch (Exception e) {
                Log.e(TAG, "Error stopping recognizer", e);
            }
        }
        
        recognizers.clear();
        sessionStartTimes.clear();
    }
    
    public void finishTranscription(RealtimeTranscriptionCallback callback) {
        stopRealtimeTranscription();
        
        String finalText = fullTranscription.toString().trim();
        Log.d(TAG, "Final transcription: " + finalText);
        Log.d(TAG, "Word timestamps count: " + wordTimestamps.size());
        
        callback.onTranscriptionComplete(finalText, new ArrayList<>(wordTimestamps));
    }
    
    private List<String> getEnabledInputLanguages() {
        List<String> languages = new ArrayList<>();
        
        try {
            InputMethodManager imm = (InputMethodManager) context.getSystemService(Context.INPUT_METHOD_SERVICE);
            List<InputMethodInfo> inputMethods = imm.getEnabledInputMethodList();
            
            for (InputMethodInfo inputMethod : inputMethods) {
                // Add supported languages from keyboard input methods
                // This is a simplified approach - in practice, you might want to parse
                // the input method's supported locales more thoroughly
                
                String packageName = inputMethod.getPackageName();
                if (packageName.contains("gboard") || packageName.contains("keyboard")) {
                    // Common keyboard apps and their likely languages
                    languages.add(Locale.getDefault().getLanguage());
                    
                    // Add some common secondary languages
                    if (!languages.contains("es")) languages.add("es"); // Spanish
                    if (!languages.contains("fr")) languages.add("fr"); // French
                    if (!languages.contains("de")) languages.add("de"); // German
                }
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Error getting input languages", e);
        }
        
        // Fallback to system default
        if (languages.isEmpty()) {
            languages.add(Locale.getDefault().getLanguage());
        }
        
        // Limit to 3 languages max to avoid overwhelming the system
        if (languages.size() > 3) {
            languages = languages.subList(0, 3);
        }
        
        return languages;
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
    
    public boolean isListening() {
        return isListening;
    }
    
    public void release() {
        stopRealtimeTranscription();
    }
}