package main

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/gorilla/mux"
	"github.com/taurusgroup/frost-ed25519/pkg/frost/party"
)

type Message struct {
	From    int    `json:"from"`
	To      int    `json:"to"`
	Round   int    `json:"round"`
	Content []byte `json:"content"`
}

type Session struct {
	ID            string
	T             int
	N             int
	PartyIDs      []party.ID
	JoinedParties []party.ID
	Messages      map[int][]Message
	GroupKey      string
	Authenticated map[party.ID]bool
	Transaction   []byte
	Mutex         sync.Mutex
}

// Battle signing session structure
type BattleSigningSession struct {
	SessionID          string
	BattleID           uint64
	WinnerIsChallenger bool
	Participants       map[string]string // role -> partyID (challenger, defender, judge)
	Signatures         map[string][]byte // role -> signature
	Message            []byte            // The message being signed (battleID + winner)
	CreatedAt          time.Time
	Status             string // "pending", "signing", "complete"
	Mutex              sync.Mutex
}

var sessions = make(map[string]*Session)
var signingessions = make(map[string]*Session)
var battleSessions = make(map[string]*BattleSigningSession)
var sessionsMutex sync.Mutex
var battleSessionsMutex sync.Mutex

func main() {
	router := mux.NewRouter()

	// Key generation endpoints
	router.HandleFunc("/keygen/initiate", InitiateKeygen).Methods("POST")
	router.HandleFunc("/keygen/{sessionID}/join", JoinSession).Methods("POST")
	router.HandleFunc("/keygen/{sessionID}/messages", MessagesHandler).Methods("POST", "GET")
	router.HandleFunc("/keygen/{sessionID}/status", StatusHandler).Methods("GET")

	// Regular signing endpoints
	router.HandleFunc("/sign/initiate", InitiateSigning).Methods("POST")
	router.HandleFunc("/sign/{sessionID}/join", JoinSigningSession).Methods("POST")
	router.HandleFunc("/sign/{sessionID}/broadcast", BroadcastTransaction).Methods("POST")
	router.HandleFunc("/sign/{sessionID}/messages", SigningMessagesHandler).Methods("POST", "GET")
	router.HandleFunc("/sign/{sessionID}/status", SigningStatusHandler).Methods("GET")
	router.HandleFunc("/sign/{sessionID}/transaction", GetTransactionHandler).Methods("GET")
	router.HandleFunc("/sign/{sessionID}/finalize", FinalizeTransaction).Methods("POST")

	// Battle signing endpoints
	router.HandleFunc("/battle/{battleID}/init", InitBattleSigningHandler).Methods("POST")
	router.HandleFunc("/battle/{sessionID}/join", JoinBattleSigningHandler).Methods("POST")
	router.HandleFunc("/battle/{sessionID}/message", BroadcastBattleMessageHandler).Methods("POST")
	router.HandleFunc("/battle/{sessionID}/signature", SubmitBattleSignatureHandler).Methods("POST")
	router.HandleFunc("/battle/{sessionID}/status", GetBattleSigningStatusHandler).Methods("GET")
	router.HandleFunc("/battle/{sessionID}/finalize", FinalizeBattleHandler).Methods("GET")

	log.Println("MPC API Server started on port 8080")
	log.Println("Endpoints available:")
	log.Println("  - Key Generation: /keygen/*")
	log.Println("  - Regular Signing: /sign/*")
	log.Println("  - Battle Signing: /battle/*")
	log.Fatal(http.ListenAndServe(":8080", router))
}

// Key Generation Handlers

func InitiateKeygen(w http.ResponseWriter, r *http.Request) {
	type Request struct {
		T int `json:"t"`
		N int `json:"n"`
	}
	var req Request
	err := json.NewDecoder(r.Body).Decode(&req)
	if err != nil || req.N < req.T || req.T < 1 {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	sessionsMutex.Lock()
	sessionID := fmt.Sprintf("session-%d", len(sessions)+1)
	sessionsMutex.Unlock()

	session := &Session{
		ID:            sessionID,
		T:             req.T,
		N:             req.N,
		PartyIDs:      make([]party.ID, req.N),
		JoinedParties: []party.ID{},
		Messages:      make(map[int][]Message),
		Mutex:         sync.Mutex{},
	}

	// Initialize PartyIDs to [1, 2, ..., N]
	for i := 0; i < req.N; i++ {
		session.PartyIDs[i] = party.ID(i + 1)
	}

	sessionsMutex.Lock()
	sessions[sessionID] = session
	sessionsMutex.Unlock()

	response := map[string]interface{}{
		"sessionID": sessionID,
		"message":   "Session created. Parties can now join.",
	}
	json.NewEncoder(w).Encode(response)
}

func JoinSession(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	sessionsMutex.Lock()
	session, exists := sessions[sessionID]
	sessionsMutex.Unlock()
	if !exists {
		http.Error(w, "Session not found", http.StatusNotFound)
		return
	}

	session.Mutex.Lock()
	defer session.Mutex.Unlock()

	if len(session.JoinedParties) >= session.N {
		http.Error(w, "Session is full", http.StatusBadRequest)
		return
	}

	newPartyID := session.PartyIDs[len(session.JoinedParties)]
	session.JoinedParties = append(session.JoinedParties, newPartyID)

	response := map[string]interface{}{
		"message": "Party joined successfully",
		"partyID": int(newPartyID),
		"t":       session.T,
		"n":       session.N,
	}
	json.NewEncoder(w).Encode(response)
}

func MessagesHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	sessionsMutex.Lock()
	session, exists := sessions[sessionID]
	sessionsMutex.Unlock()
	if !exists {
		http.Error(w, "Session not found", http.StatusNotFound)
		return
	}

	if r.Method == "POST" {
		type MessageRequest struct {
			To      int    `json:"to"`
			Content string `json:"content"` // base64 encoded
		}
		type Request struct {
			PartyID  int              `json:"partyID"`
			Round    int              `json:"round"`
			Messages []MessageRequest `json:"messages"`
		}
		var req Request
		err := json.NewDecoder(r.Body).Decode(&req)
		if err != nil {
			http.Error(w, "Invalid request", http.StatusBadRequest)
			return
		}

		session.Mutex.Lock()
		defer session.Mutex.Unlock()

		for _, msgReq := range req.Messages {
			contentBytes, err := base64.StdEncoding.DecodeString(msgReq.Content)
			if err != nil {
				http.Error(w, "Invalid message content", http.StatusBadRequest)
				return
			}

			msg := Message{
				From:    req.PartyID,
				To:      msgReq.To,
				Round:   req.Round,
				Content: contentBytes,
			}
			session.Messages[req.Round] = append(session.Messages[req.Round], msg)
		}

		response := map[string]interface{}{
			"message": "Messages received",
		}
		json.NewEncoder(w).Encode(response)

	} else if r.Method == "GET" {
		partyIDStr := r.URL.Query().Get("partyID")
		roundStr := r.URL.Query().Get("round")
		partyID, err := strconv.Atoi(partyIDStr)
		if err != nil {
			http.Error(w, "Invalid partyID", http.StatusBadRequest)
			return
		}
		round, err := strconv.Atoi(roundStr)
		if err != nil {
			http.Error(w, "Invalid round", http.StatusBadRequest)
			return
		}

		session.Mutex.Lock()
		defer session.Mutex.Unlock()

		// Adjust expected messages based on the protocol round
		var expectedMessages int
		if round == 1 {
			expectedMessages = session.N
		} else if round == 2 {
			expectedMessages = session.N * (session.N - 1)
		} else {
			expectedMessages = session.N // adjust as needed for other rounds
		}

		if len(session.Messages[round]) < expectedMessages {
			http.Error(w, "Not all messages have been submitted", http.StatusBadRequest)
			return
		}

		var messages []string
		for _, msg := range session.Messages[round] {
			if msg.To == 0 || msg.To == partyID {
				messages = append(messages, base64.StdEncoding.EncodeToString(msg.Content))
			}
		}

		response := map[string]interface{}{
			"messages": messages,
		}
		json.NewEncoder(w).Encode(response)
	}
}

func StatusHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	sessionsMutex.Lock()
	session, exists := sessions[sessionID]
	sessionsMutex.Unlock()
	if !exists {
		http.Error(w, "Session not found", http.StatusNotFound)
		return
	}

	session.Mutex.Lock()
	defer session.Mutex.Unlock()

	// Convert party.ID slices to []int for JSON encoding
	partyIDsInt := make([]int, len(session.PartyIDs))
	for i, id := range session.PartyIDs {
		partyIDsInt[i] = int(id)
	}
	joinedPartiesInt := make([]int, len(session.JoinedParties))
	for i, id := range session.JoinedParties {
		joinedPartiesInt[i] = int(id)
	}

	response := map[string]interface{}{
		"partyIDs":      partyIDsInt,
		"joinedParties": joinedPartiesInt,
		"t":             session.T,
		"n":             session.N,
	}
	json.NewEncoder(w).Encode(response)
}

// Regular Signing Handlers

func InitiateSigning(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SessionID string `json:"sessionID"`
		T         int    `json:"t"` // Threshold
		N         int    `json:"n"` // Total number of parties
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	if req.T < 1 || req.N < req.T {
		http.Error(w, "Invalid threshold or number of parties", http.StatusBadRequest)
		return
	}

	sessionsMutex.Lock()
	defer sessionsMutex.Unlock()

	if _, exists := signingessions[req.SessionID]; exists {
		http.Error(w, "Session ID already exists", http.StatusBadRequest)
		return
	}

	session := &Session{
		ID:            req.SessionID,
		T:             req.T,
		N:             req.N,
		PartyIDs:      make([]party.ID, req.N),
		JoinedParties: []party.ID{},
		Messages:      make(map[int][]Message),
		Mutex:         sync.Mutex{},
	}

	for i := 0; i < req.N; i++ {
		session.PartyIDs[i] = party.ID(i + 1)
	}

	signingessions[req.SessionID] = session

	response := map[string]interface{}{
		"message": "Signing session created. Parties can now join.",
		"t":       req.T,
		"n":       req.N,
	}
	json.NewEncoder(w).Encode(response)
}

func JoinSigningSession(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	fmt.Printf("Received join request for session: %s\n", sessionID)

	var req struct {
		PartyID int `json:"partyID"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		fmt.Printf("Error decoding request body: %v\n", err)
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	fmt.Printf("Received partyID: %d\n", req.PartyID)

	sessionsMutex.Lock()
	session, exists := signingessions[sessionID]
	sessionsMutex.Unlock()
	if !exists {
		fmt.Printf("Signing session not found: %s\n", sessionID)
		http.Error(w, "Signing session not found", http.StatusNotFound)
		return
	}

	session.Mutex.Lock()
	defer session.Mutex.Unlock()

	if len(session.JoinedParties) >= session.N {
		fmt.Printf("Signing session is full: %s\n", sessionID)
		http.Error(w, "Signing session is full", http.StatusBadRequest)
		return
	}

	newPartyID := party.ID(req.PartyID)
	session.JoinedParties = append(session.JoinedParties, newPartyID)

	fmt.Printf("Party %d joined session %s\n", req.PartyID, sessionID)

	response := map[string]interface{}{
		"message": "Party joined signing session successfully",
		"partyID": int(newPartyID),
		"n":       session.N,
	}
	json.NewEncoder(w).Encode(response)
}

func BroadcastTransaction(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	var req struct {
		Transaction string `json:"transaction"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	sessionsMutex.Lock()
	session, exists := signingessions[sessionID]
	sessionsMutex.Unlock()
	if !exists {
		http.Error(w, "Signing session not found", http.StatusNotFound)
		return
	}

	txBytes, err := base64.StdEncoding.DecodeString(req.Transaction)
	if err != nil {
		http.Error(w, "Invalid transaction encoding", http.StatusBadRequest)
		return
	}

	session.Mutex.Lock()
	session.Transaction = txBytes
	session.Mutex.Unlock()

	response := map[string]interface{}{
		"message": "Transaction broadcasted successfully",
	}
	json.NewEncoder(w).Encode(response)
}

func SigningMessagesHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	sessionsMutex.Lock()
	session, exists := signingessions[sessionID]
	sessionsMutex.Unlock()
	if !exists {
		http.Error(w, "Signing session not found", http.StatusNotFound)
		return
	}

	if r.Method == "POST" {
		type MessageRequest struct {
			To      int    `json:"to"`
			Content string `json:"content"` // base64 encoded
		}
		type Request struct {
			PartyID  int              `json:"partyID"`
			Round    int              `json:"round"`
			Messages []MessageRequest `json:"messages"`
		}
		var req Request
		err := json.NewDecoder(r.Body).Decode(&req)
		if err != nil {
			http.Error(w, fmt.Sprintf("Invalid request: %v", err), http.StatusBadRequest)
			return
		}

		session.Mutex.Lock()
		defer session.Mutex.Unlock()

		fmt.Printf("Received %d messages for session %s, round %d from party %d\n", len(req.Messages), sessionID, req.Round, req.PartyID)

		for _, msgReq := range req.Messages {
			contentBytes, err := base64.StdEncoding.DecodeString(msgReq.Content)
			if err != nil {
				http.Error(w, "Invalid message content", http.StatusBadRequest)
				return
			}

			msg := Message{
				From:    req.PartyID,
				To:      msgReq.To,
				Round:   req.Round,
				Content: contentBytes,
			}
			session.Messages[req.Round] = append(session.Messages[req.Round], msg)
		}

		// Check if we've reached the threshold
		if len(session.Messages[req.Round]) >= session.T {
			fmt.Printf("Threshold reached for session %s, round %d\n", sessionID, req.Round)
		}

		response := map[string]interface{}{
			"message": "Signing messages received",
		}
		json.NewEncoder(w).Encode(response)

	} else if r.Method == "GET" {
		partyIDStr := r.URL.Query().Get("partyID")
		roundStr := r.URL.Query().Get("round")
		partyID, err := strconv.Atoi(partyIDStr)
		if err != nil {
			http.Error(w, "Invalid partyID", http.StatusBadRequest)
			return
		}
		round, err := strconv.Atoi(roundStr)
		if err != nil {
			http.Error(w, "Invalid round", http.StatusBadRequest)
			return
		}

		session.Mutex.Lock()
		defer session.Mutex.Unlock()

		var messages []string
		for _, msg := range session.Messages[round] {
			if msg.To == 0 || msg.To == partyID {
				messages = append(messages, base64.StdEncoding.EncodeToString(msg.Content))
			}
		}

		response := map[string]interface{}{
			"messages": messages,
		}
		json.NewEncoder(w).Encode(response)
	}
}

func SigningStatusHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	sessionsMutex.Lock()
	session, exists := signingessions[sessionID]
	sessionsMutex.Unlock()
	if !exists {
		http.Error(w, "Signing session not found", http.StatusNotFound)
		return
	}

	session.Mutex.Lock()
	defer session.Mutex.Unlock()

	partyIDsInt := make([]int, len(session.PartyIDs))
	for i, id := range session.PartyIDs {
		partyIDsInt[i] = int(id)
	}
	joinedPartiesInt := make([]int, len(session.JoinedParties))
	for i, id := range session.JoinedParties {
		joinedPartiesInt[i] = int(id)
	}

	messageCount := make(map[int]int)
	for round, messages := range session.Messages {
		messageCount[round] = len(messages)
	}

	response := map[string]interface{}{
		"partyIDs":       partyIDsInt,
		"joinedParties":  joinedPartiesInt,
		"messages":       messageCount,
		"t":              session.T,
		"n":              session.N,
		"hasTransaction": session.Transaction != nil,
	}
	json.NewEncoder(w).Encode(response)
}

func GetTransactionHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	sessionsMutex.Lock()
	session, exists := signingessions[sessionID]
	sessionsMutex.Unlock()
	if !exists {
		http.Error(w, "Signing session not found", http.StatusNotFound)
		return
	}

	session.Mutex.Lock()
	defer session.Mutex.Unlock()

	if session.Transaction == nil {
		http.Error(w, "Transaction not yet broadcasted", http.StatusNotFound)
		return
	}

	response := map[string]interface{}{
		"transaction": base64.StdEncoding.EncodeToString(session.Transaction),
		"message":     base64.StdEncoding.EncodeToString(session.Transaction), // For compatibility
	}
	json.NewEncoder(w).Encode(response)
}

func FinalizeTransaction(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	var req struct {
		Signature string `json:"signature"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	sessionsMutex.Lock()
	session, exists := signingessions[sessionID]
	sessionsMutex.Unlock()
	if !exists {
		http.Error(w, "Signing session not found", http.StatusNotFound)
		return
	}

	signature, err := base64.StdEncoding.DecodeString(req.Signature)
	if err != nil {
		http.Error(w, "Invalid signature encoding", http.StatusBadRequest)
		return
	}

	// Print the signature to the console
	fmt.Printf("Received signature for session %s: %x\n", sessionID, signature)

	// Use the session to get the original transaction
	session.Mutex.Lock()
	transaction := session.Transaction
	session.Mutex.Unlock()

	if transaction == nil {
		http.Error(w, "No transaction found for this session", http.StatusBadRequest)
		return
	}

	// Here you would typically add the signature to the transaction
	// and submit it to the Solana network. For this example, we'll
	// just print the transaction details.
	fmt.Printf("Original transaction for session %s: %x\n", sessionID, transaction)
	fmt.Printf("Transaction length: %d bytes\n", len(transaction))
	fmt.Printf("Signature length: %d bytes\n", len(signature))

	response := map[string]interface{}{
		"message":           "Transaction finalized successfully",
		"transactionLength": len(transaction),
		"signatureLength":   len(signature),
	}
	json.NewEncoder(w).Encode(response)

	// Clean up the session
	sessionsMutex.Lock()
	delete(signingessions, sessionID)
	sessionsMutex.Unlock()
}

// Battle Signing Handlers

func InitBattleSigningHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	battleID, err := strconv.ParseUint(vars["battleID"], 10, 64)
	if err != nil {
		http.Error(w, "Invalid battle ID", http.StatusBadRequest)
		return
	}

	var req struct {
		WinnerIsChallenger bool   `json:"winnerIsChallenger"`
		Role               string `json:"role"` // "challenger", "defender", "judge"
		PartyID            string `json:"partyID"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	sessionID := fmt.Sprintf("battle-%d-%d", battleID, time.Now().Unix())
	
	// Create the message to be signed (battleID + winner)
	message := make([]byte, 9)
	binary.LittleEndian.PutUint64(message[:8], battleID)
	if req.WinnerIsChallenger {
		message[8] = 1
	} else {
		message[8] = 0
	}
	
	battleSessionsMutex.Lock()
	session := &BattleSigningSession{
		SessionID:          sessionID,
		BattleID:           battleID,
		WinnerIsChallenger: req.WinnerIsChallenger,
		Participants:       make(map[string]string),
		Signatures:         make(map[string][]byte),
		Message:            message,
		CreatedAt:          time.Now(),
		Status:             "pending",
	}
	session.Participants[req.Role] = req.PartyID
	battleSessions[sessionID] = session
	battleSessionsMutex.Unlock()

	log.Printf("Battle signing session created: %s for battle %d\n", sessionID, battleID)

	json.NewEncoder(w).Encode(map[string]interface{}{
		"sessionID": sessionID,
		"status":    "created",
		"message":   base64.StdEncoding.EncodeToString(message),
	})
}

func JoinBattleSigningHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	var req struct {
		Role    string `json:"role"`
		PartyID string `json:"partyID"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	battleSessionsMutex.Lock()
	session, exists := battleSessions[sessionID]
	if !exists {
		battleSessionsMutex.Unlock()
		http.Error(w, "Session not found", http.StatusNotFound)
		return
	}

	session.Mutex.Lock()
	defer session.Mutex.Unlock()
	battleSessionsMutex.Unlock()

	session.Participants[req.Role] = req.PartyID
	
	// Check if all parties have joined
	if len(session.Participants) == 3 {
		session.Status = "signing"
		log.Printf("All parties joined battle session %s\n", sessionID)
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":       session.Status,
		"participants": len(session.Participants),
		"message":      base64.StdEncoding.EncodeToString(session.Message),
	})
}

func BroadcastBattleMessageHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	var req struct {
		Message string `json:"message"` // base64 encoded
		Type    string `json:"type"`    // "battle_result"
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	message, err := base64.StdEncoding.DecodeString(req.Message)
	if err != nil {
		http.Error(w, "Invalid message encoding", http.StatusBadRequest)
		return
	}

	battleSessionsMutex.Lock()
	session, exists := battleSessions[sessionID]
	if !exists {
		battleSessionsMutex.Unlock()
		http.Error(w, "Session not found", http.StatusNotFound)
		return
	}
	battleSessionsMutex.Unlock()

	session.Mutex.Lock()
	defer session.Mutex.Unlock()

	// Verify the message matches what we expect
	if !bytes.Equal(message, session.Message) {
		http.Error(w, "Message mismatch", http.StatusBadRequest)
		return
	}

	log.Printf("Battle message broadcasted for session %s\n", sessionID)

	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "message_received",
	})
}

func SubmitBattleSignatureHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	var req struct {
		Role      string `json:"role"`
		Signature string `json:"signature"` // base64 encoded
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	sig, err := base64.StdEncoding.DecodeString(req.Signature)
	if err != nil {
		http.Error(w, "Invalid signature encoding", http.StatusBadRequest)
		return
	}

	if len(sig) != 64 {
		http.Error(w, "Invalid signature length (expected 64 bytes)", http.StatusBadRequest)
		return
	}

	battleSessionsMutex.Lock()
	session, exists := battleSessions[sessionID]
	if !exists {
		battleSessionsMutex.Unlock()
		http.Error(w, "Session not found", http.StatusNotFound)
		return
	}
	battleSessionsMutex.Unlock()

	session.Mutex.Lock()
	defer session.Mutex.Unlock()

	session.Signatures[req.Role] = sig
	log.Printf("Received %s signature for battle session %s\n", req.Role, sessionID)
	
	// Check if all signatures collected
	if len(session.Signatures) == 3 {
		session.Status = "complete"
		log.Printf("All signatures collected for battle session %s\n", sessionID)
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":               session.Status,
		"signatures_collected": len(session.Signatures),
	})
}

func GetBattleSigningStatusHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	battleSessionsMutex.Lock()
	session, exists := battleSessions[sessionID]
	if !exists {
		battleSessionsMutex.Unlock()
		http.Error(w, "Session not found", http.StatusNotFound)
		return
	}
	battleSessionsMutex.Unlock()

	session.Mutex.Lock()
	defer session.Mutex.Unlock()

	signatures := make(map[string]bool)
	for role := range session.Signatures {
		signatures[role] = true
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"sessionID":          session.SessionID,
		"battleID":           session.BattleID,
		"winnerIsChallenger": session.WinnerIsChallenger,
		"status":             session.Status,
		"participants":       len(session.Participants),
		"signatures":         signatures,
		"complete":           session.Status == "complete",
	})
}

func FinalizeBattleHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	sessionID := vars["sessionID"]

	battleSessionsMutex.Lock()
	session, exists := battleSessions[sessionID]
	if !exists {
		battleSessionsMutex.Unlock()
		http.Error(w, "Session not found", http.StatusNotFound)
		return
	}
	battleSessionsMutex.Unlock()

	session.Mutex.Lock()
	defer session.Mutex.Unlock()

	if session.Status != "complete" {
		http.Error(w, "Not all signatures collected", http.StatusBadRequest)
		return
	}

	// Return all three signatures for on-chain submission
	response := map[string]interface{}{
		"battleID":           session.BattleID,
		"winnerIsChallenger": session.WinnerIsChallenger,
		"challengerSig":      base64.StdEncoding.EncodeToString(session.Signatures["challenger"]),
		"defenderSig":        base64.StdEncoding.EncodeToString(session.Signatures["defender"]),
		"judgeSig":           base64.StdEncoding.EncodeToString(session.Signatures["judge"]),
	}

	log.Printf("Battle %d finalized with all signatures\n", session.BattleID)

	json.NewEncoder(w).Encode(response)

	// Clean up the session after successful finalization
	go func() {
		time.Sleep(5 * time.Minute) // Keep session for 5 minutes in case needed
		battleSessionsMutex.Lock()
		delete(battleSessions, sessionID)
		battleSessionsMutex.Unlock()
	}()
}