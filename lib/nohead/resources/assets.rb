# frozen_string_literal: true

module Nohead
  module Resources
    # Files of the key's project. `asset` is an asset ID ("ast_...").
    class Assets < Resource
      # Uploads a file and returns the `ready` asset: creates the upload, sends
      # the bytes straight to storage, then completes it (which checks the
      # file). `file` is a path or an IO; for bytes, pass StringIO.new(bytes).
      # Raises UploadError if storage refuses the bytes, and ValidationError if
      # the file fails the checks.
      def upload(file, filename: nil, content_type: nil, byte_size: nil, idempotency_key: nil)
        source = UploadSource.new(file, filename: filename, content_type: content_type,
                                        byte_size: byte_size)
        begin
          created = create_upload(filename: source.filename, content_type: source.content_type,
                                  byte_size: source.byte_size, idempotency_key: idempotency_key)
          upload = created.upload
          response = @client.put_upload(upload.url, upload["method"], upload.headers.to_h, source)
        ensure
          source.close
        end
        unless response.status.between?(200, 299)
          raise UploadError.new("Storage refused the upload of #{source.filename} (#{response.status})",
                                response.status)
        end
        complete(created.asset.id)
      end

      # The first step of an upload: a `pending` asset and a presigned URL to
      # PUT the bytes to (for example from a browser). Then `complete` it.
      def create_upload(idempotency_key: nil, **params)
        @client.request("assets_upload", body: params, idempotency_key: idempotency_key)
      end

      # Checks an uploaded file and marks the asset `ready`.
      def complete(asset, idempotency_key: nil)
        @client.request("assets_complete", path: { asset_id: asset }, idempotency_key: idempotency_key)
      end

      def list(deleted: nil, limit: nil, cursor: nil)
        @client.paginate("assets_list", query: { deleted: deleted, limit: limit, cursor: cursor })
      end

      def get(asset)
        @client.request("assets_get", path: { asset_id: asset })
      end

      # Soft-deletes the asset; the file is purged after 30 days.
      def delete(asset, idempotency_key: nil)
        @client.request("assets_delete", path: { asset_id: asset }, idempotency_key: idempotency_key)
      end

      def restore(asset, idempotency_key: nil)
        @client.request("assets_restore", path: { asset_id: asset }, idempotency_key: idempotency_key)
      end

      # A signed, cacheable URL of an image rendition (`url`).
      def image_url(asset, width: nil, height: nil, fit: nil, format: nil, quality: nil)
        @client.request("assets_image_url", path: { asset_id: asset }, query: {
                          width: width, height: height, fit: fit, format: format, quality: quality
                        })
      end

      # A 15-minute link to download the original file (`url`).
      def download_url(asset)
        @client.request("assets_download_url", path: { asset_id: asset })
      end
    end
  end
end
