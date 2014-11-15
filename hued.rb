#!/usr/bin/env ruby

require "chronic"
require "eventmachine"
require "huey"
require "logger"
require "pp"

# The main engine class
class Hued

  Scenes = {}

  # A rule class
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

      if entry["events"]
        entry["events"].each do |ev_name|
          event = Huey::Event.find(ev_name)
          if event.nil?
            @log.warn "Could not find event #{ev_name} for rule \"#{name}\", ignoring!"
          else
            @events << event
          end
        end
      elsif entry["scene"]
        @scene = entry["scene"] if Scenes.has_key? entry["scene"]
        if @scene.nil?
          @log.warn "Could not find scene #{entry["scene"]} for rule \"#{name}\", ignoring!"
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

    # If this is a trigger rule, it should only be triggerd if it wasn't
    # valid in a previous validity check
    def trigger?
      if @trigger
        !@triggered
      else
        @validity
      end
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

    private

      def test_conditions
        # If there are no conditions, the rule is always valid
        return true if @conditions.empty?

        @conditions.map do |cond|
          if cond.is_a? Hash
            cond_name, cond_value = cond.to_a.first
            case cond_name
            when "from"
              Time.now >= Chronic.parse(cond_value)
            when "until"
              Time.now <= Chronic.parse(cond_value)
            when "found host"
              system("ping -W3 -c1 -q #{cond_value} > /dev/null")
            end
          else
            @log.warn "Unknown condition type/form #{cond.inspect}"
          end
        end.all?
      end

  end # class Hued::Rule

  def initialize(options = {})
    @options = options
    @log = Logger.new($stdout)
    @log.progname = "hued"
    @log.level = options[:debug] ? Logger::DEBUG : Logger::INFO
    @log.formatter = proc do |severity, datetime, progname, msg|
      "#{datetime.strftime('%b %d %X')} #{progname}[#{$$}]: #{msg}\n"
    end

    configure
    discover
    load
    @log.info "Started successfully!"
  end

  def configure
    @log.info "Starting..."
    bridge_cfg = File.open("bridge.yml") { |file| YAML.load(file) }
    Huey.configure do |cfg|
      cfg.hue_ip = bridge_cfg["ip"]
      cfg.uuid = bridge_cfg["user"]
      if @options[:debug_hue]
        cfg.logger = @log
      else
        # Use the default logger and make it shut up
        cfg.logger.level = Logger::FATAL
      end
    end
    @log.info "Configured bridge connection"
  end

  def discover
    @log.info "Discovering lights..."
    @lights = Huey::Bulb.all
    @lights.each do |light|
      @log.info "* Found light #{light.id}: #{light.name}"
      light.alert! unless @options[:blink]
    end
    @log.info "Found #{@lights.count} light#{"s" unless @lights.count == 1}"

    @log.info "Discovering groups..."
    @groups = Huey::Group.all
    @groups.each do |group|
      @log.info "* Found group #{group.id}: #{group.name} with " \
                "lights #{group.bulbs.map(&:id).join(", ")}"
    end
    @log.info "Found #{@groups.count} group#{@groups.count != 1 || "s"}"
  end

  def refresh!
    @log.debug "Refreshing lights..."
    @lights.each { |light| light.reload }
    @log.debug "Refreshed #{@lights.count} light#{"s" unless @lights.count == 1}"
  end

  def load
    @log.info "Loading events..."
    @events = Huey::Event.import("events.yml")
    @events.each do |event|
      event.actions["on"] = true if event.actions["on"].nil?
      @log.info "* Loaded event: #{event.name}"
    end
    @log.info "Loaded #{@events.count} event#{"s" unless @events.count == 1}"

    @log.info "Loading scenes..."
    @scenes = {}
    YAML.load_file("scenes.yml").each do |name, entry|
      @scenes[name] = entry.map do |ev_options|
        # Keys should be symbols
        options = ev_options.inject({}) { |opts, (k, v)| opts[k.to_sym] = v; opts }
        event = Huey::Event.new(options)
        event.actions["on"] = true if event.actions["on"].nil?
        event
      end
      Scenes[name] = @scenes[name]
      @log.info "* Loaded scene: #{name}"
    end
    @log.info "Loaded #{@scenes.count} scene#{"s" unless @scenes.count == 1}"

    @log.info "Loading rules"
    @rules = YAML.load_file("rules.yml").map do |name, entry|
               Rule.new(name, @log, entry)
             end
    @rules.each do |rule|
      @log.info "* Loaded rule: #{rule.name}"
    end
    @log.info "Loaded #{@rules.count} rule#{"s" unless @rules.count == 1}"
  end

  def execute
    @log.debug "Looking for valid rules..."
    valid_rules = @rules.select(&:valid?)
    if valid_rules.empty?
      @log.debug "None found"
      return
    else
      @log.debug "There #{valid_rules.count == "1" ? "is" : "are"} " \
                 "#{valid_rules.count} valid " \
                 "rule#{"s" unless valid_rules.count == 1}"
    end

    prio_map = valid_rules.group_by(&:priority)
    prios = prio_map.keys.sort
    prios.each do |prio|
      prio_rules = prio_map[prio]
      @log.debug "* Rule#{"s" unless prio_rules.count == 1} with prioity #{prio}: " +
                  prio_rules.map(&:name).join(", ")
    end
    valid_rules_with_highest_prio = prio_map[prios.last]
    if valid_rules != valid_rules_with_highest_prio
      @log.debug "There #{valid_rules_with_highest_prio.count == 1 ? "is" : "are"} " \
                 "only #{valid_rules_with_highest_prio.count} valid " \
                 "rule#{"s" unless valid_rules_with_highest_prio.count == 1} " \
                 "for the hightest priority #{prios.last}"
    end
    valid_rules_with_highest_prio.each do |rule|
      if rule.trigger?
        @log.info "Rule \"#{rule.name}\" is valid and should be triggered, executing..."
        rule.execute
      else
        @log.debug "Rule \"#{rule.name}\" is valid, but should not be triggered"
      end
    end
  end

end # class Hued

# Option parsing
options = {}
options[:debug] = ARGV.delete("--debug")
options[:debug_hue] = ARGV.delete("--debug-hue")
options[:no_blink] = ARGV.delete("--no-blink")

# Create the main engine and trigger it periodically
hued = Hued.new(options)
EM.run do
  EM.add_periodic_timer(10) { hued.execute }
  EM.add_periodic_timer(300) { hued.refresh! }
end
