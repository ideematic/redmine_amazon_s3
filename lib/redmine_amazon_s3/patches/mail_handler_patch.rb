# frozen_string_literal: true

module RedmineAmazonS3
  module Patches
    # MailHandler appends Attachment.create results to the container and
    # ignores unsaved ones: an S3 failure would drop the file while the email
    # is reported as processed. Raising instead makes MailHandler.safe_receive
    # fail, so the email stays in the mailbox like with a disk error in core.
    module MailHandlerPatch
      private

      def add_attachments(obj)
        return super unless RedmineAmazonS3.active?

        RedmineAmazonS3.raise_upload_errors { super }
      end
    end
  end
end
