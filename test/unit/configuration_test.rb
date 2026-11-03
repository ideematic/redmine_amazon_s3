# frozen_string_literal: true

require_relative '../test_helper'

class RedmineAmazonS3::ConfigurationTest < ActiveSupport::TestCase
  Configuration = RedmineAmazonS3::Configuration

  def write_config(content)
    file = Tempfile.new(['amazon_s3', '.yml'])
    file.write(content)
    file.close
    @files = (@files || []) << file
    file.path
  end

  def teardown
    @files&.each(&:close!)
  end

  def test_missing_file_should_be_inactive
    config = Configuration.load('/nonexistent/amazon_s3.yml', 'production', {})
    assert_not config.present?
    assert_not config.active?
  end

  def test_missing_environment_section_should_be_inactive
    path = write_config("development:\n  bucket: dev\n  region: eu-west-1\n")
    assert_not Configuration.load(path, 'production', {}).active?
  end

  def test_load_should_evaluate_erb_and_read_environment_section
    path = write_config(<<~YAML)
      production:
        bucket: <%= "bucket-" + "prod" %>
        region: eu-west-3
        attachments_folder: files
        force_path_style: "true"
    YAML
    config = Configuration.load(path, 'production', {})
    assert config.active?
    assert_equal 'bucket-prod', config.bucket
    assert_equal 'files/', config.key_prefix
    assert_equal true, config.force_path_style
  end

  def test_enabled_false_should_be_inactive_without_validation
    config = Configuration.new({enabled: false})
    assert config.present?
    assert_not config.active?
  end

  def test_unknown_option_should_raise
    assert_raise(RedmineAmazonS3::ConfigurationError) do
      Configuration.new({bucket: 'b', region: 'r', bukket: 'typo'})
    end
  end

  def test_bucket_should_be_required
    assert_raise(RedmineAmazonS3::ConfigurationError) { Configuration.new({region: 'eu-west-1'}) }
  end

  def test_region_or_endpoint_should_be_required
    assert_raise(RedmineAmazonS3::ConfigurationError) { Configuration.new({bucket: 'b'}) }
    assert Configuration.new({bucket: 'b', endpoint: 'http://localhost:9000'}).active?
  end

  def test_keys_should_be_set_together
    assert_raise(RedmineAmazonS3::ConfigurationError) do
      Configuration.new({bucket: 'b', region: 'r', access_key_id: 'AKIA'})
    end
  end

  def test_invalid_sse_should_raise
    assert_raise(RedmineAmazonS3::ConfigurationError) do
      Configuration.new({bucket: 'b', region: 'r', sse: 'rot13'})
    end
  end

  def test_invalid_checksum_mode_should_raise
    assert_raise(RedmineAmazonS3::ConfigurationError) do
      Configuration.new({bucket: 'b', region: 'r', request_checksum_calculation: 'always'})
    end
  end

  def test_legacy_options_should_be_ignored_with_a_warning
    config = Configuration.new({bucket: 'b', region: 'r', thumbnails_folder: 'thumbs/', private: true})
    assert config.active?
    assert_equal 2, config.warnings.size
  end

  def test_environment_variables_should_override_file
    config = Configuration.new(
      {bucket: 'from-file', region: 'r'},
      environment: {'REDMINE_S3_BUCKET' => 'from-env', 'REDMINE_S3_ENABLED' => 'false'}
    )
    assert_equal 'from-env', config.bucket
    assert_not config.active?
  end

  def test_aws_endpoint_should_override_endpoint_and_force_path_style
    config = Configuration.new(
      {bucket: 'b', region: 'r', endpoint: 'https://from-file', force_path_style: false},
      environment: {'AWS_ENDPOINT' => 'http://minio:9000', 'REDMINE_S3_FORCE_PATH_STYLE' => 'false'}
    )
    assert_equal 'http://minio:9000', config.endpoint
    assert_equal true, config.force_path_style
    assert_equal 'http://minio:9000', config.client_options[:endpoint]
    assert_equal true, config.client_options[:force_path_style]
  end

  def test_aws_endpoint_should_satisfy_region_requirement
    config = Configuration.new({bucket: 'b'}, environment: {'AWS_ENDPOINT' => 'http://minio:9000'})
    assert config.active?
  end

  def test_blank_aws_endpoint_should_be_ignored
    config = Configuration.new(
      {bucket: 'b', region: 'r', endpoint: 'https://from-file'},
      environment: {'AWS_ENDPOINT' => '  '}
    )
    assert_equal 'https://from-file', config.endpoint
    assert_equal false, config.force_path_style
  end

  def test_redmine_s3_endpoint_should_take_precedence_over_aws_endpoint
    config = Configuration.new(
      {bucket: 'b', region: 'r'},
      environment: {'AWS_ENDPOINT' => 'http://aws-endpoint', 'REDMINE_S3_ENDPOINT' => 'http://plugin-endpoint'}
    )
    assert_equal 'http://plugin-endpoint', config.endpoint
    assert_equal true, config.force_path_style
  end

  def test_key_prefix
    assert_equal '', Configuration.new({bucket: 'b', region: 'r'}).key_prefix
    assert_equal 'a/b/', Configuration.new({bucket: 'b', region: 'r', prefix: '/a/b'}).key_prefix
    assert_equal 'a/', Configuration.new({bucket: 'b', region: 'r', prefix: 'a/'}).key_prefix
  end

  def test_client_options_should_use_default_credential_chain_without_keys
    options = Configuration.new({bucket: 'b', region: 'eu-west-1'}).client_options
    assert_not options.key?(:credentials)
    assert_not options.key?(:endpoint)
    assert_equal 'when_required', options[:request_checksum_calculation]
    assert_equal 'when_required', options[:response_checksum_validation]
  end

  def test_client_options_with_keys_and_endpoint
    options = Configuration.new(
      {bucket: 'b', endpoint: 'http://127.0.0.1:8333', force_path_style: true,
       access_key_id: 'key', secret_access_key: 'secret'}
    ).client_options
    assert_equal 'http://127.0.0.1:8333', options[:endpoint]
    assert_equal true, options[:force_path_style]
    assert_equal 'key', options[:credentials].access_key_id
  end

  def test_sse_options
    assert_equal({}, Configuration.new({bucket: 'b', region: 'r'}).sse_options)
    assert_equal(
      {server_side_encryption: 'aws:kms', ssekms_key_id: 'kms-key'},
      Configuration.new({bucket: 'b', region: 'r', sse: 'aws:kms', sse_kms_key_id: 'kms-key'}).sse_options
    )
  end

  def test_booleans_should_be_parsed_strictly
    %w[no off false 0 NO].each do |value|
      config = Configuration.new({bucket: 'b', region: 'r'}, environment: {'REDMINE_S3_ENABLED' => value})
      assert_not config.active?, "#{value} should disable"
    end
    assert_raise(RedmineAmazonS3::ConfigurationError) do
      Configuration.new({bucket: 'b', region: 'r', force_path_style: 'maybe'})
    end
  end

  def test_multipart_threshold_should_respect_s3_part_limits
    assert_raise(RedmineAmazonS3::ConfigurationError) do
      Configuration.new({bucket: 'b', region: 'r', multipart_threshold: 1024})
    end
    assert_raise(RedmineAmazonS3::ConfigurationError) do
      Configuration.new({bucket: 'b', region: 'r', multipart_threshold: 10_485_760.5})
    end
    assert_equal 10_485_760, Configuration.new({bucket: 'b', region: 'r', multipart_threshold: '10485760'}).multipart_threshold
  end

  def test_legacy_attachments_folder_should_keep_the_1x_key_rule
    {'attachments' => 'attachments/', 'attachments/' => 'attachments/',
     '/files' => '/files/', 'a/b' => 'a/b', '' => ''}.each do |folder, expected|
      config = Configuration.new({bucket: 'b', region: 'r', attachments_folder: folder})
      assert_equal expected, config.key_prefix, "attachments_folder #{folder.inspect}"
    end
  end

  def test_non_hash_yaml_should_raise
    path = write_config("- just\n- a list\n")
    assert_raise(RedmineAmazonS3::ConfigurationError) { Configuration.load(path, 'production', {}) }
    path = write_config("production: a string\n")
    assert_raise(RedmineAmazonS3::ConfigurationError) { Configuration.load(path, 'production', {}) }
  end

  def test_environment_variables_alone_should_not_activate
    config = Configuration.load('/nonexistent.yml', 'production', {'REDMINE_S3_BUCKET' => 'b', 'REDMINE_S3_REGION' => 'r'})
    assert_not config.active?
  end

  def test_inspect_should_redact_secrets
    config = Configuration.new({bucket: 'b', region: 'r', access_key_id: 'AKIA', secret_access_key: 'top-secret'})
    assert_not_include 'top-secret', config.inspect
    assert_not_include 'top-secret', RedmineAmazonS3::Storage.new(config).inspect
  end

  def test_empty_boolean_should_keep_the_default
    path = write_config("production:\n  bucket: b\n  region: r\n  enabled: <%= ENV['REDMINE_S3_UNSET_TEST'] %>\n")
    assert Configuration.load(path, 'production', {}).active?
  end
end
