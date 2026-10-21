# frozen_string_literal: true

module Nohead
  # Image renditions without a request. Image URLs are open: an image asset's
  # `image_url` serves the whole image, and any of imgproxy's processing
  # options written into it transform it
  # (https://docs.imgproxy.net/usage/processing).
  #
  #   Nohead::Images.url(asset, width: 800, height: 600, fit: "cover", format: "webp")
  module Images
    FITS = { "contain" => "fit", "cover" => "fill", "fill" => "force" }.freeze

    module_function

    # A rendition of an image (an asset, or its `image_url`). fit: "contain"
    # fits inside the box, "cover" fills it, cropping, "fill" stretches to it.
    # gravity: is what a crop keeps ("sm" for smart, "fp:0.5:0.3" for a focal
    # point); options: any other processing options, as written in a URL
    # (["bl:2"]).
    def url(image, width: nil, height: nil, fit: "contain", format: nil, quality: nil, dpr: nil,
            gravity: nil, options: [])
      base = base_of(image)
      check_options([gravity, *options])
      at = base.index("/plain/")
      segments = [
        ("rs:#{FITS.fetch(fit.to_s)}:#{width || 0}:#{height || 0}" if width || height),
        ("g:#{gravity}" if gravity), ("dpr:#{dpr}" if dpr), ("q:#{quality}" if quality), *options
      ].compact
      base[0...at] + segments.map { |segment| "/#{segment}" }.join + source(base[at..], format)
    end

    def base_of(image)
      base = image.is_a?(String) ? image : image.image_url
      raise ArgumentError, "Not a ready image: it has no image_url" if base.nil? || base.empty?
      raise ArgumentError, "Not a Nohead image URL: #{base}" unless base.include?("/plain/")

      base
    end
    private_class_method :base_of

    def check_options(values)
      bad = values.compact.find { it.to_s.match?(%r{[/@?#]}) }
      raise ArgumentError, "Not an imgproxy option: #{bad}" if bad
    end
    private_class_method :check_options

    # The source comes last; a format replaces any the URL already names.
    def source(source, format)
      format ? "#{source.sub(/@[a-z]+\z/, '')}@#{format}" : source
    end
    private_class_method :source
  end
end
