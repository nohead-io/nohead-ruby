# frozen_string_literal: true

require_relative "test_helper"

class ImagesTest < Minitest::Test
  BASE = "https://images.nohead.io/insecure/plain/projects/0199f5c2-7b1e-7c3a-9d4f-2a6b8c0e1f3d" \
         "/assets/0199f5c2-8a2d-7e4b-b1c3-5d7e9f1a2b4c"
  Asset = Struct.new(:image_url)

  def at(options) = BASE.sub("/insecure/plain/", "/insecure/#{options}/plain/")

  def test_writes_the_options_before_the_source_and_the_format_after_it
    url = Nohead::Images.url(BASE, width: 800, height: 600, fit: "cover", gravity: "sm", dpr: 2, quality: 80,
                                   format: "webp", options: ["bl:2"])

    assert_equal "#{at('rs:fill:800:600/g:sm/dpr:2/q:80/bl:2')}@webp", url
    assert_equal at("rs:fit:320:0"), Nohead::Images.url(Asset.new(BASE), width: 320)
    assert_equal BASE, Nohead::Images.url(BASE)
    assert_equal "#{BASE}@avif", Nohead::Images.url("#{BASE}@png", format: "avif")
  end

  def test_refuses_options_that_would_break_the_path
    assert_raises(ArgumentError) { Nohead::Images.url(BASE, gravity: "fp:0.5/0.3") }
    assert_raises(ArgumentError) { Nohead::Images.url(BASE, options: ["bl:2@x"]) }
  end

  def test_refuses_what_is_not_a_ready_images_url
    assert_raises(ArgumentError) { Nohead::Images.url(Asset.new(nil)) }
    assert_raises(ArgumentError) { Nohead::Images.url("https://example.com/cat.png") }
  end
end
