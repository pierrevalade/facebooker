require 'digest/md5'
require 'cgi'

module Facebooker
  #
  # Raised when trying to perform an operation on a user
  # other than the logged in user (if that's unallowed)
  class NonSessionUser < Exception;  end
  class Session
    class SessionExpired < Exception; end
    class UnknownError < Exception; end
    class ServiceUnavailable < Exception; end
    class MaxRequestsDepleted < Exception; end
    class HostNotAllowed < Exception; end
    class MissingOrInvalidParameter < Exception; end
    class InvalidAPIKey < Exception; end
    class SessionExpired < Exception; end
    class CallOutOfOrder < Exception; end
    class IncorrectSignature     < Exception; end
    class ConfigurationMissing < Exception; end
    class FQLParseError < Exception; end
    class FQLFieldDoesNotExist < Exception; end
    class FQLTableDoesNotExist < Exception; end
    class FQLStatementNotIndexable < Exception; end
    class FQLFunctionDoesNotExist < Exception; end
    class FQLWrongNumberArgumentsPassedToFunction < Exception; end
  
    API_SERVER_BASE_URL       = "api.facebook.com"
    API_PATH_REST             = "/restserver.php"
    WWW_SERVER_BASE_URL       = "www.facebook.com"
    WWW_PATH_LOGIN            = "/login.php"
    WWW_PATH_ADD              = "/add.php"
    WWW_PATH_INSTALL          = "/install.php"
    
    attr_writer :auth_token
          
    def self.create(api_key, secret_key)
      raise ArgumentError unless !api_key.nil? && !secret_key.nil?
      new(api_key, secret_key)
    end
    
    def self.api_key
      extract_key_from_environment(:api) || extract_key_from_configuration_file(:api) rescue report_inability_to_find_key(:api)
    end
    
    def self.secret_key
      extract_key_from_environment(:secret) || extract_key_from_configuration_file(:secret) rescue report_inability_to_find_key(:secret)
    end
    
    def login_url(options={})
      options = default_login_url_options.merge(options)
      "http://www.facebook.com/login.php?api_key=#{@api_key}&v=1.0#{login_url_optional_parameters(options)}"
    end

    def install_url(options={})
      "http://www.facebook.com/install.php?api_key=#{@api_key}&v=1.0#{install_url_optional_parameters(options)}"
    end

    def install_url_optional_parameters(options)
      optional_parameters = []
      optional_parameters << "&next=#{CGI.escape(options[:next])}" if options[:next]
      optional_parameters.join
    end

    def login_url_optional_parameters(options)
      # It is important that unused options are omitted as stuff like &canvas=false will still display the canvas. 
      optional_parameters = []
      optional_parameters << "&next=#{CGI.escape(options[:next])}" if options[:next]
      optional_parameters << "&skipcookie=true" if options[:skip_cookie]
      optional_parameters << "&hide_checkbox=true" if options[:hide_checkbox]
      optional_parameters << "&canvas=true" if options[:canvas]
      optional_parameters.join
    end
  
    def default_login_url_options
      {}
    end
    
    def initialize(api_key, secret_key)
      @api_key = api_key
      @secret_key = secret_key
    end
    
    def secret_for_method(method_name)
      @secret_key
    end
      
    def auth_token
      @auth_token ||= post 'facebook.auth.createToken'
    end
    
    def infinite?
      @expires == 0
    end
    
    def expired?
      @expires.nil? || (!infinite? && Time.at(@expires) <= Time.now)
    end
    
    def secured?
      !@session_key.nil? && !expired?
    end
    
    def secure!
      response = post 'facebook.auth.getSession', :auth_token => auth_token
      secure_with!(response['session_key'], response['uid'], response['expires'], response['secret'])
    end    
    
    def secure_with!(session_key, uid, expires, secret_from_session = nil)
      @session_key = session_key
      @uid = Integer(uid)
      @expires = Integer(expires)
      @secret_from_session = secret_from_session
    end
    
    def fql_query(query, format = 'XML')
      response = post('facebook.fql.query', :query => query, :format => format)
      type = response.shift
      response.shift.map do |hash|
        case type
        when 'user'
          user = User.new
          user.session = self
          user.populate_from_hash!(hash)
          user
        when 'photo'
          Photo.from_hash(hash)
        when 'event_member'
          Event::Attendance.from_hash(hash)
        end
      end        
    end
    
    def user
      @user ||= User.new(uid, self)
    end
    
    #
    # This one has so many parameters, a Hash seemed cleaner than a long param list.  Options can be:
    # :uid => Filter by events associated with a user with this uid
    # :eids => Filter by this list of event ids. This is a comma-separated list of eids.
    # :start_time => Filter with this UTC as lower bound. A missing or zero parameter indicates no lower bound. (Time or Integer)
    # :end_time => Filter with this UTC as upper bound. A missing or zero parameter indicates no upper bound. (Time or Integer)
    # :rsvp_status => Filter by this RSVP status.
    def events(options = {})
      @events ||= post('facebook.events.get', options).map do |hash|
        Event.from_hash(hash)
      end
    end
    
    def event_members(eid)
      @members ||= post('facebook.events.getMembers', :eid => eid).map do |attendee_hash|
        Event::Attendance.from_hash(attendee_hash)
      end
    end
    
    
    #
    # Returns a proxy object for handling calls to Facebook cached items
    # such as images and FBML ref handles
    def server_cache
      Facebooker::ServerCache.new(self)
    end
    
    #
    # Given an array like:
    # [[userid, otheruserid], [yetanotherid, andanotherid]]
    # returns a Hash indicating friendship of those pairs:
    # {[userid, otheruserid] => true, [yetanotherid, andanotherid] => false}
    # if one of the Hash values is nil, it means the facebook platform's answer is "I don't know"
    def check_friendship(array_of_pairs_of_users)
      uids1 = []
      uids2 = []
      array_of_pairs_of_users.each do |pair|
        uids1 = pair.first
        uids2 = pair.last
      end
      post('facebook.friends.areFriends', :uids1 => uids1, :uids2 => uids2)
    end
    
    def get_photos(pids = nil, subj_id = nil,  aid = nil)
      if [subj_id, pids, aid].all? {|arg| arg.nil?}
        raise ArgumentError, "Can't get a photo without a picture, album or subject ID" 
      end
      @photos = post('facebook.photos.get', :subj_id => subj_id, :pids => pids, :aid => aid ).map do |hash|
        Photo.from_hash(hash)
      end
    end
    
    def get_albums(aids)
      @albums = post('facebook.photos.getAlbums', :aids => aids).map do |hash|        
        Album.from_hash(hash)
      end
    end
    
    def get_tags(pids)
      @tags = post('facebook.photos.getTags', :pids => pids).map do |hash|
        Tag.from_hash(hash)
      end
    end
    
    def add_tags(pid, x, y, tag_uid = nil, tag_text = nil )
      if [tag_uid, tag_text].all? {|arg| arg.nil?}
        raise ArgumentError, "Must enter a name or string for this tag"        
      end
      @tags = post('facebook.photos.addTag', :pid => pid, :tag_uid => tag_uid, :tag_text => tag_text, :x => x, :y => y )
    end
    
    def send_notification(user_ids, fbml, email_fbml = nil)
      params = {:notification => fbml, :to_ids => user_ids.join(',')}
      if email_fbml
        params[:email] = email_fbml
      end
      post 'facebook.notifications.send', params
    end

    def send_request(user_ids, request_type, content, image_url)
      send_request_or_invitation(user_ids, request_type, content, image_url, false)      
    end
    
    ##
    # Send an invitatino to a list of users
    # +user_ids+ - An Array of facebook IDs to which to send this invitation.
    # +invitation_type+ - 
    # +content+ - Text of the invitation
    # +image_url+ - String URL to image to associate with this invitation.
    def send_invitation(user_ids, invitation_type, content, image_url)
      send_request_or_invitation(user_ids, invitation_type, content, image_url, true)
    end
    
    # Only serialize the bare minimum to recreate the session.
    def marshal_load(variables)#:nodoc:
      @session_key, @uid, @expires, @secret_from_session, @auth_token, @api_key, @secret_key = variables
    end
    
    # Only serialize the bare minimum to recreate the session.    
    def marshal_dump#:nodoc:
      [@session_key, @uid, @expires, @secret_from_session, @auth_token, @api_key, @secret_key]
    end
    
    class Desktop < Session
      def login_url
        super + "&auth_token=#{auth_token}"
      end

      def secret_for_method(method_name)
        secret = auth_request_methods.include?(method_name) ? super : @secret_from_session
        secret
      end
      
      def post(method, params = {})
        if method == 'facebook.profile.getFBML' || method == 'facebook.profile.setFBML'
          raise NonSessionUser.new("User #{@uid} is not the logged in user.") unless @uid == params[:uid]
        end
        super
      end
      private
        def auth_request_methods
          ['facebook.auth.getSession', 'facebook.auth.createToken']
        end
    end
    
    def post(method, params = {})
      params[:method] = method
      params[:api_key] = @api_key
      params[:call_id] = Time.now.to_f.to_s unless method == 'facebook.auth.getSession'
      params[:v] = "1.0"
      @session_key && params[:session_key] ||= @session_key
      service.post(params.merge(:sig => signature_for(params)))      
    end
    
    def self.configuration_file_path
      @configuration_file_path || File.expand_path("~/.facebookerrc")
    end
    
    def self.configuration_file_path=(path)
      @configuration_file_path = path
    end
    
    private
      def self.extract_key_from_environment(key_name)
        val = ENV["FACEBOOK_" + key_name.to_s.upcase + "_KEY"]
      end
    
      def self.extract_key_from_configuration_file(key_name)
        read_configuration_file[key_name]
      end
    
      def self.report_inability_to_find_key(key_name)
        raise ConfigurationMissing, "Could not find configuration information for #{key_name}"
      end
    
      def self.read_configuration_file
        eval(File.read(configuration_file_path))
      end
    
      def service
        @service ||= Service.new(API_SERVER_BASE_URL, API_PATH_REST, @api_key)      
      end
    
      def uid
        @uid || (secure!; @uid)
      end
      
      def signature_for(params)
        raw_string = params.inject([]) do |collection, pair|
          collection << pair.join("=")
          collection
        end.sort.join
        Digest::MD5.hexdigest([raw_string, secret_for_method(params[:method])].join)
      end
        
      def send_request_or_invitation(user_ids, request_type, content, image_url, invitation)
        params = {:to_ids => user_ids, :type => request_type, :content => content, :image => image_url, :invitation => invitation}
        post 'facebook.notifications.sendRequest', params
      end    
  end
  
  class CanvasSession < Session
    def default_login_url_options
      {:canvas => true}
    end
  end
end
