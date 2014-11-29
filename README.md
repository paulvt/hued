# Hued documentation

A daemon for controlling Philips (friends of) hue lights by applying rules
based on conditions.  Rules can in turn trigger or ensure execution of
certain events or scenes.

## Features

* Supports individual lights and groups known to the bridge
* Multiple rules with multiple conditions and multiple events or
  a scene
* Scenes for reusing a specific set of events

## Requirements

Hued is a pure Ruby application, so you need

* Ruby 1.9 (>= 1.9.3) or 2.x

The following Ruby libraries are required:

* Chronic (>= 0.10.0)
* EventMachine (>= 1.0.0)
* Huey (with Color) (>= 2.1.0)
* Rainbow (>= 0.8.0)

At the moment, hued requires a patched version of Huey that supports
a single light or set of lights for an event.

## Installation

For now, Hued is in a developing state and not ready for other uses
than tinkering.

## Usage

Create `bridge.yml` which contains the IP address and API key (i.e. user)
of the bridge.  For example:

    ip: 192.168.0.1
    user: 1234567890abcdef1234567890abcdef

Then, set up some rules and add the needed events and/or scenes.

### Rules

A rule is a central object that combines conditions, events and or scenes.
When a rule is valid given its conditions, the associated events or scene
can be executed (or triggered).
Create `rules.yml` to contain a list of named rules.
The full format with defaults is as follows:

    Default rule:
      conditions: []
      trigger: true
      priority: 0
      events: []
      scene:

So, a rule has a priority of 0, no conditions, no events and no scene by
default, but either a event or scene needs to be given.
If both are given, the scene takes precedence.
If trigger is enabled, the events or the scene will only be executed when
becoming valid and active.
(Being valid but not active can happen when a higher priority rule is valid.)

FIXME: say something about conditions

### Events

An event is a bundle of light state changes for a single light, a set of
lights or a group known to the bridge. 
Create `events.yml` if you want to use (named) events.
The full format with defaults is as follows:

    Default event:
      light:
      lights: 
      group:
      actions: {}

An event is required to have at least one action (i.e. a state variable
change) and a single light, set of lights or group.  If two or more are
specified then group takes precedence over set of lights which in turn
takes precedence over single light.
A single light can be specified by a light name or ID.
A set of lights can be specified by an array of IDs or a partial light name
which will be matched against all light names.
A group can be specified by a group name or ID.

### Scenes

A scene is a series of nameless events.  A scene is executed by
executing all its events and can be used to set up different lights
with different light states.
It is similar to what is used on remote controls or the hue tap.
Create `scenes.yml` if you want to use scenes.

    Default scene: []

A default scene contains no events.

### Example setup

An example setup:

`rules.yml`:

    Off when closed:
      trigger: false
      events:
        - All off

    Office lighting during working ours:
      conditions:
        from: today at 9:00
        until: today at 18:00
        weekdays: mon,tue,wed,thu,fri
      priority: 1
      scene: Nice office lighting

The rule "Off when closed" has no conditions, thus it is always valid.
Since it is not a trigger, when valid and active it will keep excuting
the event "All off" (see below) repeatedly.

Between 9:00 and 18:00 on weekdays, the rule "Office lighting during
working hours" is valid and it has a higher priority, so the rule "Off when
closed" will become inactive.  This is a trigger (by default), so at
activation it will execute the scene "Nice office lighting" (see below)
only once.

At 18:00 the "Office lighting during working hours" will become inactive
and the always-valid rule "All off" will become active and start
executing the event "All off" repeatedly again during the night.

`events.yml`:

    All off:
      lights: [1, 2, 3, 4]
      actions:
        "on": false

`scenes.yml`:

    Nice office lighting:
      - light: Hue light window
        actions: 
          hue: 12345
          sat: 200
          bri: 255
      - lights: LivingColor light
        actions:
          xy: [0.5, 0.6]
          bri: 211
      - group: Anti-burglary
        actions:
          "on": false

### Running hued

Currently, all the files mentiond above need to be in the current working
directory from where `hued` is started.

See `hued --help` for the available command-line options.

## License

Hued is free software; you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
