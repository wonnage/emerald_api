##
# This class lets you look up purchase-related information
# on Emerald.

require 'faraday'
require 'faraday_middleware'
require 'hashie/mash'

class Emerald
  module Error
    class PackageNotFound < RuntimeError; end
    class VariantNotFound < RuntimeError; end
  end

  # This by all means *should* be a hashie::mash as well. But that library
  # helpfully converts any nested hash-like objects into mashes,
  # regardless of their current class. So there's no way to store different
  # subclasses of mashes (e.g coupon, variant) within a mash - if package was a
  # mash, package.variants would get converted from an array of Emerald::Variant
  # mashes to an array of Emerald::Package variants.
  class Emerald::Package
    attr_accessor :active, :code, :cost_in_cents, :description, :name, :variants
    # Turn the variants array into Variant objects
    def initialize(attrs)
      if attrs.is_a? Emerald::Package
        attrs = attrs.as_json
      end
      attrs.each {|k,v| self.send("#{k}=", v) if self.respond_to?("#{k}=")}
      if @variants
        # Hashie doesn't really like being subclassed, if you couldn't tell
        self.variants = self.variants.map {|var| Emerald::Variant.new(var) }
      end
    end
    def find_variant_by_code(variant_code)
      self.variants.detect {|v| v.code == variant_code}
    end

    def ==(other)
      self.object_id == other.object_id || self.as_json == other.as_json
    end

    def active?
      !!self.active
    end
  end

  # These classes help us identify what a particular hashie is
  class Emerald::Coupon < Hashie::Mash; end
  class Emerald::Variant < Hashie::Mash; end

  class Purchase
    attr_accessor :package, :variants, :coupon, :organization, :signature

    # +package_or_package_code+
    # +options+: organization, variants, and coupon_code
    #
    def initialize(package_or_package_code, options={})
      self.package = package_or_package_code
      self.organization = options[:organization]

      self.variants = options[:variants] || []
      self.coupon = options[:coupon_code]
    end

    def ==(other)
      self.object_id == other.object_id || self.as_json == other.as_json
    end

    def variants=(variants)
      if variants.is_a?(Array)
        @variants = variants
        inflate_variant_codes
        @variants
      else
        raise TypeError, 'variants must be an array'
      end
    end

    def variants
      # Make sure variants are variant objects
      # This is necessary so doing something like purchase.variants << 'asdf'
      # will work as expected.
      inflate_variant_codes
      @variants
    end

    def package=(package_or_package_code)
      if package_or_package_code.is_a? Package
        @package = package_or_package_code
      elsif package = Emerald.find_package(package_or_package_code)
        @package = package
      else
        raise Emerald::Error::PackageNotFound, package_or_package_code
      end
    end

    def coupon=(coupon_or_coupon_code)
      if coupon_or_coupon_code.is_a?(Coupon) || coupon_or_coupon_code.nil? # no modification needed
        @coupon = coupon_or_coupon_code
      else
        coupon = Emerald.find_coupon(coupon_or_coupon_code, self) # returns nil if coupon not found
        if coupon
          # Can't discount more than the purchase is worth
          coupon.discount_in_cents = [coupon.discount_in_cents, self.subtotal_in_cents].min
        end
        @coupon = coupon
      end
    end

    def subtotal_in_cents
      self.package.cost_in_cents + self.variants.inject(0) {|sum, v| sum += v.cost_in_cents}
    end

    def total_in_cents
      if self.coupon
        self.subtotal_in_cents - self.coupon.discount_in_cents
      else
        self.subtotal_in_cents
      end
    end

    def total
      self.total_in_cents && self.total_in_cents / 100.0
    end

    def subtotal
      self.subtotal_in_cents && self.subtotal_in_cents / 100.0
    end

    def as_json(options={})
      super.merge(subtotal_in_cents: subtotal_in_cents,
                  subtotal: subtotal,
                  total_in_cents: total_in_cents,
                  total: total)
    end

    private
    def inflate_variant_codes # convert variant codes to variant objects
      @variants = @variants.map do |v|
        if v.is_a? Variant
          v
        else
          variant = @package.find_variant_by_code(v)
          raise Emerald::Error::VariantNotFound, v.to_s unless variant
          variant
        end
      end
    end
  end

  class << self
    attr_accessor :url
  end

  private
  def self.connection
    if self.url.nil?
      raise "You need to set Emerald.url before using this library!"
    else
      conn = Faraday.new(:url => self.url) do |builder|
        builder.use FaradayMiddleware::Mashify
        builder.use FaradayMiddleware::ParseJson
        builder.adapter Faraday.default_adapter
      end
    end
  end

  public
  ##
  # Looks up a package by its code ("product key" on Emerald).
  # Returns nil if it's not found.
  #
  def self.find_package(code)
    begin
      resp = connection.get("/emerald_api/packages/show/#{code}")
      if resp.success?
        Package.new(resp.body)
      else
        nil
      end
    rescue Faraday::Error::ConnectionFailed,Faraday::Error::ParsingError
      nil
    end
  end

  ##
  # Lists all packages on Emerald.
  #
  def self.packages
    begin
      resp = connection.get("/emerald_api/packages/index")
      if resp.success?
        resp.body.map {|package| package.cost = package.cost_in_cents / 100.0; Package.new(package)}
      else
        nil
      end
    rescue Faraday::Error::ConnectionFailed,Faraday::Error::ParsingError
      nil
    end
  end

  ##
  # Looks up a coupon by its code and product key. You need
  # to pass in an object that responds to #code as the `purchase`
  # argument.
  #
  def self.find_coupon(code, purchase)
    begin
      resp = connection.get("/emerald_api/coupons/show/#{code}") do |req|
        req.params[:product_key] = purchase.package.code
        req.params[:organization] = purchase.organization
      end
      if resp.success?
        Coupon.new(resp.body)
      else
        nil
      end
    rescue Faraday::Error::ConnectionFailed,Faraday::Error::ParsingError
      nil
    end
  end
end

