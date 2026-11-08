# frozen_string_literal: true

module Nohead
  # Image renditions without a request. Image URLs are open: an image asset's
  # `image_url` serves the whole image, and imgproxy's open-source processing
  # options written into it transform it (listed at
  # https://docs.nohead.io/guides/images#supported-options). Any other, such as
  # imgproxy Pro's `sa`, `mc` or `co`, would answer 404, so `url` refuses it.
  #
  #   Nohead::Images.url(asset, width: 800, height: 600, fit: "cover", format: "webp")
  module Images
    FITS = { "contain" => "fit", "cover" => "fill", "fill" => "force" }.freeze

    # The processing options image URLs take, by short and long name.
    SUPPORTED = %w[
      rs resize s size rt resizing_type w width h height mw min-width mh min-height
      z zoom dpr el enlarge ex extend exar extend_aspect_ratio extend_ar g gravity c crop
      t trim pd padding ar auto_rotate rot rotate fl flip bg background bl blur
      sh sharpen pix pixelate q quality fq format_quality f format ext
      kcr keep_copyright scp strip_color_profile ph preserve_hdr
      eth enforce_thumbnail cb cachebuster exp expires fn filename
      att return_attachment pr preset
    ].to_set.freeze

    module_function

    # A rendition of an image (an asset, as an object or a Hash, or its `image_url`). fit: "contain"
    # (the default, also for nil) fits inside the box, "cover" fills it, cropping, "fill" stretches to it.
    # gravity: is what a crop keeps ("sm" for smart, "fp:0.5:0.3" for a focal
    # point); options: any other processing options, as written in a URL
    # (["bl:2"]). An empty string is the same as leaving an option out.
    def url(image, width: nil, height: nil, fit: "contain", format: nil, quality: nil, dpr: nil,
            gravity: nil, options: [])
      gravity, format = [gravity, format].map { |value| value unless value.to_s.empty? }
      options = [*options].reject { |option| option.to_s.empty? }
      base = base_of(image)
      check_options([gravity, *options])
      options.each { |option| check_supported(option.to_s) }
      at = base.index("/plain/")
      dpr = number(dpr)
      quality = number(quality)
      parts = [resize(fit, number(width), number(height)), ("g:#{gravity}" if gravity), ("dpr:#{dpr}" if dpr),
               ("q:#{quality}" if quality), *options].compact
      base[0...at] + parts.map { |part| "/#{part}" }.join + source(base[at..], format)
    end

    # rs:<fit>:<width>:<height>, or nothing without a size.
    def resize(fit, width, height)
      fit = fit.to_s.empty? ? "contain" : fit.to_s
      type = FITS.fetch(fit) { raise ArgumentError, "fit must be one of #{FITS.keys.join(', ')}" }
      "rs:#{type}:#{width || 0}:#{height || 0}" if width || height
    end
    private_class_method :resize

    # A number as the other SDKs write it (2.0 is 2), or nil for none (0 and "" are none).
    def number(value)
      return nil if value == ""
      return value unless value.is_a?(Numeric)
      return nil if value.zero?

      value.is_a?(Float) && value.finite? && value == value.round ? value.round : value
    end
    private_class_method :number

    def base_of(image)
      base = case image
             when String then image
             when Hash then image["image_url"] || image[:image_url]
             else image.image_url
             end
      raise ArgumentError, "Not a ready image: it has no image_url" if base.nil? || base.empty?
      raise ArgumentError, "Not a Nohead image URL: #{base}" unless base.include?("/plain/")

      base
    end
    private_class_method :base_of

    def check_options(values)
      bad = values.compact.find { |value| value.to_s.match?(%r{[/@?#]}) }
      raise ArgumentError, "Not an imgproxy option: #{bad}" if bad
    end
    private_class_method :check_options

    # Refuses an option image URLs don't take, naming it. The only preset is preview_url's.
    def check_supported(option)
      name, args = option.split(":", 2)
      preset = %w[pr preset].include?(name) && args != "preview"
      return if SUPPORTED.include?(name) && !preset

      raise ArgumentError, "#{preset ? option : name} isn't an option Nohead image URLs take (imgproxy Pro's, " \
                           "such as sa, mc or co, aren't available): https://docs.nohead.io/guides/images#supported-options"
    end
    private_class_method :check_supported

    # The source comes last; a format replaces any the URL already names.
    def source(source, format)
      format ? "#{source.sub(/@[a-z]+\z/, '')}@#{format}" : source
    end
    private_class_method :source
  end
end
