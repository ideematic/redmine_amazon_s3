# frozen_string_literal: true

require_relative '../test_helper'

class RedmineAmazonS3::AttachmentsControllerTest < Redmine::ControllerTest
  tests AttachmentsController

  def setup
    set_tmp_attachments_directory
    @s3 = enable_fake_s3
    User.current = nil
  end

  def teardown
    disable_fake_s3
  end

  def issue_attachment(**options)
    create_s3_attachment(container: Issue.find(1), **options)
  end

  def test_download_should_stream_object_with_core_headers
    attachment = issue_attachment(content: 'Hello S3 download', filename: 'notes.txt')
    get :download, params: {id: attachment.id}

    assert_response :success
    assert_equal 'Hello S3 download', response.body
    assert_equal 'Hello S3 download'.bytesize.to_s, response.headers['Content-Length']
    assert_equal 'text/plain', response.media_type
    assert_equal RedmineAmazonS3::CONTENT_SECURITY_POLICY, response.headers['Content-Security-Policy']
    assert_match(/\Aattachment; filename="notes\.txt"/, response.headers['Content-Disposition'])
    assert_not_nil response.etag
  end

  def test_download_should_return_not_modified_for_matching_etag
    attachment = issue_attachment
    get :download, params: {id: attachment.id}
    etag = response.etag
    gets = @s3.requests(:get_object).size

    @request.env['HTTP_IF_NONE_MATCH'] = etag
    get :download, params: {id: attachment.id}
    assert_response :not_modified
    assert_equal gets, @s3.requests(:get_object).size, '304 should not read the object'
  end

  def test_download_pdf_should_be_inline
    attachment = issue_attachment(content: '%PDF-1.4', filename: 'doc.pdf', content_type: 'application/pdf')
    get :download, params: {id: attachment.id}
    assert_response :success
    assert_match(/\Ainline/, response.headers['Content-Disposition'])
  end

  def test_download_missing_object_should_respond_404
    attachment = issue_attachment
    @s3.objects.clear
    get :download, params: {id: attachment.id}
    assert_response :not_found
  end

  def test_download_should_require_permission
    project = Project.find(1)
    project.update!(is_public: false)
    attachment = issue_attachment
    get :download, params: {id: attachment.id}
    assert_response :redirect
    assert_equal 0, @s3.requests(:get_object).size
  end

  def test_show_text_file_should_read_object
    attachment = issue_attachment(content: "line one\nline two\n", filename: 'file.txt')
    get :show, params: {id: attachment.id}
    assert_response :success
    assert_select 'table.filecontent td.line-code', text: /line two/
  end

  def test_show_diff_should_read_object
    diff = fixture_file_content('hg-export.diff')
    attachment = issue_attachment(content: diff, filename: 'changes.diff', content_type: 'text/x-diff')
    get :show, params: {id: attachment.id}
    assert_response :success
    assert_select 'table.filecontent'
  end

  def test_show_image_should_not_download_object
    attachment = issue_attachment(content: 'png', filename: 'image.png', content_type: 'image/png')
    get :show, params: {id: attachment.id}
    assert_response :success
    assert_equal 0, @s3.requests(:get_object).size
  end

  def test_thumbnail_should_be_generated_from_object
    skip 'ImageMagick convert is not available' unless convert_installed?

    Attachment.thumbnails_storage_path = Rails.root.join('tmp', 'test', 'thumbnails').to_s
    FileUtils.rm_rf(Attachment.thumbnails_storage_path)
    attachment = issue_attachment(
      content: fixture_file_content('2010/11/101123161450_testfile_1.png'),
      filename: 'image.png', content_type: 'image/png'
    )
    get :thumbnail, params: {id: attachment.id, size: 50}
    assert_response :success
    assert_equal 'image/png', response.media_type
    assert_equal RedmineAmazonS3::CONTENT_SECURITY_POLICY, response.headers['Content-Security-Policy']
  ensure
    Attachment.thumbnails_storage_path = Rails.root.join('tmp', 'thumbnails').to_s
  end

  def test_download_all_should_zip_objects
    issue = Issue.find(1)
    issue.attachments.each(&:delete)
    issue_attachment(content: 'one', filename: 'one.txt')
    issue_attachment(content: 'two', filename: 'two.txt')
    get :download_all, params: {object_type: 'issues', object_id: issue.id}
    assert_response :success
    assert_equal 'application/zip', response.media_type
    names = []
    Zip::InputStream.open(StringIO.new(response.body)) do |io|
      while (entry = io.get_next_entry)
        names << entry.name
      end
    end
    assert_equal %w[one.txt two.txt], names.sort
  end

  def test_destroy_should_delete_object
    @request.session[:user_id] = 2
    attachment = issue_attachment
    key = attachment.s3_key
    delete :destroy, params: {id: attachment.id}
    assert_response :redirect
    assert_nil @s3.data(key)
  end

  def test_download_larger_than_first_part_should_stream_the_rest
    size = RedmineAmazonS3::Patches::AttachmentsControllerPatch::FIRST_PART_SIZE + 1000
    content = Random.bytes(size)
    attachment = issue_attachment(content: content, filename: 'big.bin', content_type: 'application/octet-stream')
    get :download, params: {id: attachment.id}
    assert_response :success
    assert_equal content, response.body.b
    ranges = @s3.requests(:get_object).map { |r| r[:params][:range] }
    assert_equal ["bytes=0-#{size - 1000 - 1}", "bytes=#{size - 1000}-"], ranges
  end

  def test_download_small_file_should_need_a_single_get
    attachment = issue_attachment(content: 'small')
    get :download, params: {id: attachment.id}
    assert_equal 'small', response.body
    assert_equal ['bytes=0-4'], @s3.requests(:get_object).map { |r| r[:params][:range] }
  end

  def test_download_empty_file_should_not_get_the_object
    attachment = issue_attachment(content: '')
    get :download, params: {id: attachment.id}
    assert_response :success
    assert_equal '', response.body
    assert_equal '0', response.headers['Content-Length']
    assert_equal 0, @s3.requests(:get_object).size
  end

  def test_s3_error_before_headers_should_respond_503
    attachment = issue_attachment
    @s3.client.stub_responses(:get_object, 'ServiceUnavailable')
    get :download, params: {id: attachment.id}
    assert_response 503
    assert_nil response.headers['Content-Disposition']
  end

  def test_object_deleted_between_head_and_get_should_respond_404
    attachment = issue_attachment
    @s3.client.stub_responses(:get_object, 'NoSuchKey')
    get :download, params: {id: attachment.id}
    assert_response :not_found
  end

  def test_s3_error_while_streaming_should_be_logged_and_raised
    body = RedmineAmazonS3::ObjectBody.new(RedmineAmazonS3.storage, 'att/missing', size: 10, first_part: 'abc')
    chunks = []
    assert_raise(Aws::S3::Errors::NoSuchKey) { body.each { |chunk| chunks << chunk } }
    assert_equal ['abc'], chunks
  end
end
