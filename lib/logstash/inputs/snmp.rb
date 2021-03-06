# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "stud/interval"
require "socket" # for Socket.gethostname
require_relative "snmp/client"
require_relative "snmp/mib"

# Generate a repeating message.
#
# This plugin is intented only as an example.

class LogStash::Inputs::Snmp < LogStash::Inputs::Base
  config_name "snmp"

  # List of OIDs for which we want to retrieve the scalar value
  config :get,:validate => :array # ["1.3.6.1.2.1.1.1.0"]

  # List of OIDs for which we want to retrieve the subtree of information
  config :walk,:validate => :array # ["1.3.6.1.2.1.1.1.0"]

  # List of hosts to query the configured `get` and `walk` options.
  #
  # Each host definition is a hash and must define the `host` key and value.
  #  `host` must use the format {tcp|udp}:{ip address}/{port}
  #  for example `host => "udp:127.0.0.1/161"`
  # Each host definition can optionally include the following keys and values:
  #  `community` with a default value of `public`
  #  `version` `1` or `2c` with a default value of `2c`
  #  `retries` with a detault value of `2`
  #  `timeout` in milliseconds with a default value of `1000`
  config :hosts, :validate => :array  #[ {"host" => "udp:127.0.0.1/161", "community" => "public"} ]

  # List of paths of MIB .dic files of dirs. If a dir path is specified, all files with .dic extension will be loaded.
  #
  # ATTENTION: a MIB .dic file must be generated using the libsmi library `smidump` command line utility
  # like this for example. Here the `RFC1213-MIB.txt` file is an ASN.1 MIB file.
  #
  # `$ smidump -k -f python RFC1213-MIB.txt > RFC1213-MIB.dic`
  #
  # The OSS libsmi library https://www.ibr.cs.tu-bs.de/projects/libsmi/ is available & installable
  # on most OS.
  config :mib_paths, :validate => :array # ["path/to/mib.dic", "path/to/mib/dir"]

  # number of OID root digits to ignore in event field name. For example, in a numeric OID
  # like 1.3.6.1.2.1.1.1.0" the first 5 digits could be ignored by setting oid_root_skip => 5
  # which would result in a field name "1.1.1.0". Similarly when a MIB is used an OID such
  # as "1.3.6.1.2.mib-2.system.sysDescr.0" would become "mib-2.system.sysDescr.0"
  config :oid_root_skip, :validate => :number, :default => 0

  # Set polling interval in seconds
  #
  # The default, `30`, means poll each host every 30second.
  config :interval, :validate => :number, :default => 30

  # Add the default "host" field to the event.
  config :add_field, :validate => :hash, :default => { "host" => "%{[@metadata][host_address]}" }

  def register
    validate_oids!
    validate_hosts!

    mib = LogStash::SnmpMib.new
    Array(@mib_paths).each do |path|
      # TODO handle errors
      mib.add_mib_path(path)
    end

    @client_definitions = []
    @hosts.each do |host|
      host_name = host["host"]
      community = host["community"] || "public"
      version = host["version"] || "2c"
      raise(LogStash::ConfigurationError, "only protocol version '1' and '2c' are supported for host option '#{host_name}'") unless version =~ VERSION_REGEX

      retries = host["retries"] || 2
      timeout = host["timeout"] || 1000

      # TODO: move these validations in a custom validator so it happens before the register method is called.
      host_details = host_name.match(HOST_REGEX)
      raise(LogStash::ConfigurationError, "invalid format for host option '#{host_name}'") unless host_details
      raise(LogStash::ConfigurationError, "only udp & tcp protocols are supported for host option '#{host_name}'") unless host_details[:host_protocol].to_s =~ /^(?:udp|tcp)$/i

      protocol = host_details[:host_protocol]
      address = host_details[:host_address]
      port = host_details[:host_port]

      definition = {
        :client => LogStash::SnmpClient.new(protocol, address, port, community, version, retries, timeout, mib),
        :get => Array(get),
        :walk => Array(walk),

        :host_protocol => protocol,
        :host_address => address,
        :host_port => port,
        :host_community => community,
      }
      @client_definitions << definition
    end
  end

  def run(queue)
    # for now a naive single threaded poller which sleeps for the given interval between
    # each run. each run polls all the defined hosts for the get and walk options.
    while !stop?
      @client_definitions.each do |definition|
        result = {}
        if !definition[:get].empty?
          begin
            result = result.merge(definition[:client].get(definition[:get], @oid_root_skip))
          rescue => e
            logger.error("error invoking get operation on OIDs: #{definition[:get]}, ignoring", :exception => e, :backtrace => e.backtrace)
          end
        end
        if  !definition[:walk].empty?
          definition[:walk].each do |oid|
            begin
              result = result.merge(definition[:client].walk(oid, @oid_root_skip))
            rescue => e
              logger.error("error invoking walk operation on OID: #{oid}, ignoring", :exception => e, :backtrace => e.backtrace)
            end
          end
        end

        unless result.empty?
          metadata = {
              "host_protocol" => definition[:host_protocol],
              "host_address" => definition[:host_address],
              "host_port" => definition[:host_port],
              "host_community" => definition[:host_community],
          }
          result["@metadata"] = metadata

          event = LogStash::Event.new(result)
          decorate(event)
          queue << event
        end
      end

      Stud.stoppable_sleep(@interval) { stop? }
    end
  end

  def stop
  end

  private

  OID_REGEX = /^\.?([0-9\.]+)$/
  HOST_REGEX = /^(?<host_protocol>udp|tcp):(?<host_address>.+)\/(?<host_port>\d+)$/i
  VERSION_REGEX =/^1|2c$/

  def validate_oids!
    @get = Array(@get).map do |oid|
      # verify oids for valid pattern and get rid or any leading dot if present
      unless oid =~ OID_REGEX
        raise(LogStash::ConfigurationError, "The get option oid '#{oid}' has an invalid format")
      end
      $1
    end

    @walk = Array(@walk).map do |oid|
      # verify oids for valid pattern and get rid or any leading dot if present
      unless oid =~ OID_REGEX
        raise(LogStash::ConfigurationError, "The walk option oid '#{oid}' has an invalid format")
      end
      $1
    end

    raise(LogStash::ConfigurationError, "at least one get OID or one walk OID is required") if @get.empty? && @walk.empty?
  end

  def validate_hosts!
    # TODO: for new we only validate the host part, not the other optional options

    raise(LogStash::ConfigurationError, "at least one host definition is required") if Array(@hosts).empty?

    @hosts.each do |host|
      raise(LogStash::ConfigurationError, "each host definition must have a \"host\" option") if !host.is_a?(Hash) || host["host"].nil?
    end
  end
end
