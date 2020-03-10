#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'thor'
require 'fileutils'
require 'logger'
require 'rest-client'
require 'json'
require 'influxdb'
require 'holidays'
require 'chronic'
require 'nokogiri'

LOGFILE = File.join(Dir.home, '.log', 'rainforest.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'rainforest.yaml')

module Kernel
  def with_rescue(exceptions, logger, retries: 5)
    try = 0
    begin
      yield try
    rescue *exceptions => e
      try += 1
      raise if try > retries

      logger.info "caught error #{e.class}, retrying (#{try}/#{retries})..."
      retry
    end
  end
end

class Date
  def weekend_or_holiday?
    itself.saturday? ||
      itself.sunday? ||
      !Holidays.on(itself, :federalreserve).empty?
  end
end

class RequiredFieldError < StandardError; end

class Rainforest < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new STDOUT
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  desc 'list-devices', 'list all devices known to gateway'
  def list_devices
    credentials = YAML.load_file CREDENTIALS_PATH

    response = RestClient.post "http://#{credentials[:username]}:#{credentials[:password]}@#{credentials[:ip_address]}/cgi-bin/post_manager",
                               '<Command><Name>device_list</Name></Command>'
    p response.body
  end

  desc 'list-variables', 'list all variables on device'
  def list_variables
    credentials = YAML.load_file CREDENTIALS_PATH

    response = RestClient.post "http://#{credentials[:username]}:#{credentials[:password]}@#{credentials[:ip_address]}/cgi-bin/post_manager",
                               '<Command>' \
                               "  <Name>device_query</Name><DeviceDetails><HardwareAddress>#{credentials[:mac_id]}</HardwareAddress></DeviceDetails>" \
                               '  <Components><All>Y</All></Components>' \
                               '</Command>'
    pp response.body
  end

  desc 'record-status', 'record the current usage data to database'
  method_option :dry_run, type: :boolean, aliases: '-d', desc: 'do not write to database'
  def record_status
    setup_logger

    begin
      credentials = YAML.load_file CREDENTIALS_PATH

      response = with_rescue([Errno::EHOSTUNREACH, RestClient::ServiceUnavailable, SocketError], @logger) do |_try|
        RestClient.post "http://#{credentials[:username]}:#{credentials[:password]}@#{credentials[:ip_address]}/cgi-bin/post_manager",
                        '<Command>' \
                        "  <Name>device_query</Name><DeviceDetails><HardwareAddress>#{credentials[:mac_id]}</HardwareAddress></DeviceDetails>" \
                        '  <Components><All>Y</All></Components>' \
                        '</Command>'
      end
      @logger.debug response
      doc = Nokogiri.XML response
      demand_timestamp = (doc.at '//Device/DeviceDetails/LastContact')&.content&.hex
      demand = (doc.at '//Device/Components/Component/Variables/Variable//Name[contains(text(), "zigbee:InstantaneousDemand")]/following-sibling::Value')&.content&.to_f
      raise RequiredFieldError if demand.nil? || demand_timestamp.nil?

      influxdb = InfluxDB::Client.new 'rainforest'

      # record recent demand
      data = {
        values: { value: demand },
        timestamp: demand_timestamp
      }
      @logger.debug data
      influxdb.write_point('demand', data) unless options[:dry_run]

      # calculate and record current and next time-of-use phases
      today = Date.today
      yesterday = today - 1
      tomorrow = today + 1
      hour = Time.now.hour

      if today.weekend_or_holiday?
        # weekend
        if hour < 15 # before 3pm
          # [:off_peak, "3pm", :peak]
          start = if yesterday.weekend_or_holiday?
                    'yesterday 7pm'
                  else
                    'yesterday 11pm'
                  end
          phase = 'off_peak'
          finish = '3pm'
          next_phase = 'peak'
        elsif hour < 19 # from 3pm to 7pm
          # [:peak, "7pm", :off_peak]
          start = '3pm'
          phase = 'peak'
          finish = '7pm'
          next_phase = 'off_peak'
        else # 7pm afterward
          start = '7pm'
          phase = 'off_peak'
          if tomorrow.weekend_or_holiday?
            # [:off_peak, "tomorrow 3pm", :peak]
            finish = 'tomorrow 3pm'
            next_phase = 'peak'
          else
            # [:off_peak, "tomorrow 7am", :partial_peak]
            finish = 'tomorrow 7am'
            next_phase = 'partial_peak'
          end
        end
      else
        # today is not a weekend or holiday
        if hour < 7 # before 7am
          # [:off_peak, "7am", :partial_peak]
          start = if yesterday.weekend_or_holiday?
                    'yesterday 7pm'
                  else
                    'yesterday 11pm'
                  end
          phase = 'off_peak'
          finish = '7am'
          next_phase = 'partial_peak'
        elsif hour < 14 # from 7am to 2pm
          # [:partial_peak, "2pm", :peak]
          start = '7am'
          phase = 'partial_peak'
          finish = '2pm'
          next_phase = 'peak'
        elsif hour < 21 # from 2pm to 9pm
          # [:peak, "9pm", :partial_peak]
          start = '2pm'
          phase = 'peak'
          finish = '9pm'
          next_phase = 'partial_peak'
        elsif hour < 23 # from 9pm to 11pm
          # [:partial_peak, "11pm", :off_peak]
          start = '9pm'
          phase = 'partial_peak'
          finish = '11pm'
          next_phase = 'off_peak'
        else # 11pm afterward
          start = '11pm'
          phase = 'off_peak'
          if tomorrow.weekend_or_holiday?
            # [:off_peak, "tomorrow 3pm", :peak]
            finish = 'tomorrow 3pm'
            next_phase = 'peak'
          else
            # [:off_peak, "tomorrow 7am", :partial_peak]
            finish = 'tomorrow 7am'
            next_phase = 'partial_peak'
          end
        end
      end

      @logger.info "start: #{start}, #{phase}, finish: #{finish}, #{next_phase}"

      # data = {
      #   values: { value: true },
      #   timestamp: Chronic.parse(start).utc.to_i
      # }
      # influxdb.write_point(phase, data)

      data = {
        values: { value: false },
        timestamp: Chronic.parse(finish).utc.to_i
      }
      influxdb.write_point(phase, data) unless options[:dry_run]

      data = {
        values: { value: true },
        timestamp: Chronic.parse(finish).utc.to_i
      }
      influxdb.write_point(next_phase, data) unless options[:dry_run]
    rescue Errno::EHOSTUNREACH, RestClient::ServiceUnavailable, SocketError => e
      if Time.now.utc.hour == 10 && (6..10).cover?(Time.now.utc.min)
        @logger.info 'inaccessible due to update check 10:06-10:10 GMT'
      else
        @logger.error e
      end
    rescue StandardError => e
      @logger.error e
    end
  end
end

Rainforest.start
