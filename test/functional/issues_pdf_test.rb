# frozen_string_literal: true

require_relative '../test_helper'

class RedmineAmazonS3::IssuesPdfTest < Redmine::ControllerTest
  tests IssuesController

  def setup
    set_tmp_attachments_directory
    @s3 = enable_fake_s3
    User.current = nil
  end

  def teardown
    disable_fake_s3
  end

  def test_pdf_export_should_embed_inline_image_from_s3
    issue = Issue.find(1)
    image = create_s3_attachment(
      container: issue, filename: 'inline.png', content_type: 'image/png',
      content: fixture_file_content('2010/11/101123161450_testfile_1.png')
    )
    issue.update_column(:description, "Screenshot:\n\n![](inline.png)")

    with_settings text_formatting: 'common_mark' do
      get :show, params: {id: issue.id, format: 'pdf'}
    end
    assert_response :success
    assert_equal 'application/pdf', response.media_type
    image_gets = @s3.requests(:get_object).select { |r| r[:params][:key] == image.s3_key }
    assert_equal 1, image_gets.size
    assert_match(%r{/Subtype\s*/Image}, response.body)
  end

  def test_pdf_export_without_images_should_not_download_anything
    get :show, params: {id: 1, format: 'pdf'}
    assert_response :success
    assert_equal 0, @s3.requests(:get_object).size
  end

  def test_pdf_export_should_not_download_original_when_thumbnail_is_cached
    skip 'ImageMagick convert is not available' unless convert_installed?

    Attachment.thumbnails_storage_path = Rails.root.join('tmp', 'test', 'thumbnails').to_s
    FileUtils.rm_rf(Attachment.thumbnails_storage_path)
    issue = Issue.find(1)
    image = create_s3_attachment(
      container: issue, filename: 'inline.png', content_type: 'image/png',
      content: fixture_file_content('2010/11/101123161450_testfile_1.png')
    )
    assert image.reload.thumbnail(size: 200)
    gets = @s3.requests(:get_object).size
    issue.update_column(:description, "{{thumbnail(inline.png, size=200)}}")

    with_settings text_formatting: 'common_mark' do
      get :show, params: {id: issue.id, format: 'pdf'}
    end
    assert_response :success
    assert_equal gets, @s3.requests(:get_object).size
  ensure
    Attachment.thumbnails_storage_path = Rails.root.join('tmp', 'thumbnails').to_s
  end

  def test_pdf_export_should_skip_image_that_cannot_be_downloaded
    issue = Issue.find(1)
    create_s3_attachment(container: issue, filename: 'inline.png', content_type: 'image/png', content: 'png')
    issue.update_column(:description, "![](inline.png)")
    @s3.client.stub_responses(:get_object, 'ServiceUnavailable')

    with_settings text_formatting: 'common_mark' do
      get :show, params: {id: issue.id, format: 'pdf'}
    end
    assert_response :success
    assert_equal 'application/pdf', response.media_type
  end

  def test_output_aliases_should_release_local_copies
    image = create_s3_attachment(container: Issue.find(1), filename: 'inline.png', content_type: 'image/png',
                                 content: fixture_file_content('2010/11/101123161450_testfile_1.png'))
    %w[Output output].each do |method|
      pdf = Redmine::Export::PDF::ITCPDF.new('en')
      pdf.add_page
      pdf.instance_variable_set(:@attachments, [image])
      path = pdf.get_image_filename('inline.png')
      assert File.exist?(path)
      pdf.public_send(method, '', 'S')
      assert_not File.exist?(path), "#{method} should release the local copy"
    end
  end
end
