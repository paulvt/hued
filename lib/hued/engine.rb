# encoding: utf-8

module Hued

  # The main engine class
  class Engine

    def initialize(options = {})
      @config = Hued.config
      @log = Hued.log
      @ctime = {}
      @file = {}
      [:bridge, :events, :scenes, :rules].each do |items|
        @ctime[items] = Time.now
        @file[items] = File.join(@config[:config_dir], "#{items}.yml")
      end

      configure
      discover
      load
      @log.info "Started successfully!"
    end

    def configure
      @log.info "Starting hued v#{Hued::VERSION}..."
      bridge_cfg = begin
                     YAML.load_file(@file[:bridge])
                   rescue => e
                     @log.info "Cannot find bridge configuration: #{@file[:bridge]}!"
                     @log.info "Will trying automatic setup when discovering"
                     nil
                   end
      Huey.configure do |cfg|
        cfg.hue_ip = bridge_cfg["ip"] if bridge_cfg
        cfg.uuid = bridge_cfg["user"] if bridge_cfg
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
      @log.info "Found #{@groups.count} group#{"s" unless @groups.count == 1}"
      # FIXME: mention bridge.cfg contents if it was done via auto setup
    rescue => e
      @log.error "Could not discover lights/groups: #{e.message}"
      @lights = []
      @groups = []
    end

    def refresh!
      @log.debug "Refreshing lights..."
      @lights.each { |light| light.reload }
      @log.debug "Refreshed #{@lights.count} light#{"s" unless @lights.count == 1}"
    rescue => e
      @log.error "Could not refresh lights: #{e.message}"
    end

    def load
      [:events, :scenes].each do |items|
        if File.exist? @file[items]
          @log.info "Loading #{items}..."
          send("load_#{items}")
        end
      end

      # Treat rules separately, we cannot start without it
      if File.exist? @file[:rules]
        @log.info "Loading rules"
        load_rules
      else
        @log.error "Cannot find required file: #{@file[:rules]}, aborting!"
        exit 1
      end
    end

    def reload
      @log.debug "Checking if events/scenes/rules need to be reloaded..."
      @reload_rules = false
      [:events, :scenes].each do |items|
        if File.exist?(@file[items]) and
           File.ctime(@file[items]) > @ctime[items]
          @log.info "Reloading events..."
          send("load_#{items}")
          # Rules may depend on events/scenes, reload the rules too!
          @reload_rules = true
        end
      end

      if File.exist?(@file[:rules]) and
         (@reload_rules or File.ctime(@file[:rules]) > @ctime[:rules])
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
        begin
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
        rescue => e
          @log.error "Could not execute rule: #{e.message}"
        end
      end
    end

    def shutdown
      @log.info "Shutting down..."
    end

    #######
    private

      def load_events
        @ctime[:events] = File.ctime(@file[:events])
        @events = Huey::Event.import(@file[:events])
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
        @ctime[:scenes] = File.ctime(@file[:scenes])
        @scenes = {}
        YAML.load_file(@file[:scenes]).each do |name, entry|
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
        @ctime[:rules] = File.ctime(@file[:rules])
        @rules =
          YAML.load_file(@file[:rules]).map do |name, entry|
            rule = Rule.new(name, @log, entry)
            @log.info "* Loaded rule: #{rule.name}"
            rule
          end
        @log.info "Loaded #{@rules.count} rule#{"s" unless @rules.count == 1}"
      rescue => e
        @log.error "Could not load rules: #{e.message}"
        @scenes = {}
      end

  end # class Hued::Engine

end # module Hued
