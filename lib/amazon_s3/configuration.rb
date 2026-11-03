module AmazonS3
    class ConfigurationError < StandardError; end
    class Configuration
        class << self
            def get
                if @singleton.nil?
                  @singleton = Configuration.new
                  @singleton.load(@singleton.default_config_path)
                end
                @singleton
              end
        end

        def initialize
            @config = {
              :access_key_id      => nil,
              :secret_access_key  => nil,
              :bucket             => nil,
              :region             => nil,
              :endpoint           => nil,
              :attachments_folder => nil,
              :thumbnails_folder  => nil,
              :private            => false,
            }
        end

        def default_config_path
            File.join(Rails.root, 'config', 'amazon_s3.yml')
        end

        def load(path)
            file = ERB.new( File.read(path) ).result
            config = YAML::load( file )[Rails.env]
      
            if config.nil?
              raise ConfigurationError.new("No amazon_s3 configuration found for environment '#{Rails.env}'")
            end
      
            set(config)
        end

        def set(config)
            config.each do |key, value|
              if !@config.has_key? key.to_sym
                raise ConfigurationError.new("Unknown configuration option '#{key}'")
              end
              @config[key.to_sym] = value
            end
          end
      
          def access_key_id
            @config[:access_key_id]
          end
      
          def secret_access_key
            @config[:secret_access_key]
          end
      
          def bucket
            @config[:bucket]
          end
      
          def region
            @config[:region]
          end

          # Custom S3-compatible endpoint (e.g. MinIO, Scaleway, OVH).
          # The AWS_ENDPOINT environment variable takes precedence over the YAML value.
          def endpoint
            ENV['AWS_ENDPOINT'].presence || @config[:endpoint].presence
          end

          # Custom endpoints generally don't support virtual-hosted-style
          # bucket addressing, so path style is enforced whenever one is set.
          def force_path_style?
            endpoint.present?
          end
      
          def private?
            @config[:private]
          end
      
          def attachments_folder
            str = @config[:attachments_folder]
            if str.present?
              str.match(/\S+\//) ? str : "#{str}/"
            else
              ''
            end
          end
      
          def thumbnails_folder
            str = @config[:thumbnails_folder]
            if str.present?
              str.match(/\S+\//) ? str : "#{str}/"
            else
              'thumbnails/'
            end
        end
    end
end