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
      #
      # With an `idempotency_key`, running the same upload again resumes it:
      # the key starts the upload, and an asset that is already `ready` is
      # returned without sending the bytes again. Once the upload's URL has
      # expired (`upload.expires_at`), it raises UploadError: start over with
      # a new key.
      def upload(file, filename: nil, content_type: nil, byte_size: nil, idempotency_key: nil)
        source = UploadSource.new(file, filename: filename, content_type: content_type,
                                        byte_size: byte_size)
        begin
          created = create_upload(filename: source.filename, content_type: source.content_type,
                                  byte_size: source.byte_size, idempotency_key: idempotency_key)
          # A replayed start returns the first run's asset, which may be done.
          if idempotency_key
            current = get(created.id)
            return current if current.status == "ready"
            # The key replays the first run's upload URL, which expires sooner.
            if created.upload.expires_at <= Time.now
              raise UploadError, "The upload of #{source.filename} expired: start it again with a new idempotency_key"
            end
          end
          upload = created.upload
          response = @client.put_upload(upload.url, upload["method"], upload.headers.to_h, source)
        ensure
          source.close
        end
        unless response.status.between?(200, 299)
          raise UploadError.new("Storage refused the upload of #{source.filename} (#{response.status})",
                                response.status)
        end
        complete(created.id)
      end

      # The first step of an upload: a `pending` asset with its `upload`, a
      # presigned URL to PUT the bytes to (for example from a browser). Then
      # `complete` it.
      def create_upload(idempotency_key: nil, **params)
        @client.request("assets_upload", body: body_of(params), idempotency_key: idempotency_key)
      end

      # Checks an uploaded file and marks the asset `ready`.
      def complete(asset, idempotency_key: nil)
        @client.request("assets_complete", path: { asset_id: asset }, idempotency_key: idempotency_key)
      end

      # `q` finds assets whose filename or alt text has every word, ignoring
      # case ("hero jpg" finds `Hero-banner.jpg`). `kind` lists only assets of
      # a kind ("image", "video", "audio", "document" or "other"), or of
      # several (%w[image video]).
      #
      # `content_type` lists only assets of a MIME type or `type/*` wildcard
      # ("image/*"), or of several (["image/*", "application/pdf"]), for
      # example the ones an asset field accepts (its `accepted_types`; an
      # empty list, like a field's, means any type).
      def list(q: nil, kind: nil, content_type: nil, deleted: nil, limit: nil, cursor: nil)
        filter = { kind: one_or_in(kind), content_type: one_or_in(content_type), deleted: deleted }
        @client.paginate("assets_list", query: { q: q, filter: filter, limit: limit, cursor: cursor })
      end

      def get(asset)
        @client.request("assets_get", path: { asset_id: asset })
      end

      # Renames the asset (`filename:`) or sets its `alt:` text (nil or ""
      # clears it). The file itself can't change: upload a new asset for that.
      # `alt` is the default wherever the asset is used. A deleted asset is a
      # ConflictError: restore it first.
      def update(asset, idempotency_key: nil, **params)
        @client.request("assets_update", path: { asset_id: asset }, body: body_of(params),
                                         idempotency_key: idempotency_key)
      end

      # Soft-deletes the asset: restore brings it back until its `purge_after`,
      # when the file is purged.
      def delete(asset, idempotency_key: nil)
        @client.request("assets_delete", path: { asset_id: asset }, idempotency_key: idempotency_key)
      end

      def restore(asset, idempotency_key: nil)
        @client.request("assets_restore", path: { asset_id: asset }, idempotency_key: idempotency_key)
      end

      # Deletes a deleted asset for good, now instead of at its `purge_after`,
      # and returns it as it was. It can't be restored, and its image
      # URLs stop working. Raises ConflictError if the asset isn't deleted.
      def purge(asset, idempotency_key: nil)
        @client.request("assets_purge", path: { asset_id: asset }, idempotency_key: idempotency_key)
      end

      # Where the asset is used: how many undeleted records use it (`records`),
      # how many of those are published (`published`), and the 10 most
      # recently updated with the fields they use it in (`uses`). Needs
      # `records:read` too.
      def usage(asset)
        @client.request("assets_usage", path: { asset_id: asset })
      end
    end
  end
end
