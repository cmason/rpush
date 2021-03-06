require 'thread'
require 'socket'
require 'pathname'
require 'openssl'
require 'net/http/persistent'

require 'rpush/daemon/errors'
require 'rpush/daemon/constants'
require 'rpush/daemon/reflectable'
require 'rpush/daemon/loggable'
require 'rpush/daemon/string_helpers'
require 'rpush/daemon/interruptible_sleep'
require 'rpush/daemon/delivery_error'
require 'rpush/daemon/retryable_error'
require 'rpush/daemon/delivery'
require 'rpush/daemon/feeder'
require 'rpush/daemon/batch'
require 'rpush/daemon/queue_payload'
require 'rpush/daemon/synchronizer'
require 'rpush/daemon/app_runner'
require 'rpush/daemon/tcp_connection'
require 'rpush/daemon/dispatcher_loop'
require 'rpush/daemon/dispatcher/http'
require 'rpush/daemon/dispatcher/tcp'
require 'rpush/daemon/dispatcher/apns_tcp'
require 'rpush/daemon/service_config_methods'
require 'rpush/daemon/retry_header_parser'
require 'rpush/daemon/ring_buffer'
require 'rpush/daemon/signal_handler'
require 'rpush/daemon/proc_title'

require 'rpush/daemon/store/interface'

require 'rpush/daemon/apns/delivery'
require 'rpush/daemon/apns/feedback_receiver'
require 'rpush/daemon/apns'

require 'rpush/daemon/gcm/delivery'
require 'rpush/daemon/gcm'

require 'rpush/daemon/wpns/delivery'
require 'rpush/daemon/wpns'

require 'rpush/daemon/adm/delivery'
require 'rpush/daemon/adm'

module Rpush
  module Daemon
    class << self
      attr_accessor :store
    end

    def self.start
      Process.daemon if daemonize?
      SignalHandler.start
      initialize_store
      write_pid_file
      Synchronizer.sync

      # No further store connections will be made from this thread.
      store.release_connection

      # Blocking call, returns after Feeder.stop is called from another thread.
      Feeder.start

      # Wait for shutdown to complete.
      shutdown_lock.synchronize { true }
    end

    def self.shutdown
      puts "\nShutting down..."

      shutdown_lock.synchronize do
        Feeder.stop
        AppRunner.stop
        delete_pid_file
      end
    end

    def self.shutdown_lock
      return @shutdown_lock if @shutdown_lock
      @shutdown_lock = Mutex.new
      @shutdown_lock
    end

    def self.initialize_store
      return if store
      begin
        name = Rpush.config.client.to_s
        require "rpush/daemon/store/#{name}"
        self.store = Rpush::Daemon::Store.const_get(name.camelcase).new
      rescue StandardError, LoadError => e
        Rpush.logger.error("Failed to load '#{Rpush.config.client}' storage backend.")
        Rpush.logger.error(e)
        exit 1
      end
    end

    protected

    def self.daemonize?
      !(Rpush.config.push || Rpush.config.foreground || Rpush.config.embedded || Rpush.jruby?)
    end

    def self.write_pid_file
      unless Rpush.config.pid_file.blank?
        begin
          File.open(Rpush.config.pid_file, 'w') { |f| f.puts Process.pid }
        rescue SystemCallError => e
          Rpush.logger.error("Failed to write PID to '#{Rpush.config.pid_file}': #{e.inspect}")
        end
      end
    end

    def self.delete_pid_file
      pid_file = Rpush.config.pid_file
      File.delete(pid_file) if !pid_file.blank? && File.exist?(pid_file)
    end
  end
end
