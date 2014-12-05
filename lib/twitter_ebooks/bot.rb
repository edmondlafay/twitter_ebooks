# encoding: utf-8
require 'twitter'
require 'rufus/scheduler'

module Ebooks
  class ConfigurationError < Exception
  end

  class UserInfo
    attr_reader :username

    # number of times we've interacted with a timeline tweet, unprompted
    attr_accessor :pesters_left

    # number of times we've included them in a mention that wasn't from them
    attr_accessor :includes_left

    def initialize(username)
      @username = username
      @pesters_left = 1
      @includes_left = 2
    end

    def can_pester?
      @pesters_left > 0
    end

    def can_include?
      @includes_left > 0
    end
  end

  # Represents a current "interaction state" with another user
  class Interaction
    attr_reader :userinfo, :received, :last_update

    def initialize(userinfo)
      @userinfo = userinfo
      @received = []
      @last_update = Time.now
    end

    def receive(tweet)
      @received << tweet
      @last_update = Time.now

      # When we receive a tweet from someone, become more
      # inclined to pester them and include in mentions
      @userinfo.pesters_left += 1
      @userinfo.includes_left += 2
    end

    # Make an informed guess as to whether this user is a bot
    # based on its username and reply speed
    def is_bot?
      if @received.length > 2
        if (@received[-1].created_at - @received[-3].created_at) < 30
          return true
        end
      end

      @userinfo.username.include?("ebooks")
    end

    def continue?
      if is_bot?
        true if @received.length < 2
      else
        true
      end
    end
  end

  # Meta information about a tweet that we calculate for ourselves
  class TweetMeta
    attr_accessor :mentions # array: usernames mentioned in tweet
    attr_accessor :mentionless # string: text of tweet with mentions removed
    attr_accessor :reply_mentions # array: usernames to include in a reply
    attr_accessor :reply_prefix # string: processed string to start reply with
    attr_accessor :limit # integer: available room to calculate reply

    attr_accessor :bot, :tweet

    def mentions_bot?
      # To check if this is someone talking to us, ensure:
      # - The tweet mentions list contains our username
      # - The tweet is not being retweeted by somebody else
      # - Or soft-retweeted by somebody else
      @mentions.map(&:downcase).include?(@bot.username.downcase) && !@tweet.retweeted_status? && !@tweet.text.start_with?('RT ')
    end

    def initialize(bot, ev)
      @bot = bot
      @tweet = ev

      @mentions = ev.attrs[:entities][:user_mentions].map { |x| x[:screen_name] }

      # Process mentions to figure out who to reply to
      # i.e. not self and nobody who has seen too many secondary mentions
      reply_mentions = @mentions.reject do |m|
        username = m.downcase
        username == @bot.username || !@bot.userinfo(username).can_include?
      end
      @reply_mentions = ([ev.user.screen_name] + reply_mentions).uniq

      @reply_prefix = @reply_mentions.map { |m| '@'+m }.join(' ') + ' '
      @limit = 140 - @reply_prefix.length

      mless = ev.text
      begin
        ev.attrs[:entities][:user_mentions].reverse.each do |entity|
          last = mless[entity[:indices][1]..-1]||''
          mless = mless[0...entity[:indices][0]] + last.strip
        end
      rescue Exception
        p ev.attrs[:entities][:user_mentions]
        p ev.text
        raise
      end
      @mentionless = mless
    end
  end

  class Bot
    attr_accessor :consumer_key, :consumer_secret,
                  :access_token, :access_token_secret

    attr_reader :twitter, :stream, :thread

    # Configuration
    attr_accessor :username, :delay_range, :blacklist

    @@all = [] # List of all defined bots
    def self.all; @@all; end

    def self.get(name)
      all.find { |bot| bot.username == name }
    end

    def log(*args)
      STDOUT.print "@#{@username}: " + args.map(&:to_s).join(' ') + "\n"
      STDOUT.flush
    end

    def initialize(*args, &b)
      @username ||= nil
      @blacklist ||= []
      @delay_range ||= 0

      @users ||= {}
      @interactions ||= {}
      configure(*args, &b)

      # Tweet ids we've already observed, to avoid duplication
      @seen_tweets ||= {}
      Bot.all << self
    end

    def userinfo(username)
      @users[username] ||= UserInfo.new(username)
    end

    def interaction(username)
      if @interactions[username] &&
         Time.now - @interactions[username].last_update < 600
        @interactions[username]
      else
        @interactions[username] = Interaction.new(userinfo(username))
      end
    end

    def twitter
      @twitter ||= Twitter::REST::Client.new do |config|
        config.consumer_key = @consumer_key
        config.consumer_secret = @consumer_secret
        config.access_token = @access_token
        config.access_token_secret = @access_token_secret
      end
    end

    def stream
      @stream ||= Twitter::Streaming::Client.new do |config|
        config.consumer_key = @consumer_key
        config.consumer_secret = @consumer_secret
        config.access_token = @access_token
        config.access_token_secret = @access_token_secret
      end
    end

    # Calculate some meta information about a tweet relevant for replying
    def calc_meta(ev)
      TweetMeta.new(self, ev)
    end

    # Receive an event from the twitter stream
    def receive_event(ev)
      if ev.is_a? Array # Initial array sent on first connection
        log "Online!"
        return
      end

      if ev.is_a? Twitter::DirectMessage
        return if ev.sender.screen_name == @username # Don't reply to self
        log "DM from @#{ev.sender.screen_name}: #{ev.text}"
        fire(:direct_message, ev)

      elsif ev.respond_to?(:name) && ev.name == :follow
        return if ev.source.screen_name == @username
        log "Followed by #{ev.source.screen_name}"
        fire(:follow, ev.source)

      elsif ev.is_a? Twitter::Tweet
        return unless ev.text # If it's not a text-containing tweet, ignore it
        return if ev.user.screen_name == @username # Ignore our own tweets

        meta = calc_meta(ev)

        if blacklisted?(ev.user.screen_name)
          log "Blocking blacklisted user @#{ev.user.screen_name}"
          @twitter.block(ev.user.screen_name)
        end

        # Avoid responding to duplicate tweets
        if @seen_tweets[ev.id]
          return
        else
          @seen_tweets[ev.id] = true
        end

        if meta.mentions_bot?
          log "Mention from @#{ev.user.screen_name}: #{ev.text}"
          interaction(ev.user.screen_name).receive(ev)
          fire(:mention, ev, meta)
        else
          fire(:timeline, ev, meta)
        end

      elsif ev.is_a?(Twitter::Streaming::DeletedTweet) ||
            ev.is_a?(Twitter::Streaming::Event)
        # pass
      else
        log ev
      end
    end

    def start_stream
      log "starting tweet stream"

      stream.user do |ev|
        receive_event ev
      end
    end

    def prepare
      # Sanity check
      if @username.nil?
        raise ConfigurationError, "bot.username cannot be nil"
      end

      twitter
      fire(:startup)
    end

    # Connects to tweetstream and opens event handlers for this bot
    def start
      start_stream
    end

    # Fire an event
    def fire(event, *args)
      handler = "on_#{event}".to_sym
      if respond_to? handler
        self.send(handler, *args)
      end
    end

    def delay(&b)
      time = @delay.to_a.sample unless @delay.is_a? Integer
      sleep time
    end

    def blacklisted?(username)
      if @blacklist.include?(username)
        true
      else
        false
      end
    end

    # Reply to a tweet or a DM.
    def reply(ev, text, opts={})
      opts = opts.clone

      if ev.is_a? Twitter::DirectMessage
        return if blacklisted?(ev.sender.screen_name)
        log "Sending DM to @#{ev.sender.screen_name}: #{text}"
        twitter.create_direct_message(ev.sender.screen_name, text, opts)
      elsif ev.is_a? Twitter::Tweet
        meta = calc_meta(ev)

        if !interaction(ev.user.screen_name).continue?
          log "Not replying to suspected bot @#{ev.user.screen_name}"
          return
        end

        if !meta.mentions_bot?
          if !userinfo(ev.user.screen_name).can_pester?
            log "Not replying: leaving @#{ev.user.screen_name} alone"
            return
          end
        end

        meta.reply_mentions.each do |username|
          # Decrease includes_left for everyone involved here who isn't
          # directly talking to the bot
          if !meta.mentions_bot? || username != ev.user.screen_name
            userinfo(username).includes_left -= 1
          end
        end

        log "Replying to @#{ev.user.screen_name} with: #{meta.reply_prefix + text}"
        twitter.update(meta.reply_prefix + text, in_reply_to_status_id: ev.id)
      else
        raise Exception("Don't know how to reply to a #{ev.class}")
      end
    end

    def favorite(tweet)
      return if blacklisted?(tweet.user.screen_name)
      log "Favoriting @#{tweet.user.screen_name}: #{tweet.text}"

      meta = calc_meta(tweet)
      #if !meta[:mentions_bot] && !userinfo(ev.user.screen_name).can_pester?
      #  log "Not favoriting: leaving @#{ev.user.screen_name} alone"
      #end

      begin
        twitter.favorite(tweet.id)
      rescue Twitter::Error::Forbidden
        log "Already favorited: #{tweet.user.screen_name}: #{tweet.text}"
      end
    end

    def retweet(tweet)
      return if blacklisted?(tweet.user.screen_name)
      log "Retweeting @#{tweet.user.screen_name}: #{tweet.text}"

      begin
        twitter.retweet(tweet.id)
      rescue Twitter::Error::Forbidden
        log "Already retweeted: #{tweet.user.screen_name}: #{tweet.text}"
      end
    end

    def follow(*args)
      log "Following #{args}"
      twitter.follow(*args)
    end

    def unfollow(*args)
      log "Unfollowing #{args}"
      twiter.unfollow(*args)
    end

    def tweet(*args)
      log "Tweeting #{args.inspect}"
      twitter.update(*args)
    end

    def scheduler
      @scheduler ||= Rufus::Scheduler.new
    end

    # could easily just be *args however the separation keeps it clean.
    def pictweet(txt, pic, *args)
      log "Tweeting #{txt.inspect} - #{pic} #{args}"
      twitter.update_with_media(txt, File.new(pic), *args)
    end
  end
end
