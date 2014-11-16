# encoding: utf-8

require "chronic"
require "eventmachine"
require "huey"
require "logger"
require "optparse"
require "pp"

require "hued/version"

require "hued/engine"
require "hued/rule"

module Hued
  extend self

  # Daemon configuration
  attr_reader :config
  
  # Daemon log
  attr_reader :log

  # Loaded scenes
  # FIXME: load scenes as Hued::Scene classes
  Scenes = {}

  def configure(options)
    @config = options

    # Set up the logger
    @log = Logger.new($stdout)
    @log.progname = "hued"
    @log.level = options[:debug] ? Logger::DEBUG : Logger::INFO
    @log.formatter = proc do |severity, datetime, progname, msg|
      "#{datetime.strftime('%b %d %X')} #{progname}[#{$$}]: #{msg}\n"
    end
  end
  
end
