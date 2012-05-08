# Copyright 2012 Georgios Gousios <gousiosg@gmail.com>
#
# Redistribution and use in source and binary forms, with or
# without modification, are permitted provided that the following
# conditions are met:
#
#   1. Redistributions of source code must retain the above
#      copyright notice, this list of conditions and the following
#      disclaimer.
#
#   2. Redistributions in binary form must reproduce the above
#      copyright notice, this list of conditions and the following
#      disclaimer in the documentation and/or other materials
#      provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
# USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
# AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
# ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require 'rubygems'
require 'yaml'
require 'json'
require 'net/http'
require 'logger'
require 'set'
require 'open-uri'
require 'pp'
require 'sequel'

require 'schema-sql/schema'

class GHTorrentSQL

  attr_reader :settings
  attr_reader :log
  attr_reader :num_api_calls

  def init(config)
    @settings = YAML::load_file config
    get_db
    @ts = Time.now().tv_sec()
    @num_api_calls = 0
    @log = Logger.new(STDOUT)
    @url_base = @settings['mirror']['urlbase']
    @url_base_v2 = @settings['mirror']['urlbase_v2']
  end

  # db related functions
  def get_db

    @db = Sequel.connect('sqlite://github.db')
    if @db.tables.empty?
      puts("Database empty, creating schema")
      create_schema(@db)
    end
    @db
  end

  # Specific API call functions and caches

  # Get commit information.
  def get_commit(user, repo, sha)

    unless sha.match(/[a-f0-9]{40}$/)
      @log.error "Ignoring commit #{sha}"
      return
    end

    commits = @db[:commit]

    ensure_user(user)
    ensure_repo(user, repo)

    if commits.filter(:sha => sha).empty?
      url = @url_base + "repos/#{user}/#{repo}/commits/#{sha}"
      c = api_request(url)

      ensure_user(c['commit']['author']['email'])
      ensure_user(c['commit']['committer']['email'])

      commits.insert(:sha => sha,
                     :message => c['message'],
                     :login_id => @db[:user].filter(:login => user).first[:id],
                     :author_id => @db[:user].filter(:login => c['commit']['author']['email']).first[:id],
                     :committer_id => @db[:user].filter(:login => c['commit']['committer']['email']).first[:id]
      )

      @log.info "New commit #{sha}"
    else
      @log.debug "Commit #{sha} exists"
    end
  end

  # Ensure that a user exists, or fetch its latest state from Github
  def ensure_user(user)
    if user.match(/@/)
      ensure_user_byemail(user)
    else
      ensure_user_byuname(user)
    end
  end

  def ensure_user_byuname(user)
    users = @db[:user]
    if users.filter(:login => user).empty?
      url = @url_base + "users/#{user}"
      u = api_request(url)

      users.insert(:login => u['login'],
                   :name => u['name'],
                   :company => u['company'],
                   :email => u['email'],
                   :hireable => boolean(u['hirable']),
                   :bio => u['bio'],
                   :location => u['location'],
                   :created_at => date(u['created_at']))

      @log.info "New user #{user}"
    else
      @log.debug "User #{user} exists"
    end
  end

  # We cannot yet retrieve users by email from Github. Just go over the
  # database and try to find the user by email, if stored. Otherwise,
  # add the user to the DB by email
  def ensure_user_byemail(user)
    users = @db[:user]
    usr = users.first(:email => user)

    if usr.nil?
      # Try Github API v2 user search by email. This is optional info, so
      # it may not return any data.
      # http://develop.github.com/p/users.html
      url = @url_base_v2 + "user/email/#{user}"
      u = api_request(url)

      if u['user'].nil? or u['user']['login'].nil?
        @log.debug "Cannot find #{user} through API v2 query"
      else
        users.insert(:login => u['user']['login'],
                     :name => u['user']['name'],
                     :company => u['user']['company'],
                     :email => u['user']['email'],
                     :hireable => nil,
                     :bio => nil,
                     :location => u['user']['location'],
                     :created_at => date(u['user']['created_at']))
        @log.debug "Found #{user} through API v2 query"
      end

      @log.warn "Cannot find user #{user}"
    else
      @log.debug "User with email #{user} exists"
    end

  end

  # Ensure that a repo exists, or fetch its latest state from Github
  def ensure_repo(user, repo)

    ensure_user(user)
    repos = @db[:project]

    if repos.filter(:name => repo).empty?
      url = @url_base + "repos/#{user}/#{repo}"
      r = api_request(url)

      repos.insert(:url => r['url'],
                   :owner => @db[:user].filter(:login => user).first[:id],
                   :name => r['name'],
                   :description => r['description'],
                   :language => r['language'],
                   :created_at => date(r['created_at']))

      @log.info "New repo #{repo}"
    else
      @log.debug "Repo #{repo} exists"
    end
  end

  def boolean(arg)
    case arg
      when 'true'
        1
      when 'false'
        0
      when nil
        0
    end
  end

  # Dates returned by Github are formatted as:
  # - yyyy-mm-ddThh:mm:ssZ
  # - yyyy/mm/dd hh:mm:ss {+/-}hhmm
  def date(arg)
    Time.parse(arg).to_i
  end

  # Get current Github events
  def get_events
    api_request "https://api.github.com/events"
  end

  # Read a value whose format is "foo.bar.baz" from a hierarchical map
  # (the result of a JSON parse or a Mongo query), where a dot represents
  # one level deep in the result hierarchy.
  def read_value(from, key)
    return from if key.nil? or key == ""

    key.split(/\./).reduce({}) do |acc, x|
      unless acc.nil?
        if acc.empty?
          # Initial run
          acc = from[x]
        else
          if acc.has_key?(x)
            acc = acc[x]
          else
            # Some intermediate key does not exist
            return ""
          end
        end
      else
        # Some intermediate key returned a null value
        # This indicates a malformed entry
        return ""
      end
    end
  end

  private

  def api_request(url)
    JSON.parse(api_request_raw(url))
  end

  def api_request_raw(url)
    #Rate limiting to avoid error requests
    if Time.now().tv_sec() - @ts < 60 then
      if @num_api_calls >= @settings['mirror']['reqrate'].to_i
        @log.debug "Sleeping for #{Time.now().tv_sec() - @ts}"
        sleep (Time.now().tv_sec() - @ts)
        @num_api_calls = 0
        @ts = Time.now().tv_sec()
      end
    else
      @log.debug "Tick, num_calls = #{@num_api_calls}, zeroing"
      @num_api_calls = 0
      @ts = Time.now().tv_sec()
    end

    @num_api_calls += 1
    @log.debug("Request: #{url} (num_calls = #{num_api_calls})")
    begin
      open(url).read
    rescue OpenURI::HTTPError => e
      case e.io.status[0].to_i
        # The following indicate valid Github return codes
        when 400, # Bad request
             401, # Unauthorized
             403, # Forbidden
             404, # Not found
             422: # Unprocessable entity
          error = {"error" => e.io.status[1]}
          return error.to_json
        else # Server error or HTTP conditions that Github does not report
          raise e
      end
    end
  end
end

# vim: set sta sts=2 shiftwidth=2 sw=2 et ai :
