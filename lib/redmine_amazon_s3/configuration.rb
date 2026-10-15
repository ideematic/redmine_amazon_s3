# frozen_string_literal: true

require 'erb'
require 'yaml'

module RedmineAmazonS3
  # Settings read from config/amazon_s3.yml (ERB, one section per Rails
  # environment). Every option can be overridden by an environment variable
  # named REDMINE_S3_<OPTION>, e.g. REDMINE_S3_BUCKET.
  class Configuration
    DEFAULTS = {
      enabled: true,
      access_key_id: nil,
      secret_access_key: nil,
      session_token: nil,
      region: nil,
      endpoint: nil,
      force_path_style: false,
      bucket: nil,
      prefix: nil,
      sse: nil,
      sse_kms_key_id: nil,
      request_checksum_calculation: 'when_required',
      response_checksum_validation: 'when_required',
      multipart_threshold: 100 * 1024 * 1024,
      conditional_writes: false
    }.freeze

    ALIASES = {attachments_folder: :prefix}.freeze
    DEPRECATED = %i[thumbnails_folder private].freeze
    BOOLEANS = %i[enabled force_path_style conditional_writes].freeze
    TRUE_VALUES = %w[true 1 yes on].freeze
    FALSE_VALUES = %w[false 0 no off].freeze
    SECRETS = %i[secret_access_key session_token].freeze
    # S3 multipart limits: parts of 5 MiB to 5 GiB
    MULTIPART_RANGE = (5 * 1024 * 1024)..(5 * 1024 * 1024 * 1024)
    SSE_VALUES = %w[AES256 aws:kms].freeze
    CHECKSUM_VALUES = %w[when_supported when_required].freeze

    attr_reader :options

    def self.default_path
      Rails.root.join('config', 'amazon_s3.yml').to_s
    end

    # Loads the section for the given environment. A missing file or section
    # returns an inactive configuration; a present but invalid section raises.
    def self.load(path = default_path, env = Rails.env, environment = ENV)
      section =
        if File.file?(path)
          yaml = YAML.safe_load(ERB.new(File.read(path)).result, aliases: true) || {}
          raise ConfigurationError, "#{path} must contain a hash" unless yaml.is_a?(Hash)

          yaml[env.to_s]
        end
      new(section, environment: environment, present: !section.nil?)
    end

    def initialize(hash = {}, environment: {}, present: true)
      @present = present
      @warnings = []
      @options = DEFAULTS.dup
      merge!(hash || {})
      merge!(env_overrides(environment))
      validate! if active?
    end

    def present?
      @present
    end

    def active?
      present? && options[:enabled]
    end

    attr_reader :warnings

    DEFAULTS.each_key do |name|
      define_method(name) { options[name] }
    end

    # Key prefix with a trailing slash, or an empty string. The legacy
    # attachments_folder option keeps the exact 1.x rule, so that objects
    # uploaded by 1.x keep their keys.
    def key_prefix
      return legacy_key_prefix if @legacy_prefix

      value = prefix.to_s.strip.delete_prefix('/')
      value.empty? || value.end_with?('/') ? value : "#{value}/"
    end

    def inspect
      redacted = options.to_h { |key, value| [key, SECRETS.include?(key) && value.present? ? '[FILTERED]' : value] }
      "#<#{self.class.name} active=#{active?} #{redacted.inspect}>"
    end

    def client_options
      opts = {
        region: region.presence || 'us-east-1',
        force_path_style: force_path_style,
        request_checksum_calculation: request_checksum_calculation,
        response_checksum_validation: response_checksum_validation
      }
      opts[:endpoint] = endpoint if endpoint.present?
      # Without explicit keys the SDK uses its default credential chain
      # (environment, shared files, IAM roles, instance profiles...).
      if access_key_id.present? && secret_access_key.present?
        opts[:credentials] = Aws::Credentials.new(access_key_id, secret_access_key, session_token.presence)
      end
      opts
    end

    def sse_options
      return {} if sse.blank?

      opts = {server_side_encryption: sse}
      opts[:ssekms_key_id] = sse_kms_key_id if sse == 'aws:kms' && sse_kms_key_id.present?
      opts
    end

    private

    def merge!(hash)
      raise ConfigurationError, 'S3 configuration must be a hash' unless hash.is_a?(Hash)

      hash.each do |raw_key, value|
        key = raw_key.to_s.to_sym
        if DEPRECATED.include?(key)
          @warnings << "Option '#{key}' is no longer used and is ignored"
          next
        end
        @legacy_prefix = true if key == :attachments_folder
        @legacy_prefix = false if key == :prefix
        key = ALIASES.fetch(key, key)
        raise ConfigurationError, "Unknown S3 configuration option '#{raw_key}'" unless DEFAULTS.key?(key)

        @options[key] = cast(key, value)
      end
    end

    def env_overrides(environment)
      DEFAULTS.each_key.with_object({}) do |key, overrides|
        name = "REDMINE_S3_#{key.to_s.upcase}"
        overrides[key] = environment[name] if environment.key?(name)
      end
    end

    def cast(key, value)
      if BOOLEANS.include?(key)
        cast_boolean(key, value)
      elsif key == :multipart_threshold
        raise ArgumentError if value.is_a?(Float)

        Integer(value)
      else
        value.nil? ? nil : value.to_s
      end
    rescue ArgumentError, TypeError
      raise ConfigurationError, "Invalid value for S3 option '#{key}': #{value.inspect}"
    end

    def cast_boolean(key, value)
      return value if [true, false].include?(value)
      # An empty value (e.g. "enabled: <%= ENV['UNSET'] %>") keeps the default
      return DEFAULTS[key] if value.nil? || value.to_s.strip.empty?

      text = value.to_s.strip.downcase
      return true if TRUE_VALUES.include?(text)
      return false if FALSE_VALUES.include?(text)

      raise ConfigurationError, "Invalid boolean for S3 option '#{key}': #{value.inspect}"
    end

    # 1.x appended a slash unless the value contained one anywhere.
    def legacy_key_prefix
      value = prefix.to_s
      return '' if value.blank?

      value.match?(%r{\S+/}) ? value : "#{value}/"
    end

    def validate!
      raise ConfigurationError, "S3 option 'bucket' is required" if bucket.blank?
      if region.blank? && endpoint.blank?
        raise ConfigurationError, "S3 option 'region' is required unless 'endpoint' is set"
      end
      if (access_key_id.present? || secret_access_key.present?) &&
         !(access_key_id.present? && secret_access_key.present?)
        raise ConfigurationError, "S3 options 'access_key_id' and 'secret_access_key' must be set together"
      end
      if sse.present? && !SSE_VALUES.include?(sse)
        raise ConfigurationError, "S3 option 'sse' must be one of #{SSE_VALUES.join(', ')}"
      end
      %i[request_checksum_calculation response_checksum_validation].each do |key|
        unless CHECKSUM_VALUES.include?(options[key])
          raise ConfigurationError, "S3 option '#{key}' must be one of #{CHECKSUM_VALUES.join(', ')}"
        end
      end
      unless MULTIPART_RANGE.cover?(multipart_threshold)
        raise ConfigurationError,
              "S3 option 'multipart_threshold' must be between #{MULTIPART_RANGE.min} and #{MULTIPART_RANGE.max} bytes"
      end
    end
  end
end
