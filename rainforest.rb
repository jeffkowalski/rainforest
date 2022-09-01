#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

class Date
  def weekend_or_holiday?
    itself.saturday? ||
      itself.sunday? ||
      !Holidays.on(itself, :federalreserve).empty?
  end
end

class RequiredFieldError < StandardError; end

class Rainforest < RecorderBotBase
  desc 'list-devices', 'list all devices known to gateway'
  def list_devices
    credentials = load_credentials

    response = RestClient.post "http://#{credentials[:username]}:#{credentials[:password]}@#{credentials[:ip_address]}/cgi-bin/post_manager",
                               '<Command><Name>device_list</Name></Command>'
    puts response.body
  end

  desc 'list-variables', 'list all variables on device'
  def list_variables
    credentials = load_credentials

    response = RestClient.post "http://#{credentials[:username]}:#{credentials[:password]}@#{credentials[:ip_address]}/cgi-bin/post_manager",
                               '<Command>' \
                               "  <Name>device_query</Name><DeviceDetails><HardwareAddress>#{credentials[:mac_id]}</HardwareAddress></DeviceDetails>" \
                               '  <Components><All>Y</All></Components>' \
                               '</Command>'
    puts response.body
  end

  no_commands do
    def main
      credentials = load_credentials

      soft_faults = [Errno::ECONNRESET, Errno::EHOSTUNREACH, RestClient::RequestTimeout, RestClient::ServiceUnavailable, SocketError]
      response = with_rescue(soft_faults, @logger) do |_try|
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
      data = [{ series: 'demand',
                values: { value: demand },
                timestamp: demand_timestamp }]
      @logger.debug data

      # calculate and record current and next time-of-use phases
      hour = Time.now.hour

      # today is not a weekend or holiday
      if hour < 15 # before 3pm
        # [:off_peak, "3pm", :partial_peak]
        start = '12am'
        phase = 'off_peak'
        finish = '3pm'
        next_phase = 'partial_peak'
      elsif hour < 16 # from 3pm to 4pm
        # [:partial_peak, "4pm", :peak]
        start = '3pm'
        phase = 'partial_peak'
        finish = '4pm'
        next_phase = 'peak'
      elsif hour < 21 # from 4pm to 9pm
        # [:peak, "9pm", :partial_peak]
        start = '4pm'
        phase = 'peak'
        finish = '9pm'
        next_phase = 'partial_peak'
      else # hour <= 23 # from 9pm to 12am
        # [:partial_peak, "12am", :off_peak]
        start = '9pm'
        phase = 'partial_peak'
        finish = '12am'
        next_phase = 'off_peak'
      end

      @logger.info "start: #{start}, #{phase}, finish: #{finish}, #{next_phase}"

      change_over = Chronic.parse(finish).utc.to_i
      data.push({ series: phase,
                  values: { value: false },
                  timestamp: change_over })
      data.push({ series: next_phase,
                  values: { value: true },
                  timestamp: change_over })

      influxdb.write_points(data) unless options[:dry_run]
    rescue *soft_faults
      raise unless Time.now.utc.hour == 10 && (5..15).cover?(Time.now.utc.min)

      @logger.info 'inaccessible due to update check 10:05-10:15 GMT'
    end
  end
end

Rainforest.start
