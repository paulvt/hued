# encoding: utf-8

module Hued

  # The main engine class
  class Engine

    def initialize(options = {})
      @config = Hued.config
      @log = Hued.log
      @ctime = Hash.new(Time.now)

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
        if @config[:hue_debug]
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
        light.alert! if @config[:blink]
      end
      @log.info "Found #{@lights.count} light#{"s" unless @lights.count == 1}"

      @log.info "Discovering groups..."
      @groups = Huey::Group.all
      @groups.each do |group|
        @log.info "* Found group #{group.id}: #{group.name} with " \
                  "lights #{group.bulbs.map(&:id).join(", ")}"
      end
      @log.info "Found #{@groups.count} group#{@groups.count != 1 || "s"}"
    rescue => e
      @log.error "Could not discover lights/groups: #{e.message}"
      @lights = []
      @groups = []
    end

    def refresh!
      @log.debug "Refreshing lights..."
      @lights.each { |light| light.reload }
      @log.debug "Refreshed #{@lights.count} light#{"s" unless @lights.count == 1}"
    end

    def load
      [:events, :scenes].each do |items|
        if File.exist? "#{items}.yml"
          @log.info "Loading #{items}..."
          send("load_#{items}")
        end
      end

      # Treat rules separately, we cannot start without it
      if File.exist? "rules.yml"
        @log.info "Loading rules"
        load_rules
      else
        @log.error "Cannot find required file: rules.yml, aborting!"
        exit 1
      end
    end

    def reload
      @log.debug "Checking if events/scenes/rules need to be reloaded..."
      @reload_rules = false
      [:events, :scenes].each do |items|
        if File.exist?("#{items}.yml") and
           File.ctime("#{items}.yml") > @ctime[items]
          @log.info "Reloading events..."
          send("load_#{items}")
          # Rules may depend on events/scenes, reload the rules too!
          @reload_rules = true
        end
      end

      if File.exist?("rules.yml") and
         (@reload_rules or File.ctime("rules.yml") > @ctime[:rules])
        @log.info "Reloading rules..."
        send("load_rules")
      end
    end

    def execute
      @log.debug "Looking for active (and valid) rules..."
      valid_rules = @rules.select(&:valid?)
      if valid_rules.empty?
        @log.debug "No valid rules found"
        return
      else
        @log.debug "There #{valid_rules.count == 1 ? "is" : "are"} " \
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
      active_rules = prio_map[prios.last]
      if valid_rules != active_rules
        @log.debug "There #{active_rules.count == 1 ? "is" : "are"} " \
                   "only #{active_rules.count} active " \
                   "rule#{"s" unless active_rules.count == 1}"
                   "(i.e. with priority #{prios.last})"
      end
      active_rules.each do |rule|
        if rule.trigger?
          if rule.triggered?
            @log.info "Rule \"#{rule.name}\" is active, but has already been triggered"
          else
            @log.info "Rule \"#{rule.name}\" is active and should be triggered"
            rule.execute
          end
        else
          @log.info "Rule \"#{rule.name}\" is active and should be triggered (again)"
          rule.execute
        end
      end
    end

    def shutdown
      @log.info "Shutting down..."
    end

    #######
    private

      def load_events
        @ctime[:events] = File.ctime("events.yml")
        @events = Huey::Event.import("events.yml")
        @events.each do |event|
          event.actions["on"] = true if event.actions["on"].nil?
          @log.info "* Loaded event: #{event.name}"
        end
        @log.info "Loaded #{@events.count} event#{"s" unless @events.count == 1}"
      rescue => e
        @log.error "Could not load events: #{e.message}"
        @events= []
      end

      def load_scenes
        @ctime[:scenes] = File.ctime "scenes.yml"
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
      rescue => e
        @log.error "Could not load scenes: #{e.message}"
        @scenes = {}
      end

      def load_rules
        @ctime[:rules] = File.ctime "rules.yml"
        @rules = YAML.load_file("rules.yml").map do |name, entry|
                   Rule.new(name, @log, entry)
                 end
        @rules.each do |rule|
          @log.info "* Loaded rule: #{rule.name}"
        end
        @log.info "Loaded #{@rules.count} rule#{"s" unless @rules.count == 1}"
      rescue => e
        @log.error "Could not load rules: #{e.message}"
        @scenes = {}
      end

  end # class Hued::Engine

end # module Hued
