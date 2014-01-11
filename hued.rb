#!/usr/bin/env ruby

require "huey"
require "logger"

log = Logger.new($stdout)
log.progname = "hued"
log.level = Logger::INFO
#log.level = Logger::DEBUG

log.info "Starting..."
bridge_cfg = File.open("bridge.yml") { |file| YAML.load(file) }
Huey.configure do |cfg|
  cfg.hue_ip = bridge_cfg["ip"]
  cfg.uuid = bridge_cfg["user"]
  cfg.logger = log
end
log.info "Configured bridge connection"

log.info "Discovering bulbs..."
bulbs = Huey::Bulb.all
bulbs.each do |bulb|
  log.info "Found bulb #{bulb.id}: #{bulb.name}"
  #bulb.alert!
end
log.info "Found #{bulbs.count} bulbs"

log.info "Importing groups..."
groups = Huey::Group.import("groups.yml")
groups.each do |group|
  log.info "Imported group #{group.name}: #{group.bulbs.map(&:id).join(", ")}"
end
log.info "Imported #{groups.count} groups"

log.info "Importing events..."
events = Huey::Event.import("events.yml")
events.each do |event|
  log.info "Imported event #{event.name}"
end
log.info "Imported #{events.count} events"

log.info "Executing event #{events[0].name}!"
events[0].execute
sleep 2
log.info "Executing event #{events[1].name}!"
events[1].execute
sleep 2
