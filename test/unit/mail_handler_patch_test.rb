# frozen_string_literal: true

require_relative '../test_helper'

class RedmineAmazonS3::MailHandlerPatchTest < ActiveSupport::TestCase
  FIXTURES_PATH = File.join(Rails.root, 'test', 'fixtures', 'mail_handler')

  def setup
    set_tmp_attachments_directory
    @s3 = enable_fake_s3
    ActionMailer::Base.deliveries.clear
    Setting.notified_events = Redmine::Notifiable.all.collect(&:name)
    User.current = nil
  end

  def teardown
    disable_fake_s3
  end

  def receive(filename)
    raw = File.read(File.join(FIXTURES_PATH, filename))
    MailHandler.safe_receive(raw, issue: {project: 'onlinestore'})
  end

  def test_email_attachments_should_be_stored_in_s3
    issue = receive('ticket_with_attachment.eml')
    assert issue.is_a?(Issue)
    attachment = issue.attachments.first
    assert attachment
    assert @s3.data(attachment.s3_key).present?
  end

  def test_s3_failure_should_fail_the_email_instead_of_dropping_the_attachment
    @s3.client.stub_responses(:put_object, 'ServiceUnavailable')
    assert_equal false, receive('ticket_with_attachment.eml')
  end
end
