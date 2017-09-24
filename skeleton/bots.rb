require 'twitter_ebooks'

# This is an example bot definition with event handlers commented out
# You can define and instantiate as many bots as you like

# Information about a particular Twitter user we know
class UserInfo
  attr_reader :username

  # @return [Integer] how many times we can pester this user unprompted
  attr_accessor :pesters_left

  # @param username [String]
  def initialize(username)
    @username = username
    @pesters_left = 1
  end
end

class MyBot < Ebooks::Bot
  attr_accessor :original, :model, :model_path

  # Configuration here applies to all MyBots
  def configure
    # Consumer details come from registering an app at https://dev.twitter.com/
    # Once you have consumer details, use "ebooks auth" for new access tokens
    self.consumer_key = ENV[TWITTER_KEY] || '' # Your app consumer key
    self.consumer_secret = [TWITTER_SECRET] || '' # Your app consumer secret

    # Users to block instead of interacting with
    self.blacklist = [
      'kylelehk', 'friedrichsays', 'Sudieofna', 'tnietzschequote',
      'NerdsOnPeriod', 'FSR', 'BafflingQuotes', 'Obey_Nxme'
    ]

    # Range in seconds to randomize delay when bot.delay is called
    self.delay_range = 1..6
    @userinfo = {}
  end

  def top100; @top100 ||= model.keywords.take(100); end
  def top20;  @top20  ||= model.keywords.take(20); end

  def on_startup
    load_model!
    # scheduler.cron '0 0 * * *' do
    scheduler.every '24h' do
      tweet(model.make_statement)
      # Tweet something every 24 hours
      # See https://github.com/jmettraux/rufus-scheduler
      # tweet("hi")
      # pictweet("hi", "cuteselfie.jpg")
    end
  end

  def on_message(dm)
    delay do
      reply(dm, model.make_response(dm.text))
    end
  end

  def on_mention(tweet)
    # Become more inclined to pester a user when they talk to us
    userinfo(tweet.user.screen_name).pesters_left += 1

    delay do
      reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit))
    end
  end

  def on_timeline(tweet)
    # Reply to a tweet in the bot's timeline

    return if tweet.retweeted_status?
    return unless can_pester?(tweet.user.screen_name)

    tokens = Ebooks::NLP.tokenize(tweet.text)

    interesting = tokens.find { |t| top100.include?(t.downcase) }
    very_interesting = tokens.find_all { |t| top20.include?(t.downcase) }.length > 2

    delay do
      if very_interesting
        favorite(tweet) if rand < 0.5
        retweet(tweet) if rand < 0.1
        if rand < 0.01
          userinfo(tweet.user.screen_name).pesters_left -= 1
          reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit))
        end
      elsif interesting
        favorite(tweet) if rand < 0.05
        if rand < 0.001
          userinfo(tweet.user.screen_name).pesters_left -= 1
          reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit))
        end
      end
    end
  end

  # Find information we've collected about a user
  # @param username [String]
  # @return [Ebooks::UserInfo]
  def userinfo(username)
    @userinfo[username] ||= UserInfo.new(username)
  end

  # Check if we're allowed to send unprompted tweets to a user
  # @param username [String]
  # @return [Boolean]
  def can_pester?(username)
    userinfo(username).pesters_left > 0
  end

  # Only follow our original user or people who are following our original user
  # @param user [Twitter::User]
  def can_follow?(username)
    @original.nil? || username.casecmp(@original) == 0 || twitter.friendship?(username, @original)
  end

  def favorite(tweet)
    if can_follow?(tweet.user.screen_name)
      super(tweet)
    else
      log "Unfollowing @#{tweet.user.screen_name}"
      twitter.unfollow(tweet.user.screen_name)
    end
  end

  def on_follow(user)
    # Follow a user back
    # follow(user.screen_name)
  end

  def on_favorite(user, tweet)
    # Follow user who just favorited bot's tweet
    # follow(user.screen_name)
  end

  def on_retweet(tweet)
    # Follow user who just retweeted bot's tweet
    # follow(tweet.user.screen_name)
  end

  private
  def load_model!
    return if @model

    @model_path ||= "model/#{original}.model"

    log "Loading model #{model_path}"
    @model = Ebooks::Model.load(model_path)
  end
end

# Make a MyBot and attach it to an account
MyBot.new("contest_player") do |bot|
  bot.access_token = "" # Token connecting the app to this account
  bot.access_token_secret = "" # Secret connecting the app to this account

  bot.original = "0xabad1dea"
end
