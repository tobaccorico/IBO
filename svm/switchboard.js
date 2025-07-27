
// This runs in Switchboard's serverless environment
const { TwitterApi } = require('twitter-api-v2');

// Initialize Twitter client (credentials from Switchboard secrets)
const twitterClient = new TwitterApi({
    appKey: process.env.TWITTER_API_KEY,
    appSecret: process.env.TWITTER_API_SECRET,
    accessToken: process.env.TWITTER_ACCESS_TOKEN,
    accessSecret: process.env.TWITTER_ACCESS_SECRET,
});

const roClient = twitterClient.readOnly;

async function main() {
    // Parse input parameters from Switchboard
    const params = JSON.parse(process.env.FUNCTION_DATA || '{}');
    const { battle_id, challenger_tweet, defender_tweet } = params;
    
    if (!challenger_tweet || !defender_tweet) {
        throw new Error('Missing challenger or defender tweet URIs');
    }
    
    // Extract tweet IDs
    const challengerTweetId = extractTweetId(challenger_tweet);
    const defenderTweetId = extractTweetId(defender_tweet);
    
    if (!challengerTweetId || !defenderTweetId) {
        throw new Error('Invalid tweet URI format');
    }
    
    try {
        // First verify defender's tweet is a reply to challenger's tweet
        const defenderTweet = await roClient.v2.singleTweet(defenderTweetId, {
            'tweet.fields': ['in_reply_to_user_id', 'referenced_tweets'],
        });
        
        // Check if defender's tweet references challenger's tweet
        const isValidReply = defenderTweet.data.referenced_tweets?.some(
            ref => ref.type === 'replied_to' && ref.id === challengerTweetId
        );
        
        if (!isValidReply) {
            throw new Error('Defender tweet must be a reply to challenger tweet');
        }
        
        // Get both threads starting from their respective tweets
        const challengerThread = await getThreadFromTweet(challengerTweetId, challengerTweetId);
        const defenderThread = await getThreadFromTweet(defenderTweetId, defenderTweetId);
        
        // Check consecutive likes for each thread
        const challengerResult = checkConsecutiveLikes(challengerThread);
        const defenderResult = checkConsecutiveLikes(defenderThread);
        
        // Return oracle result
        return {
            battle_id,
            challenger_broke_streak: challengerResult.brokeStreak,
            defender_broke_streak: defenderResult.brokeStreak,
            broken_at_tweet: challengerResult.brokenAt || defenderResult.brokenAt,
            timestamp: Date.now(),
        };
        
    } catch (error) {
        console.error('Error checking battle threads:', error);
        throw error;
    }
}

// Extract tweet ID from various Twitter URL formats
function extractTweetId(url) {
    const patterns = [
        /twitter\.com\/\w+\/status\/(\d+)/,
        /x\.com\/\w+\/status\/(\d+)/,
        /^(\d+)$/ // Just the ID
    ];
    
    for (const pattern of patterns) {
        const match = url.match(pattern);
        if (match) return match[1];
    }
    return null;
}

// Get a thread starting from a specific tweet (following replies to itself)
async function getThreadFromTweet(startTweetId, authorTweetId) {
    const thread = [];
    let currentTweetId = startTweetId;
    const maxDepth = 100; // Prevent infinite loops
    
    for (let i = 0; i < maxDepth; i++) {
        try {
            // Get the current tweet
            const tweet = await roClient.v2.singleTweet(currentTweetId, {
                'tweet.fields': ['author_id', 'public_metrics', 'created_at', 'referenced_tweets'],
            });
            
            thread.push(tweet.data);
            
            // Find replies to this tweet by the same author
            const replies = await roClient.v2.search(
                `to:${tweet.data.author_id} conversation_id:${currentTweetId}`,
                {
                    'tweet.fields': ['author_id', 'public_metrics', 'created_at', 'in_reply_to_user_id', 'referenced_tweets'],
                    'max_results': 100,
                }
            );
            
            // Find the next tweet in the thread (reply by same author to their own tweet)
            let nextTweet = null;
            for await (const reply of replies) {
                // Check if this is a self-reply to the current tweet
                if (reply.author_id === tweet.data.author_id &&
                    reply.referenced_tweets?.some(ref => 
                        ref.type === 'replied_to' && ref.id === currentTweetId
                    )) {
                    nextTweet = reply;
                    break;
                }
            }
            
            if (!nextTweet) {
                // End of thread
                break;
            }
            
            currentTweetId = nextTweet.id;
            
        } catch (error) {
            console.error('Error fetching tweet in thread:', error);
            break;
        }
    }
    
    return thread;
}

// Check if all tweets in a thread have consecutive likes (no zeros, no decreases)
function checkConsecutiveLikes(thread) {
    if (thread.length === 0) {
        return {
            brokeStreak: false,
            brokenAt: null,
        };
    }
    
    let lastLikes = 0;
    
    for (let i = 0; i < thread.length; i++) {
        const tweet = thread[i];
        const likes = tweet.public_metrics?.like_count || 0;
        
        // Check if tweet has zero likes (breaks the streak)
        if (likes === 0) {
            return {
                brokeStreak: true,
                brokenAt: `https://twitter.com/i/status/${tweet.id}`,
            };
        }
        
        // For subsequent tweets, check if likes decreased
        if (i > 0 && likes < lastLikes) {
            return {
                brokeStreak: true,
                brokenAt: `https://twitter.com/i/status/${tweet.id}`,
            };
        }
        
        lastLikes = likes;
    }
    
    // Maintained the streak
    return {
        brokeStreak: false,
        brokenAt: null,
    };
}

// Switchboard function handler
exports.handler = async function() {
    try {
        const result = await main();
        
        // Encode result for on-chain consumption
        const encoded = Buffer.from(JSON.stringify(result));
        
        // Return base64 encoded result
        return {
            success: true,
            result: encoded.toString('base64'),
        };
    } catch (error) {
        return {
            success: false,
            error: error.message,
        };
    }
};
