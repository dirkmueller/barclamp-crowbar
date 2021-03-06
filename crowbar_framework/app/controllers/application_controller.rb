#
# Copyright 2011-2013, Dell
# Copyright 2013-2014, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'uri'

# Filters added to this controller apply to all controllers in the application.
# Likewise, all the methods added will be available for all controllers.
class ApplicationController < ActionController::Base
  rescue_from Crowbar::Error::NotFound, :with => :render_not_found
  rescue_from Crowbar::Error::ChefOffline, :with => :chef_is_offline

  @@users = nil

  before_filter :digest_authenticate, :if => :need_to_auth?
  before_filter :enable_profiler, :if => Proc.new { ENV["ENABLE_PROFILER"] == "true" }


  # Basis for the reflection/help system.

  # First, a place to stash the help contents.
  # Using a class_inheritable_accessor ensures that
  # these contents are inherited by children, but can be
  # overridden or appended to by child classes without messing up
  # the contents we are building here.
  class_attribute :help_contents
  self.help_contents = []

  # Class method for adding method-specific help/API information
  # for each method we are going to expose to the CLI.
  # Since it is a class method, it will not be bothered by the Rails
  # trying to expose it to everything else, and we can call it to build
  # up our help contents at class creation time instead of instance creation
  # time, so there is minimal overhead.
  # Since we are just storing an arrray of singleton hashes, adding more
  # user-oriented stuff (descriptions, exmaples, etc.) should not be a problem.
  def self.add_help(method,args=[],http_method=[:get])
    # if we were passed multiple http_methods, build an entry for each.
    # This assumes that they all take the same parameters, if they do not
    # you should call add_help for each different set of parameters that the
    # method/http_method combo can take.
    http_method.each { |m|
      self.help_contents = self.help_contents.push({
        method => {
                                             "args" => args,
                                             "http_method" => m
        }
      })
    }
  end

  helper :all

  protect_from_forgery with: :exception

  # TODO: Disable it only for API calls
  skip_before_action :verify_authenticity_token

  def self.set_layout(template = "application")
    layout proc { |controller|
      if controller.is_ajax?
        nil
      else
        template
      end
    }
  end

  def is_ajax?
    request.xhr?
  end

  add_help(:help)
  def help
    render :json => { self.controller_name => self.help_contents.collect { |m|
        res = {}
        m.each { |k,v|
          # sigh, we cannot resolve url_for at class definition time.
          # I suppose we have to do it at runtime.
          url=URI::unescape(url_for({ :action => k,
                        :controller => self.controller_name,

          }.merge(v["args"].inject({}) {|acc,x|
            acc.merge({x.to_s => "(#{x.to_s})"})
          }
          )
          ))
          res.merge!({ k.to_s => v.merge({"url" => url})})
        }
        res
      }
    }
  end
  set_layout

  #########################
  # private stuff below.

  private

  @@auth_load_mutex = Mutex.new
  @@realm = ""

  def need_to_auth?()
    return false unless File::exists? "htdigest"
    ip = session[:ip_address] rescue nil
    return false if ip == request.remote_addr
    return true
  end

  def digest_authenticate
    load_users()
    authenticate_or_request_with_http_digest(@@realm) { |u| find_user(u) }
    ## only create the session if we're authenticated
    if authenticate_with_http_digest(@@realm) { |u| find_user(u) }
      session[:ip_address] = request.remote_addr
    end
  end

  def find_user(username)
    return false if !@@users || !username
    user = @@users[username]
    return false unless user
    return user[:password] || false
  end

  ##
  # load the ""user database"" but be careful about thread contention.
  # $htdigest gets flushed when proposals get saved (in case they user database gets modified)
  $htdigest_reload =true
  $htdigest_timestamp = Time.now()
  def load_users
    unless $htdigest_reload
      f = File.new("htdigest")
      if $htdigest_timestamp != f.mtime
        $htdigest_timestamp = f.mtime
        $htdigest_reload = true
      end
    end
    return if @@users and !$htdigest_reload

    ## only 1 thread should load stuff..(and reset the flag)
    @@auth_load_mutex.synchronize  do
      $htdigest_reload = false if $htdigest_reload
    end

    ret = {}
    data = IO.readlines("htdigest")
    data.each { |entry|
      next if entry.strip.length ==0
      list = entry.split(":") ## format: user : realm : hashed pass
      user = list[0].strip rescue nil
      password = list[2].strip rescue nil
      realm = list[1].strip rescue nil
      ret[user] ={:realm => realm, :password => password}
    }
    @@auth_load_mutex.synchronize  do
        @@users = ret.dup
        @@realm = @@users.values[0][:realm]
    end
    ret
  end

  def flash_and_log_exception(e)
    flash[:alert] = e.message
    log_exception(e)
  end

  def log_exception(e)
    lines = [ e.message ] + e.backtrace
    Rails.logger.warn lines.join("\n")
  end

  def render_not_found
    respond_to do |format|
      format.html { render "errors/not_found", :status => 404 }
      format.json { render :json => { :error => "Not found" }, :status => 404 }
    end
  end

  def chef_is_offline
    respond_to do |format|
      format.html { render "errors/chef_offline", :status => 500 }
      format.json { render :json => { :error => "Chef server is not available" }, :status => 500 }
    end
  end

  def enable_profiler
    Rack::MiniProfiler.authorize_request
  end
end
