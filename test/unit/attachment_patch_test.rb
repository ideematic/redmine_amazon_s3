# frozen_string_literal: true

require_relative '../test_helper'

class RedmineAmazonS3::AttachmentPatchTest < ActiveSupport::TestCase
  fixtures :users, :projects, :issues, :trackers, :issue_statuses, :enumerations

  def setup
    set_tmp_attachments_directory
    @s3 = enable_fake_s3
    User.current = nil
  end

  def teardown
    disable_fake_s3
    Attachment.thumbnails_storage_path = Rails.root.join('tmp', 'thumbnails').to_s
  end

  def test_create_should_upload_to_s3_and_compute_sha256
    attachment = create_s3_attachment(content: 'Hello S3')
    assert_equal Time.now.strftime('%Y/%m'), attachment.disk_directory
    assert_match(/\A\d{12}_[0-9a-f]{8}_hello\.txt\z/, attachment.disk_filename)
    assert_equal Digest::SHA256.hexdigest('Hello S3'), attachment.digest
    assert_equal "att/#{attachment.disk_directory}/#{attachment.disk_filename}", attachment.s3_key
    assert_equal 'Hello S3', @s3.data(attachment.s3_key)
    assert_equal 'text/plain', @s3.objects[attachment.s3_key][:content_type]
    assert_not File.exist?(File.join(Attachment.storage_path, attachment.disk_directory, attachment.disk_filename))
  end

  def test_create_from_uploaded_file_should_stream_it
    attachment = Attachment.create!(
      file: uploaded_test_file('testfile.txt', 'text/plain'), author: User.find(1)
    )
    content = fixture_file_content('testfile.txt')
    assert_equal content, @s3.data(attachment.s3_key)
    assert_equal Digest::SHA256.hexdigest(content), attachment.digest
    assert_equal content.bytesize, attachment.filesize
  end

  def test_create_with_non_ascii_filename_should_use_hashed_name
    attachment = create_s3_attachment(filename: 'résumé été.txt')
    assert_match(/\A\d{12}_[0-9a-f]{8}_[0-9a-f]{32}\.txt\z/, attachment.disk_filename)
  end

  def test_same_filename_at_the_same_time_should_not_overwrite
    first = create_s3_attachment(content: 'first')
    second = create_s3_attachment(content: 'second')
    assert_not_equal first.s3_key, second.s3_key
    assert_equal 'first', @s3.data(first.s3_key)
    assert_equal 'second', @s3.data(second.s3_key)
  end

  def test_create_should_fill_content_type_like_core
    attachment = create_s3_attachment(filename: 'image.png', content_type: nil)
    assert_equal 'image/png', attachment.content_type
  end

  def test_failed_upload_should_not_save_attachment
    @s3.client.stub_responses(:put_object, 'ServiceUnavailable')
    attachment = Attachment.new(file: 'data', filename: 'fail.txt', author: User.find(1))
    assert_no_difference 'Attachment.count' do
      assert_not attachment.save
    end
    assert_include I18n.t(:error_redmine_amazon_s3_upload_failed), attachment.errors.full_messages
  end

  def test_readable_should_check_s3
    attachment = create_s3_attachment
    assert attachment.readable?
    @s3.objects.clear
    assert attachment.reload.readable? == false
  end

  def test_readable_should_be_memoized
    attachment = create_s3_attachment
    attachment.reload
    3.times { attachment.readable? }
    assert_equal 1, @s3.requests(:head_object).size
  end

  def test_destroy_should_delete_object
    attachment = create_s3_attachment
    key = attachment.s3_key
    attachment.destroy
    assert_nil @s3.data(key)
  end

  def test_destroy_should_not_delete_object_referenced_by_a_copy
    attachment = create_s3_attachment
    copy = attachment.copy
    copy.save!
    assert_equal attachment.s3_key, copy.s3_key

    attachment.destroy
    assert_equal 'Hello S3', @s3.data(copy.s3_key)
    copy.destroy
    assert_nil @s3.data(copy.s3_key)
  end

  def test_rollback_should_delete_uploaded_object
    key = nil
    Attachment.transaction(requires_new: true) do
      key = create_s3_attachment.s3_key
      raise ActiveRecord::Rollback
    end
    assert_nil @s3.data(key)
  end

  def test_same_content_should_reuse_existing_object
    first = create_s3_attachment(content: 'same content', filename: 'a.txt')
    second = create_s3_attachment(content: 'same content', filename: 'b.txt')
    assert_equal first.s3_key, second.reload.s3_key
    assert_equal 2, @s3.requests(:put_object).size
    assert_equal [first.s3_key], @s3.objects.keys, 'the duplicate object should be deleted'
  end

  def test_same_content_should_not_reuse_missing_object
    first = create_s3_attachment(content: 'same content', filename: 'a.txt')
    @s3.objects.delete(first.s3_key)
    second = create_s3_attachment(content: 'same content', filename: 'b.txt')
    original_key = second.s3_key
    assert_equal original_key, second.reload.s3_key
    assert_equal 'same content', @s3.data(original_key)
  end

  def test_legacy_fake_digest_should_never_be_deduplicated
    first = create_s3_attachment(content: 'legacy', filename: 'a.txt')
    first.update_column(:digest, '1670836478')
    second = create_s3_attachment(content: 'legacy', filename: 'b.txt')
    second.update_column(:digest, '1670836478')
    second.send(:reuse_existing_file_if_possible)
    assert_not_equal first.s3_key, second.reload.s3_key
  end

  def test_update_digest_to_sha256_should_stream_object
    attachment = create_s3_attachment(content: 'digest me')
    attachment.update_column(:digest, '1670836478')
    attachment.reload.update_digest_to_sha256!
    assert_equal Digest::SHA256.hexdigest('digest me'), attachment.reload.digest
  end

  def test_move_to_target_directory_should_be_a_noop
    attachment = create_s3_attachment
    attachment.update_column(:disk_directory, nil)
    attachment.reload.move_to_target_directory!
    assert_nil attachment.reload.disk_directory
  end

  def test_with_s3_local_copy_should_download_lazily
    attachment = create_s3_attachment(content: 'local copy').reload
    path = nil
    attachment.with_s3_local_copy do
      assert_equal 0, @s3.requests(:get_object).size
      path = attachment.diskfile
      assert_equal 'local copy', File.binread(path)
      assert_equal path, attachment.diskfile
      attachment.with_s3_local_copy { assert_equal path, attachment.diskfile }
      assert File.exist?(path), 'nested release should keep the copy'
    end
    assert_not File.exist?(path)
    assert_equal 1, @s3.requests(:get_object).size
    assert_not_equal path, attachment.diskfile
  end

  def test_archive_attachments_should_read_from_s3
    one = create_s3_attachment(content: 'one', filename: 'same.txt')
    two = create_s3_attachment(content: 'two', filename: 'same.txt')
    zip = Attachment.archive_attachments([one, two])
    entries = {}
    Zip::InputStream.open(StringIO.new(zip)) do |io|
      while (entry = io.get_next_entry)
        entries[entry.name] = io.read
      end
    end
    assert_equal({'same.txt' => 'one', 'same(1).txt' => 'two'}, entries)
  end

  def test_archive_attachments_should_skip_missing_objects
    one = create_s3_attachment(content: 'one', filename: 'one.txt')
    two = create_s3_attachment(content: 'two', filename: 'two.txt')
    @s3.objects.delete(two.s3_key)
    zip = Attachment.archive_attachments([one, two.reload])
    names = []
    Zip::InputStream.open(StringIO.new(zip)) do |io|
      while (entry = io.get_next_entry)
        names << entry.name
      end
    end
    assert_equal ['one.txt'], names
  end

  def test_thumbnail_should_be_generated_from_s3_and_cached_locally
    skip 'ImageMagick convert is not available' unless convert_installed?

    set_tmp_thumbnails_directory
    attachment = create_s3_attachment(
      content: fixture_file_content('2010/11/101123161450_testfile_1.png'),
      filename: 'image.png', content_type: 'image/png'
    ).reload
    thumbnail = attachment.thumbnail(size: 50)
    assert thumbnail
    assert File.exist?(thumbnail)
    assert_equal 1, @s3.requests(:get_object).size

    assert_equal thumbnail, attachment.reload.thumbnail(size: 50)
    assert_equal 1, @s3.requests(:get_object).size, 'cached thumbnail should not download the source again'

    attachment.destroy
    assert_not File.exist?(thumbnail)
  end

  def test_inactive_plugin_should_store_files_on_local_disk
    disable_fake_s3
    assert_not RedmineAmazonS3.active?
    attachment = create_s3_attachment(content: 'local')
    assert File.exist?(attachment.diskfile)
    assert attachment.readable?
    assert_equal 'local', File.binread(attachment.diskfile)
  end

  def test_failed_multipart_upload_should_not_save_attachment
    enable_fake_s3(multipart_threshold: 5 * 1024 * 1024)
    @fake_s3.client.stub_responses(:create_multipart_upload, {upload_id: 'upload-1'})
    @fake_s3.client.stub_responses(:upload_part, 'InternalError')
    attachment = Attachment.new(file: 'x' * (5 * 1024 * 1024), filename: 'big.bin', author: User.find(1))
    assert_not attachment.save
    assert_include I18n.t(:error_redmine_amazon_s3_upload_failed), attachment.errors.full_messages
  end

  def test_failed_insert_should_delete_uploaded_object
    attachment = Attachment.new(file: 'orphan', filename: 'orphan.txt', author: User.find(1))
    Attachment.stubs(:_insert_record).raises(ActiveRecord::StatementInvalid, 'insert failed')
    assert_raise(ActiveRecord::StatementInvalid) do
      Attachment.transaction(requires_new: true) { attachment.save }
    end
    assert_equal 1, @s3.requests(:put_object).size
    assert_empty @s3.objects
  end

  def test_upload_failure_should_raise_inside_raise_upload_errors
    @s3.client.stub_responses(:put_object, 'ServiceUnavailable')
    assert_raise(RedmineAmazonS3::UploadError) do
      RedmineAmazonS3.raise_upload_errors { create_s3_attachment }
    end
  end

  def test_content_type_with_control_characters_should_not_be_sent_to_s3
    attachment = create_s3_attachment(content_type: "text/plain\r\nX-Injected: 1")
    assert_nil @s3.objects[attachment.s3_key][:content_type]
  end

  def test_retried_save_should_upload_the_whole_io
    attachment = Attachment.new(file: StringIO.new('retried content'), filename: 'retry.txt', author: User.find(1))
    @s3.client.stub_responses(:put_object, 'ServiceUnavailable')
    assert_not attachment.save

    @s3.send(:stub_object_operations)
    assert attachment.save
    assert_equal 'retried content', @s3.data(attachment.s3_key)
    assert_equal Digest::SHA256.hexdigest('retried content'), attachment.digest
  end

  def test_s3_head_cache_should_follow_the_key
    attachment = create_s3_attachment.reload
    assert attachment.readable?
    attachment.disk_filename = 'other.txt'
    assert_not attachment.readable?
  end

  def test_legacy_digest_thumbnails_should_include_the_id
    attachment = create_s3_attachment(filename: 'image.png', content_type: 'image/png')
    attachment.update_column(:digest, '1670836478')
    assert_match %r{/#{attachment.id}_1670836478_\d+_100\.thumb\z}, attachment.send(:thumbnail_path, 100)
  end

  def test_delete_errors_should_be_swallowed
    attachment = create_s3_attachment
    @s3.client.stub_responses(:delete_object, 'ServiceUnavailable')
    assert attachment.destroy
  end

  def test_server_error_on_head_should_raise
    attachment = create_s3_attachment.reload
    @s3.client.stub_responses(:head_object, 'ServiceUnavailable')
    assert_raise(Aws::S3::Errors::ServiceUnavailable) { attachment.readable? }
  end

  private

  def set_tmp_thumbnails_directory
    dir = Rails.root.join('tmp', 'test', 'thumbnails').to_s
    FileUtils.rm_rf(dir)
    Attachment.thumbnails_storage_path = dir
  end
end
