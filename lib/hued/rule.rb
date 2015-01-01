# encoding: utf-8

require "nokogiri"
require "net/http"

module Hued

  # The rule class
  class Rule

    attr_reader :name, :conditions, :tigger, :priority, :events, :scene

    def initialize(name, log, entry)
      @name = name
      @log = log
      @validity = false
      @conditions = entry["conditions"] || []
      @trigger = entry["trigger"].nil? ? true : entry["trigger"]
      @triggered = false
      @priority = entry["priority"] || 0
      @events = []

      @sun_data = nil

      if entry["events"]
        entry["events"].each do |ev_name|
          event = Huey::Event.find(ev_name)
          if event.nil?
            @log.warn "Could not find event \"#{ev_name}\" for rule \"#{name}\", ignoring!"
          else
            @events << event
          end
        end
      elsif entry["scene"]
        @scene = entry["scene"] if Scenes.has_key? entry["scene"]
        if @scene.nil?
          @log.warn "Could not find scene \"#{entry["scene"]}\" for rule \"#{name}\", ignoring!"
        end
      else
        raise ArgumentError, "You must supply either an even or scene name"
      end
    end

    def valid?
      # Determine validity
      prev_validity = @validity
      @validity = test_conditions

      # Reset the triggered flag if the this is a trigger rule, but it is
      # no longer valid
      @triggered = false if @trigger and prev_validity and !@validity

      @validity
    end

    def triggered?
      @triggered
    end

    def trigger?
      @trigger
    end

    def execute
      @triggered = true
      events = if @scene
                 @log.info "Executing scene: #{@scene}"
                 events = Scenes[@scene]
               elsif @events
                 @events
               else
                 @log.info "No scene or events found, skipping execution"
                 []
               end

      events.each_with_index do |event, idx|
        if event.name
          @log.info "Executing event: #{event.name}!"
        else
          @log.info "Executing event #{idx}"
        end
        retry_count = 0
        begin
          event.execute
        rescue Huey::Errors::BulbOff
          if retry_count > 4
            @log.warn "One of the lights is still off, ignoring event"
          else
            @log.warn "One of the lights was off, retrying..."
            event.group.bulbs.each { |bulb| bulb.on = false }
            retry_count += 1
            retry
          end
        rescue Huey::Errors::Error => e
          @log.error "Error while executing event (#{e.class}): #{e.message}"
        end
      end
    end

    #######
    private

      def test_conditions
        # If there are no conditions, the rule is always valid
        return true if @conditions.empty?

        @conditions.map do |cond|
          cond_negate = false
          res = if cond.is_a? Hash
                  cond_name, cond_value = cond.to_a.first
                  if cond_name[0] == "^"
                    cond_negate = true
                    cond_name = cond_name[1..-1]
                  end
                  case cond_name
                  when "from"
                    Time.now >= Chronic.parse(cond_value)
                  when "until"
                    Time.now <= Chronic.parse(cond_value)
                  when "found host"
                    system("ping -W3 -c1 -q #{cond_value} > /dev/null 2>&1")
                  when "weekday", "weekdays"
                    weekdays = cond_value.split(/,\s*/).map(&:downcase)
                    weekdays.include? Time.now.strftime("%a").downcase
                  when "dark_at"
                    now = Time.now
                    # Retrieve new sunrise/sunset data if cache is too old
                    if @sun_data.nil? or
                       @sun_data.at("/sun/date/day").text.to_i != now.day
                      lat, lon = cond_value
                      url = "http://www.earthtools.org/sun/%s/%s/%s/%s/99/0" %
                            [lat, lon, now.day, now.month]
                      @log.debug "Retreiving sunrise/sunset data from #{url}..."
                      data = Net::HTTP.get(URI(url))
                      @sun_data = Nokogiri::XML(data)
                    end
                    sunrise = Chronic.parse("today " +
                                            @sun_data.at("/sun/morning/sunrise").text)
                    sunset = Chronic.parse("today " +
                                           @sun_data.at("/sun/evening/sunset").text)

                    now < sunrise or now > sunset
                  end
                else
                  @log.warn "Unknown condition type/form #{cond.inspect}"
                end
          cond_negate ? !res : res
        end.all?
      end

  end # class Hued::Rule

end # module Hued
