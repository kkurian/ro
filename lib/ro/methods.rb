module Ro
  class << Ro
    # cast
    # |
    # v
    def cast(which, arg, *args)
      which = which.to_s
      values = [arg, *args].join(',').scan(/[^,\s]+/)

      list_of = which.match(/^list_of_(.+)$/)
      which = list_of[1] if list_of

      cast = casts.fetch(which.to_s.to_sym)

      if list_of
        values.map { |value| cast[value] }
      else
        raise ArgumentError, "too many values in #{values.inspect}" if values.size > 1

        value = values.first
        cast[value]
      end
    end

    def casts
      {
        string: proc { |value| String(value) },
        int: proc { |value| Integer(value.to_s) },
        string_or_nil: proc { |value| String(value).empty? ? nil : String(value) },
        url: proc { |value| Ro.normalize_url(value) },
        array: proc { |value| String(value).scan(/[^,:]+/) },
        bool: proc { |value| String(value) !~ /^\s*(f|false|off|no|0){0,1}\s*$/ },
        path: proc { |value| Ro.path_for(value) }
      }
    end

    # url utils
    # |
    # v

    def url_for(path, *args)
      options = Map.extract_options!(args)
      base = options[:base] || options[:url] || Ro.config.url

      path = path_for(path, *args)

      fragment = options.delete(:fragment)
      query = options.delete(:query) || options

      uri = URI.parse(base.to_s)
      uri.path = absolute_path_for(uri.path, path)
      uri.path = '' if uri.path == '/'

      uri.query = query_string_for(query) unless query.empty?

      uri.fragment = fragment if fragment

      uri.to_s
    end

    def query_string_for(hash, options = {})
      options = Map.for(options)
      escape = options.has_key?(:escape) ? options[:escape] : true
      pairs = []
      esc = escape ? proc { |v| CGI.escape(v.to_s) } : proc { |v| v.to_s }
      hash.each do |key, values|
        key = key.to_s
        values = [values].flatten
        values.each do |value|
          value = value.to_s
          pairs << if value.empty?
                     [esc[key]]
                   else
                     [esc[key], esc[value]].join('=')
                   end
        end
      end
      pairs.replace(pairs.sort_by { |pair| pair.size })
      pairs.join('&')
    end

    def normalize_url(url)
      uri = URI.parse(url.to_s).normalize
      uri.path = absolute_path_for(uri.path)
      uri.to_s
    end

    # misc utils
    # |
    # v
    def md5(string)
      Digest::MD5.hexdigest(string)
    end

    # log utils
    # |
    # v
    attr_accessor :logger

    def log(*args, &block)
      level = nil

      level = if args.size == 0 || args.size == 1
                :info
              else
                args.shift.to_s.to_sym
              end

      @logger && @logger.send(level, *args, &block)
    end

    def log!
      Ro.logger =
        ::Logger.new(STDERR).tap do |logger|
          logger.level = ::Logger::INFO
        end
    end

    def debug!
      Ro.logger =
        ::Logger.new(STDERR).tap do |logger|
          logger.level = ::Logger::DEBUG
        end
    end

    def error!(message, context = nil)
      error = Error.new(message, context)

      begin
        raise error
      rescue Error
        backtrace = error.backtrace || []
        error.set_backtrace(backtrace[1..-1])
        raise
      end
    end

    # name utils
    # |
    # v
    def name_for(name)
      Slug.for(File.basename(name.to_s))
    end

    def slug_for(*args, &block)
      options = Map.options_for!(args)
      options[:join] = '-' unless options.has_key?(:join)
      args.push(options)
      Slug.for(*args, &block)
    end

    # template utils
    # |
    # v
    def template(method = :tap, *args, &block)
      Template.send(method, *args, &(block || proc {}))
    end

    def render(path, context)
      Template.render(path, context: context)
    end

    def render_src(path, context)
      Template.render_src(path, context: context)
    end

    # url expansion utils
    # |
    # v
    def expand_asset_values(hash, node)
      src = Map.for(hash)
      dst = Map.new

      re = %r{\A(?:[.]/)?(assets/[^\s]+)\s*\z}

      src.depth_first_each do |key, value|
        next unless value.is_a?(String)

        if (match = re.match(value.strip))
          path = match[1].strip
          url = node.url_for(path)
          value = url
        end

        dst.set(key, value)
      end

      dst.to_hash
    end

    @@EXPAND_ASSET_URL_STRATEGIES = %i[accurate_expand_asset_urls sloppy_expand_asset_urls]

    def expand_asset_urls(html, node)
      last = @@EXPAND_ASSET_URL_STRATEGIES.size - 1

      @@EXPAND_ASSET_URL_STRATEGIES.each_with_index do |strategy, i|
        return send(strategy, html, node)
      rescue Object => e
        raise if i == last

        Ro.log(e)
      end

      Ro.error! "could not expand assets via #{@@EXPAND_ASSET_URL_STRATEGIES.join(', ')}"
    end

    def accurate_expand_asset_urls(html, node)
      doc = REXML::Document.new('<__ro__>' + html + '</__ro__>')

      doc.each_recursive do |element|
        next unless element.respond_to?(:attributes)

        src = {}
        element.attributes.each do |key, value|
          src[key] = value
        end

        dst = expand_asset_values(src, node)

        dst.each do |k, v|
          element.attributes[k] = v
        end
      end

      doc.to_s.tap do |xml|
        xml.sub!(/^\s*<.?__ro__>\s*/, '')
        xml.sub!(/\s*<.?__ro__>\s*$/, '')
        xml.strip!
      end
    end

    def sloppy_expand_asset_urls(html, node)
      html.to_s.gsub(%r{\s*=\s*['"](?:[.]/)?assets/[^'"\s]+['"]}) do |match|
        path = match[%r{assets/[^'"\s]+}]
        url = node.url_for(path)
        "='#{url}'"
      end
    end

    # path utils
    #
    def path_for(arg, *args)
      Path.for(arg, *args)
    end

    def absolute_path_for(arg, *args)
      Path.absolute(arg, *args)
    end
  end
end
