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
      data = [{ series: 'demand',
                values: { value: demand },
                timestamp: demand_timestamp }]
      @logger.debug data

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

      change_over = Chronic.parse(finish).utc.to_i
      data.push({ series: phase,
                  values: { value: false },
                  timestamp: change_over })
      data.push({ series: next_phase,
                  values: { value: true },
                  timestamp: change_over })

      influxdb.write_points(data) unless options[:dry_run]
    rescue Errno::EHOSTUNREACH, RestClient::ServiceUnavailable, SocketError
      raise unless Time.now.utc.hour == 10 && (5..15).cover?(Time.now.utc.min)

      @logger.info 'inaccessible due to update check 10:05-10:15 GMT'
    end
  end
end

Rainforest.start
