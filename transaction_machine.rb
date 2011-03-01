#!/usr/bin/env ruby -rubygems

require 'rubygems'
require 'eventmachine'


# This is an EventMachine module that performs the job of an async job queue.
# The server takes a string of ruby and returns a ticket ID, and disconnects. Clients can then
# reconnect to determine the state of their job.
#
# You can use this server as a replacement for BackgrounDrB to spin off long jobs in Rails without tying up your
# web processes.
#
# Typical usage looks like the following:
# EventMachine::run do
#   TransactionMachine::server( :host => 'localhost', :port => 12345 )
# end
#
#
# Transaction machine protocol looks like this:
# C: CHECK ticketid\n\n
# S: DONE chars-count\n\nMARSHALED-DATA  or
# S: WORKING\n\n
# S: NOTFOUND\n\n
#
# C: QUEUE chars-count\n\nMARSHALED-DATA
# S: ticketid\n\n
# S: ERROR reason\n\n
module TransactionMachine

  def self.server(args={})
    args = {
      :host => 'localhost',
      :port => 5555,
    }.merge(args)

    EventMachine::start_server(args[:host], args[:port], Server)

  end

  class JobQueue
    class << self
      attr_reader :jobs, :jobnumber


      def jobs
        @jobs ||= {}
      end

      def next_key
        @jobnumber ||= 1
        @jobnumber += 1
      end

    end
  end

  module Server
    include EventMachine::Deferrable

    def post_init
      @buffer = ""
      @jobtype = nil
      @jobattr = nil
    end

    def receive_data(data)
      puts "GOT DATA: #{data}"
      return if @done
      @buffer << data

      # TODO: if they put in "BLAH " then this will stall forever. be more strict.
      unless @jobtype
        m = @buffer.match(/\A(CHECK|QUEUE) /) || return
        @jobtype = m[1]
        @buffer = @buffer[@jobtype.length + 1, @buffer.length]
      end

      # TODO: again, if they put "HIBOB" as the attr, then this will wait for input forever
      unless @jobattr
        m = @buffer.match(/\A(\d+)\n\n/) || return

        @buffer = @buffer[m[1].length + 2, @buffer.length]
        @jobattr = m[1].to_i
      end

      cmd = ""

      case @jobtype
      when "CHECK"
        if JobQueue.jobs.key?(@jobattr)
          job = JobQueue.jobs[@jobattr]
          if job
            serialized_data = Marshal.dump(job)
            puts "DONE"
            cmd = "DONE #{serialized_data.size}\n\n#{serialized_data}"
            JobQueue.jobs.delete(@jobattr)
          else
            puts "WORKING"
            cmd = "WORKING\n\n"
          end
        else
          puts "NOTFOUND"
          cmd = "NOTFOUND\n\n"
        end
        send_data(cmd)
        close_connection_after_writing
        @done = true
      when "QUEUE"
        return if @buffer.size < @jobattr

        buffer = @buffer[0, @jobattr]
        hsh = Marshal.load( buffer ) rescue nil
        if hsh.nil?
          send_data("ERROR marshalled data did not decode properly\n\n")
          close_connection_after_writing
          @done = true
          return
        end

        @key = JobQueue.next_key
        JobQueue.jobs[@key] = nil
        send_data("#{@key}\n\n")
        close_connection_after_writing

        if hsh.key?(:defer) && hsh[:defer].key?(:method)
          meth = lambda {
            eval hsh[:defer][:method] rescue JobQueue.jobs[@key] = $!
          }
          cb = hsh[:defer].key?(:callback) ? lambda { eval hsh[:defer][:callback] rescue JobQueue.jobs[@key] = $! } : nil
          EventMachine.defer(meth, cb)
        end

        if hsh.key?(:inline)
          begin
            JobQueue.jobs[@key] = eval(hsh[:inline])
          rescue
            JobQueue.jobs[@key] = $!
          end
        end
      end
    end
  end
end

if __FILE__ == $0
  EventMachine::run do
    TransactionMachine.server
  end
end
