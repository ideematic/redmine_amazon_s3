# Redmine Amazon S3

A [Redmine](https://www.redmine.org) 6 plugin that stores file attachments in
[Amazon S3](https://aws.amazon.com/s3/) or any S3-compatible object store
(MinIO, SeaweedFS, Garage, Ceph, Scaleway, OVH, Wasabi, Cloudflare R2...)
instead of the local `files/` directory.

Downloads still go through Redmine, so permissions, previews, thumbnails, PDF
exports and "download all" work exactly as with local storage.

## Requirements

- Redmine 6.0 or 6.1, with the Ruby version that your Redmine release requires
- An S3 bucket and credentials (see [IAM policy](#iam-policy))
- ImageMagick, only if you use thumbnails (same as Redmine core)

## Installation

The plugin id is `redmine_amazon_s3`. Redmine 6 requires the directory name to
match the plugin id, so the plugin must live in `plugins/redmine_amazon_s3`.

```bash
cd /path/to/redmine
git clone https://github.com/ideematic/redmine_amazon_s3.git plugins/redmine_amazon_s3
bundle install
cp plugins/redmine_amazon_s3/config/amazon_s3.yml.example config/amazon_s3.yml
# edit config/amazon_s3.yml, then restart Redmine
```

The plugin has no database migration.

At boot, the log shows where attachments are stored:

```
[redmine_amazon_s3] Storing attachments in s3://my-redmine-attachments/attachments/
```

## Configuration

Configuration lives in `<redmine>/config/amazon_s3.yml`, with one section per
Rails environment.

- The plugin is active only for an environment that has a section in the file
  and is not disabled with `enabled: false`. Otherwise Redmine keeps its local
  disk storage, and a warning is logged at boot.
- An invalid section (unknown option, missing bucket, bad value...) raises an
  error at boot. The plugin never silently falls back to local disk.
- The file is evaluated with ERB.
- Every option can be overridden with an environment variable named
  `REDMINE_S3_<OPTION>`, for example `REDMINE_S3_BUCKET` or
  `REDMINE_S3_PREFIX`. Environment variables do not activate the plugin on
  their own: the environment still needs a non-empty section in the file.

### Amazon S3

```yaml
production:
  bucket: my-redmine-attachments
  region: eu-west-3
  prefix: attachments
  # Omit both keys to use the AWS default credential chain
  access_key_id: <%= ENV['AWS_ACCESS_KEY_ID'] %>
  secret_access_key: <%= ENV['AWS_SECRET_ACCESS_KEY'] %>
  # sse: AES256
```

### S3-compatible stores

Set `endpoint`, and usually `force_path_style: true`:

```yaml
production:
  endpoint: https://s3.fr-par.scw.cloud
  region: fr-par
  force_path_style: true
  bucket: my-redmine-attachments
  access_key_id: <%= ENV['S3_ACCESS_KEY_ID'] %>
  secret_access_key: <%= ENV['S3_SECRET_ACCESS_KEY'] %>
```

The checksum options default to `when_required`: since aws-sdk-s3 1.178, the
SDK sends CRC32 checksums by default, and several S3-compatible providers
reject them. With AWS S3 you can set both options to `when_supported`.

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `enabled` | `true` | Set to `false` to keep local disk storage for this environment. |
| `bucket` | | Bucket name. **Required.** |
| `region` | | Bucket region, e.g. `eu-west-3`. Required unless `endpoint` is set (then defaults to `us-east-1`). |
| `endpoint` | | URL of an S3-compatible server, e.g. `https://s3.fr-par.scw.cloud`. |
| `force_path_style` | `false` | Use path-style URLs (`endpoint/bucket/key`). Needed by most S3-compatible servers. |
| `access_key_id` | | Access key. Must be set together with `secret_access_key`. |
| `secret_access_key` | | Secret key. Must be set together with `access_key_id`. |
| `session_token` | | Session token for temporary credentials. |
| `prefix` | | Folder inside the bucket, e.g. `attachments`. A trailing `/` is added if missing. Default: bucket root. |
| `sse` | | Server-side encryption: `AES256` or `aws:kms`. |
| `sse_kms_key_id` | | KMS key id or ARN, used when `sse` is `aws:kms`. Default: the AWS managed key. |
| `multipart_threshold` | `104857600` | Size in bytes (100 MB) above which files are uploaded in parts. Must be positive. |
| `conditional_writes` | `false` | Send `If-None-Match: *` so that an upload never overwrites an existing object. Supported by AWS S3; leave off for servers that reject the header. |
| `request_checksum_calculation` | `when_required` | `when_required` or `when_supported`. |
| `response_checksum_validation` | `when_required` | `when_required` or `when_supported`. |

Legacy options from 1.x:

| Option | Behaviour |
|--------|-----------|
| `attachments_folder` | Alias of `prefix`. |
| `thumbnails_folder` | Accepted and ignored, with a warning at boot. |
| `private` | Accepted and ignored, with a warning at boot. |

### Credentials

`access_key_id` and `secret_access_key` are optional. When both are empty, the
AWS SDK uses its default credential chain: `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` environment variables, shared credentials files
(`AWS_PROFILE`), and IAM roles for EC2, ECS or EKS.

## IAM policy

Minimal policy for the Redmine user or role. Replace `BUCKET` and `PREFIX`
(use `arn:aws:s3:::BUCKET/*` when there is no prefix):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::BUCKET/PREFIX*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::BUCKET"
    }
  ]
}
```

`s3:ListBucket` lets S3 answer 404 for a missing object. Without it, S3
answers 403; the plugin logs an access-denied error and treats the object as
missing.

With `sse: aws:kms`, also allow `kms:GenerateDataKey` and `kms:Decrypt` on the
KMS key.

## How it works

### Object keys

Objects are stored under `<prefix><disk_directory>/<disk_filename>`, for
example:

```
attachments/2026/10/261015135025_78c5b6ac_hello.txt
```

This is the same layout as 1.x, so objects uploaded by 1.x stay readable.

### Downloads

Downloads are streamed through Redmine, not redirected to S3. Redmine keeps
enforcing permissions and sends the same headers as with local storage: ETag
and `304 Not Modified`, `Content-Disposition`, and the CSP `sandbox` header.
Files are streamed in chunks and never loaded entirely in memory.

Text and diff previews, "download all" (zip), and inline images in PDF exports
work. They use a temporary local copy of the object, deleted afterwards.

### Thumbnails

Thumbnails are generated with ImageMagick from a temporary copy of the image,
then cached locally in `tmp/thumbnails`, as in core. The cache is per server;
a missing thumbnail is regenerated from S3.

### Deduplication

As in core, an uploaded file identical to an existing attachment (same SHA256
digest and size) reuses the existing object. Copied issues and projects share
the same objects too. An object is deleted only when no attachment references
it anymore.

Digests shorter than 64 characters (MD5, or the placeholder digests written by
1.x) are never used for deduplication.

### Upload errors

If the upload to S3 fails, the attachment is not saved and the user sees
"The file could not be stored. Please try again later." The error is logged.

## Limitations

- The upload to S3 happens inside the database transaction, like core's write
  to disk.
- "Download all" sends one HEAD request per file.
- A slow client holds a Puma thread for the whole download. Put a buffering
  reverse proxy in front of Redmine, e.g. nginx with `proxy_buffering on;`.
- CSV imports still use the local `tmp/imports` directory.
- There is no task to copy existing local attachments to S3.
- `rake redmine:attachments:move_to_subdirectories` does nothing with S3
  (each attachment is skipped with a warning).
- Uploads are buffered in `<redmine>/tmp` while their digest is computed, so
  that directory needs room for the largest attachment.
- When S3 fails while an incoming email is processed, the email is reported as
  failed and stays in the mailbox (as with a disk error in core). The issue
  itself may already have been created, so processing the email again can
  create a duplicate issue.

**Warning: copies of the database.** A staging or test instance restored from
the production database must not use the production bucket and prefix:
deleting an attachment there, or `rake redmine:attachments:prune`, deletes the
production object. Give each instance its own bucket or prefix.

## Upgrading from 1.x

1. Upgrade Redmine to 6.0 or 6.1.
2. Rename the plugin directory: the plugin id changed from `amazon_s3` to
   `redmine_amazon_s3`.

   ```bash
   mv plugins/amazon_s3 plugins/redmine_amazon_s3
   ```

3. Keep `config/amazon_s3.yml`: the file name is unchanged and 1.x keys are
   accepted (see [legacy options](#options)). Remove `thumbnails_folder` and
   `private` to silence the warnings.
4. Run `bundle install` and restart Redmine.
5. Recompute digests. Attachments uploaded by 1.x have a fake digest (a
   timestamp). Redmine's core task recomputes SHA256 digests by streaming each
   object from S3:

   ```bash
   bundle exec rake redmine:attachments:update_digests RAILS_ENV=production
   ```

Thumbnails that 1.x stored in the bucket (`thumbnails_folder`) are no longer
used. You can delete them.

## Development and testing

Run the tests from the Redmine root, in the test environment:

```bash
RAILS_ENV=test bin/rails redmine:plugins:test NAME=redmine_amazon_s3
```

Unit and functional tests use an in-memory S3 built on the SDK's stubbed
client: no network access is needed.

### Live tests against SeaweedFS

The integration test can run against a real S3-compatible server:

```bash
docker run -d --name redmine-s3 -p 127.0.0.1:8333:8333 \
  -e AWS_ACCESS_KEY_ID=redmine -e AWS_SECRET_ACCESS_KEY=redmine-secret \
  chrislusf/seaweedfs server -dir=/data -s3 -s3.port=8333

AWS_ACCESS_KEY_ID=redmine AWS_SECRET_ACCESS_KEY=redmine-secret \
  aws --endpoint-url http://127.0.0.1:8333 s3 mb s3://redmine-test

RAILS_ENV=test S3_TEST_ENDPOINT=http://127.0.0.1:8333 \
  S3_TEST_ACCESS_KEY_ID=redmine S3_TEST_SECRET_ACCESS_KEY=redmine-secret \
  bin/rails test plugins/redmine_amazon_s3/test/integration
```

`S3_TEST_BUCKET` overrides the bucket name (default `redmine-test`). Each run
uses a random prefix.

## Changelog

### 2.0.0

Full rewrite for Redmine 6. Main changes from 1.x:

- Permission checks restored: 1.x made every attachment readable and skipped
  file checks.
- Real SHA256 digests instead of timestamps.
- An object shared by several attachments is no longer deleted when one of
  them is removed.
- Downloads send the CSP `sandbox` header, like core.
- Downloads are streamed instead of loaded in memory.
- Support for S3-compatible endpoints.
- Credentials are optional: the AWS default credential chain is used.
- Server-side encryption (`AES256`, `aws:kms`).
- Plugin id renamed from `amazon_s3` to `redmine_amazon_s3`.

## Credits

Maintained by [Ideematic](https://github.com/ideematic).

Version 1.x was written by Josef Hovad ([jhovad](https://github.com/jhovad)),
as a fork of [x3ro/redmine_amazon_s3](https://github.com/x3ro/redmine_amazon_s3),
itself forked from [ka8725/redmine_s3](https://github.com/ka8725/redmine_s3),
forked from the original [tigrish/redmine_s3](https://github.com/tigrish/redmine_s3).

## License

MIT. See the [`LICENSE`](LICENSE) file.
