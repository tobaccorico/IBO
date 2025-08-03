// internal/twitter/intent.go
package twitter

import (
	"context"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// IntentClient handles Twitter intent-based operations without OAuth
type IntentClient struct {
	baseURL string
}

// Tweet represents a tweet structure
type Tweet struct {
	ID        string
	Text      string
	Author    string
	ReplyToID string
	Timestamp time.Time
	Likes     int
}

// BattleVerification represents the result of verifying a rap battle
type BattleVerification struct {
	ChallengerURI      string
	DefenderURI        string
	ChallengerBroke    bool
	DefenderBroke      bool
	BrokenAtTweet      string
	ConsecutiveLikes   map[string]int
}

// NewIntentClient creates a new Twitter intent client
func NewIntentClient() *IntentClient {
	return &IntentClient{
		baseURL: "https://twitter.com/intent",
	}
}

// CreateTweetIntent creates a Twitter intent URL for posting
func (ic *IntentClient) CreateTweetIntent(text string, replyTo string) string {
	params := url.Values{}
	params.Set("text", text)
	
	if replyTo != "" {
		// Extract tweet ID from URL if full URL provided
		tweetID := ic.extractTweetID(replyTo)
		if tweetID != "" {
			params.Set("in_reply_to", tweetID)
		}
	}
	
	return fmt.Sprintf("%s/tweet?%s", ic.baseURL, params.Encode())
}

// CreateFollowIntent creates a follow intent URL
func (ic *IntentClient) CreateFollowIntent(username string) string {
	params := url.Values{}
	params.Set("screen_name", strings.TrimPrefix(username, "@"))
	return fmt.Sprintf("%s/follow?%s", ic.baseURL, params.Encode())
}

// CreateLikeIntent creates a like intent URL
func (ic *IntentClient) CreateLikeIntent(tweetURL string) string {
	tweetID := ic.extractTweetID(tweetURL)
	params := url.Values{}
	params.Set("tweet_id", tweetID)
	return fmt.Sprintf("%s/like?%s", ic.baseURL, params.Encode())
}

// CreateRetweetIntent creates a retweet intent URL
func (ic *IntentClient) CreateRetweetIntent(tweetURL string) string {
	tweetID := ic.extractTweetID(tweetURL)
	params := url.Values{}
	params.Set("tweet_id", tweetID)
	return fmt.Sprintf("%s/retweet?%s", ic.baseURL, params.Encode())
}

// ParseTweetURI validates and parses a tweet URI
func (ic *IntentClient) ParseTweetURI(uri string) (*Tweet, error) {
	// Validate URI format: /username/status/id
	re := regexp.MustCompile(`^/?([a-zA-Z0-9_]{1,15})/status/(\d{1,19})$`)
	matches := re.FindStringSubmatch(uri)
	
	if len(matches) != 3 {
		return nil, fmt.Errorf("invalid tweet URI format: %s", uri)
	}
	
	return &Tweet{
		ID:     matches[2],
		Author: matches[1],
	}, nil
}

// ValidateBattleURIs validates challenger and defender tweet URIs
func (ic *IntentClient) ValidateBattleURIs(challengerURI, defenderURI string) error {
	// Validate both URIs
	challengerTweet, err := ic.ParseTweetURI(challengerURI)
	if err != nil {
		return fmt.Errorf("invalid challenger URI: %v", err)
	}
	
	defenderTweet, err := ic.ParseTweetURI(defenderURI)
	if err != nil {
		return fmt.Errorf("invalid defender URI: %v", err)
	}
	
	// Ensure they're different tweets
	if challengerTweet.ID == defenderTweet.ID {
		return fmt.Errorf("challenger and defender cannot use the same tweet")
	}
	
	return nil
}

// VerifyBattleThread simulates verification of a rap battle thread
// In production, this would interface with an oracle or scraping service
func (ic *IntentClient) VerifyBattleThread(ctx context.Context, challengerURI, defenderURI string) (*BattleVerification, error) {
	verification := &BattleVerification{
		ChallengerURI:    challengerURI,
		DefenderURI:      defenderURI,
		ConsecutiveLikes: make(map[string]int),
	}
	
	// Parse URIs
	challengerTweet, err := ic.ParseTweetURI(challengerURI)
	if err != nil {
		return nil, err
	}
	
	defenderTweet, err := ic.ParseTweetURI(defenderURI)
	if err != nil {
		return nil, err
	}
	
	// In production, this would:
	// 1. Verify defender tweet is a reply to challenger
	// 2. Traverse the thread and count consecutive likes
	// 3. Determine who broke the streak
	
	// For now, simulate the verification
	verification.ConsecutiveLikes[challengerTweet.ID] = 150
	verification.ConsecutiveLikes[defenderTweet.ID] = 100
	
	// Simulate checking the thread
	// In reality, this would traverse replies and check like counts
	
	return verification, nil
}

// GenerateBattlePrompt creates a prompt for starting a rap battle
func (ic *IntentClient) GenerateBattlePrompt(ticker string, stake string) string {
	template := `🎤 RAP BATTLE CHALLENGE 🎤
Ticker: %s
Stake: %s
Rules: Most consecutive 100+ liked verses wins!
Reply with your first verse to accept!
#CasaBattle #%s`
	
	return fmt.Sprintf(template, ticker, stake, ticker)
}

// Helper functions

func (ic *IntentClient) extractTweetID(tweetURL string) string {
	// Handle both full URLs and URIs
	re := regexp.MustCompile(`(?:twitter\.com|x\.com)/\w+/status/(\d+)`)
	matches := re.FindStringSubmatch(tweetURL)
	if len(matches) > 1 {
		return matches[1]
	}
	
	// Try URI format
	re = regexp.MustCompile(`/?\w+/status/(\d+)`)
	matches = re.FindStringSubmatch(tweetURL)
	if len(matches) > 1 {
		return matches[1]
	}
	
	// Assume it's just the ID
	if regexp.MustCompile(`^\d+$`).MatchString(tweetURL) {
		return tweetURL
	}
	
	return ""
}

// BattleOracle simulates oracle functionality for verifying battles
type BattleOracle struct {
	client *IntentClient
}

func NewBattleOracle() *BattleOracle {
	return &BattleOracle{
		client: NewIntentClient(),
	}
}

// CheckBattleOutcome checks the outcome of a rap battle
func (bo *BattleOracle) CheckBattleOutcome(challengerURI, defenderURI string) (*BattleResult, error) {
	// This would interface with actual Twitter data
	// For now, return mock data
	
	result := &BattleResult{
		ChallengerBrokeStreak: false,
		DefenderBrokeStreak:   false,
		Winner:                "", // Determined by contract if both maintained
	}
	
	// Simulate checking consecutive likes
	// In production, this would:
	// 1. Fetch the thread starting from challenger tweet
	// 2. Check each verse for 100+ likes
	// 3. Determine who first dropped below threshold
	
	return result, nil
}

type BattleResult struct {
	ChallengerBrokeStreak bool
	DefenderBrokeStreak   bool
	Winner                string
	BrokenAtTweet         string
}

// IntentHandler manages Twitter intents in the UI
type IntentHandler struct {
	client *IntentClient
}

func NewIntentHandler() *IntentHandler {
	return &IntentHandler{
		client: NewIntentClient(),
	}
}

// OpenTweetIntent opens a tweet intent in the user's browser
func (ih *IntentHandler) OpenTweetIntent(text string, replyTo string) error {
	intentURL := ih.client.CreateTweetIntent(text, replyTo)
	// In a GUI app, this would open the browser
	// For CLI, we return the URL
	fmt.Printf("Open this URL to tweet: %s\n", intentURL)
	return nil
}

// ShareBattleResult creates a share intent for battle results
func (ih *IntentHandler) ShareBattleResult(winner, loser, ticker string, stake string) error {
	text := fmt.Sprintf("🏆 %s defeated %s in a %s rap battle! 💰 Stake: %s\n#CasaBattle #%s",
		winner, loser, ticker, stake, ticker)
	
	return ih.OpenTweetIntent(text, "")
}