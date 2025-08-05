// internal/ui/battle_mpc_helper.go
package ui

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/http"
	"time"
)

const MPC_API_URL = "http://localhost:8080"

type BattleMPCClient struct {
	apiURL string
}

func NewBattleMPCClient() *BattleMPCClient {
	return &BattleMPCClient{
		apiURL: MPC_API_URL,
	}
}

// InitiateBattleSigning starts a new battle signing session
func (c *BattleMPCClient) InitiateBattleSigning(battleID uint64, winnerIsChallenger bool, role, partyID string) (string, error) {
	url := fmt.Sprintf("%s/battle/%d/init", c.apiURL, battleID)
	
	reqBody := map[string]interface{}{
		"winnerIsChallenger": winnerIsChallenger,
		"role":              role,
		"partyID":           partyID,
	}
	jsonData, _ := json.Marshal(reqBody)
	
	resp, err := http.Post(url, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	
	var result struct {
		SessionID string `json:"sessionID"`
		Status    string `json:"status"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	
	return result.SessionID, nil
}

// JoinBattleSigning joins an existing battle signing session
func (c *BattleMPCClient) JoinBattleSigning(sessionID, role, partyID string) error {
	url := fmt.Sprintf("%s/battle/%s/join", c.apiURL, sessionID)
	
	reqBody := map[string]interface{}{
		"role":    role,
		"partyID": partyID,
	}
	jsonData, _ := json.Marshal(reqBody)
	
	resp, err := http.Post(url, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := ioutil.ReadAll(resp.Body)
		return fmt.Errorf("failed to join: %s", string(bodyBytes))
	}
	
	return nil
}

// SubmitSignature submits a signature for the battle
func (c *BattleMPCClient) SubmitSignature(sessionID, role string, signature []byte) error {
	url := fmt.Sprintf("%s/battle/%s/signature", c.apiURL, sessionID)
	
	reqBody := map[string]interface{}{
		"role":      role,
		"signature": base64.StdEncoding.EncodeToString(signature),
	}
	jsonData, _ := json.Marshal(reqBody)
	
	resp, err := http.Post(url, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := ioutil.ReadAll(resp.Body)
		return fmt.Errorf("failed to submit signature: %s", string(bodyBytes))
	}
	
	return nil
}

// GetBattleStatus checks the status of a battle signing session
func (c *BattleMPCClient) GetBattleStatus(sessionID string) (*BattleSigningStatus, error) {
	url := fmt.Sprintf("%s/battle/%s/status", c.apiURL, sessionID)
	
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	
	var status BattleSigningStatus
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		return nil, err
	}
	
	return &status, nil
}

// FinalizeBattle gets all collected signatures
func (c *BattleMPCClient) FinalizeBattle(sessionID string) (*BattleSignatures, error) {
	url := fmt.Sprintf("%s/battle/%s/finalize", c.apiURL, sessionID)
	
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	
	var result struct {
		BattleID           uint64 `json:"battleID"`
		WinnerIsChallenger bool   `json:"winnerIsChallenger"`
		ChallengerSig      string `json:"challengerSig"`
		DefenderSig        string `json:"defenderSig"`
		JudgeSig           string `json:"judgeSig"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	
	challengerSig, _ := base64.StdEncoding.DecodeString(result.ChallengerSig)
	defenderSig, _ := base64.StdEncoding.DecodeString(result.DefenderSig)
	judgeSig, _ := base64.StdEncoding.DecodeString(result.JudgeSig)
	
	return &BattleSignatures{
		BattleID:           result.BattleID,
		WinnerIsChallenger: result.WinnerIsChallenger,
		ChallengerSig:      challengerSig,
		DefenderSig:        defenderSig,
		JudgeSig:           judgeSig,
	}, nil
}

// WaitForCompletion polls until all signatures are collected
func (c *BattleMPCClient) WaitForCompletion(sessionID string, timeout time.Duration) (*BattleSignatures, error) {
	deadline := time.Now().Add(timeout)
	
	for time.Now().Before(deadline) {
		status, err := c.GetBattleStatus(sessionID)
		if err != nil {
			return nil, err
		}
		
		if status.Complete {
			return c.FinalizeBattle(sessionID)
		}
		
		time.Sleep(2 * time.Second)
	}
	
	return nil, fmt.Errorf("timeout waiting for signatures")
}

type BattleSigningStatus struct {
	SessionID          string          `json:"sessionID"`
	BattleID           uint64          `json:"battleID"`
	WinnerIsChallenger bool            `json:"winnerIsChallenger"`
	Status             string          `json:"status"`
	Participants       int             `json:"participants"`
	Signatures         map[string]bool `json:"signatures"`
	Complete           bool            `json:"complete"`
}

type BattleSignatures struct {
	BattleID           uint64
	WinnerIsChallenger bool
	ChallengerSig      []byte
	DefenderSig        []byte
	JudgeSig           []byte
}

// CreateBattleMessage creates the message to be signed for a battle result
func CreateBattleMessage(battleID uint64, winnerIsChallenger bool) []byte {
	message := make([]byte, 9)
	binary.LittleEndian.PutUint64(message[:8], battleID)
	if winnerIsChallenger {
		message[8] = 1
	} else {
		message[8] = 0
	}
	return message
}