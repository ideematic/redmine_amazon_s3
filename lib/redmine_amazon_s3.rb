# frozen_string_literal: true

require 'aws-sdk-s3'

# Stores Redmine attachments in Amazon S3 or any S3-compatible object store.
#
# The plugin is active only when config/amazon_s3.yml has an enabled section
# for the current Rails environment. When inactive, every patched method falls
# back to Redmine's local disk storage.
module RedmineAmazonS3
  CONTENT_SECURITY_POLICY = "default-src 'none'; style-src 'unsafe-inline'; sandbox"

  class << self
    def configuration
      @configuration ||= Configuration.load
    end

    # Replaces the configuration, e.g. from tests. Resets the storage client.
    def configuration=(config)
      @configuration = config
      @storage = nil
    end

    def storage
      @storage ||= Storage.new(configuration)
    end

    attr_writer :storage

    def active?
      configuration.active?
    end

    def reset!
      @configuration = nil
      @storage = nil
    end

    # Loads and validates the configuration at boot, so that an invalid
    # configuration fails fast instead of on the first upload.
    def boot!
      reset!
      configuration.warnings.each { |warning| logger&.warn("[redmine_amazon_s3] #{warning}") }
      if active?
        validate_client_options!
        logger&.info(
          "[redmine_amazon_s3] Storing attachments in s3://#{configuration.bucket}/#{configuration.key_prefix}"
        )
      elsif configuration.present?
        logger&.warn("[redmine_amazon_s3] Disabled for '#{Rails.env}': attachments are stored on local disk")
      else
        logger&.warn(
          "[redmine_amazon_s3] No '#{Rails.env}' section in #{Configuration.default_path}: " \
            "attachments are stored on local disk"
        )
      end
    end

    def logger
      Rails.logger
    end

    # Inside the block, failed uploads raise UploadError instead of only
    # invalidating the attachment. Used where an unsaved attachment would be
    # silently dropped (incoming emails).
    def raise_upload_errors
      previous = ActiveSupport::IsolatedExecutionState[:redmine_amazon_s3_raise]
      ActiveSupport::IsolatedExecutionState[:redmine_amazon_s3_raise] = true
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[:redmine_amazon_s3_raise] = previous
    end

    def raise_upload_errors?
      ActiveSupport::IsolatedExecutionState[:redmine_amazon_s3_raise] == true
    end

    private

    # Building a client validates endpoint and region. Stubbed so that the
    # credential chain (e.g. the EC2 metadata endpoint) is not queried.
    def validate_client_options!
      Aws::S3::Client.new(configuration.client_options.merge(stub_responses: true))
    rescue ArgumentError, Aws::Errors::InvalidRegionError, URI::InvalidURIError => e
      raise ConfigurationError, "Invalid S3 client configuration: #{e.message}"
    end
  end
end
