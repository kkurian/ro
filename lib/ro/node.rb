module Ro
  class Node
    fattr :root
    fattr :path
    fattr :type
    fattr :loaded
    fattr :fields

    def initialize(path)
      @path = Ro.realpath(path.to_s)
      @id   = File.basename(@path)
      @slug = Slug.for(@id)
      @type = File.basename(File.dirname(@path))
      @root = Ro::Root.new(File.dirname(File.dirname(@path)))
      @loaded = false
      @loading = false
      @attributes = Map.new
      @fields = Map.new
    end

    attr_reader :id

    def _id
      @id
    end

    def type
      attributes[:type] || @type
    end

    def _type
      @type
    end

    def path
      attributes[:path] || @path
    end

    def _path
      @path
    end

    def slug
      attributes[:slug] || @slug
    end

    def _slug
      @slug
    end

    def identifier
      "#{_type}/#{_id}"
    end

    def hash
      identifier.hash
    end

    def ==(other)
      attributes == other.attributes
    end

    def inspect
      identifier
    end

    def to_s
      inspect
    end

    def basename
      name
    end

    def node
      self
    end

    def ro(*args, &block)
      Ro::Root.new(*args, &block).nodes
    end

    def get(*args)
      attributes.get(*args)
    end

    def [](*args)
      attributes.get(*args)
    end

    def asset_path(*_args)
      File.join(relative_path, 'assets')
    end

    def asset_dir
      File.join(path, 'assets')
    end

    def asset_paths
      Dir.glob("#{asset_dir}/**/**").select { |entry| test('f', entry) }.sort
    end

    def assets
      asset_paths.map { |path| Asset.new(node, path) }
    end

    def asset_urls
      assets.map(&:url)
    end

    def asset_for(*args)
      options = Map.options_for!(args)

      path_info = Ro.relative_path_for(args)

      path = File.join(@path.to_s, 'assets', path_info)

      glob = path_info.gsub(/[_-]/, '[_-]')

      globs =
        [
          File.join(@path.to_s, 'assets', "#{glob}"),
          File.join(@path.to_s, 'assets', "#{glob}*"),
          File.join(@path.to_s, 'assets', "**/#{glob}*")
        ]

      candidates = globs.map { |glob| Dir.glob(glob, ::File::FNM_CASEFOLD) }.flatten.compact.uniq.sort

      case candidates.size
      when 0
        raise ArgumentError, "no asset matching #{globs.inspect}"
      else
        path = candidates.last
      end

      Asset.new(node, path)
    end

    def asset_for?(*args, &block)
      asset_for(*args, &block)
    rescue StandardError
      nil
    end

    def url_for(relative_path, options = {})
      path = File.expand_path(File.join(node.path, relative_path.to_s))
      raise ArgumentError, "#{relative_path.inspect} -- DOES NOT EXIST" unless test('e', path)

      Ro.url_for(node.relative_path, relative_path.to_s, options)
    end

    def url(options = {})
      Ro.url_for(node.relative_path, options)
    end

    def relative_path
      re = /^#{Regexp.escape(Ro.root)}/
      @path.to_s.gsub(re, '')
    end

    def source_for(*args)
      key = Ro.relative_path_for(:assets, :source, args).split('/')
      get(key)
    end

    def method_missing(method, *args, &block)
      super if method.to_s == 'to_ary'

      Ro.log "Ro::Node(#{identifier})#method_missing(#{method.inspect}, #{args.inspect})"

      key = method.to_s

      return @attributes[key] if @attributes.has_key?(key)

      _load do
        return(
          if @attributes.has_key?(key)
            @attributes[key]
          else
            super
          end
        )
      end
    end

    def attributes
      _load { @attributes }
    end

    attr_writer :attributes

    def as_json(*_args)
      attributes.to_hash.merge(meta_attributes)
    end

    def meta_attributes
      {
        '_identifier' => identifier,
        '_type' => _type,
        '_id' => _id,
        '_url' => url,
        '_asset_urls' => asset_urls
      }
    end

    def instance_eval(*args, &block)
      _load { super }
    end

    def related(*args, &block)
      _load do
        related = @attributes.get(:related) || Map.new
        nodes = List.new(root)
        list = root.nodes
        which = Ro.list_of_strings(args)

        related.each do |relationship, value|
          next if !which.empty? && !which.include?(relationship.to_s)

          type, names =
            case value
            when Hash
              value.to_a.first
            else
              [relationship, value]
            end

          names = Ro.list_of_strings(names)

          names.each do |name|
            identifier = "#{type}/#{name}"
            node = list.index[identifier]
            node._load { nodes.add(node) }
          end
        end

        if block.nil?
          nodes

        elsif block
          nodes.where(&block)
        end
      end
    end

    def reload(&block)
      @loaded = false
      _load(&block)
    end

    def loaded
      attributes
    end

    def load!(&block)
      _load(&block)
    end

    def _load(&block)
      unless @loaded
        if @loading
          return(block ? block.call : :loading)
        end

        @loading = true
        @loaded = _load_from_cache_or_disk
        @loading = false
      end

      block ? block.call : @loaded
    end

    def _load_from_cache_or_disk
      # return :cache if _load_from_cache
      return :disk if _load_from_disk

      nil
    end

    # FIXME: - think about this... since mutual deps can exist....  maybe NO cache.  KISS
    def _load_from_cache
      cache_key = _cache_key

      cached = Ro.cache && Ro.cache.read(cache_key)

      return unless cached

      Ro.log "loading #{identifier} from cache"

      @attributes = Map.new.update(cached)
    end

    def _load_from_disk
      cache_key = _cache_key

      Ro.log "loading #{identifier} from disk"

      @attributes = Map.new

      _load_attributes_yml
      _load_attribute_files
      # FIXME
      # _load_sources
      # _load_assets

      Ro.cache && Ro.cache.write(cache_key, @attributes)
    end

    def _load_attributes_yml
      return unless test('s', _attributes_yml)

      buf = IO.binread(_attributes_yml)
      data = YAML.load(buf)
      data = data.is_a?(Hash) ? data : { '_' => data }

      @attributes.update(data)

      %w[assets].each do |key|
        raise ArgumentError, "attributes.yml may not contain the key '#{key}'" if @attributes.has_key?(key)
      end

      @attributes
    end

    def _load_attribute_files
      glob = File.join(@path, '**/**')

      cd = CycleDector.new(self)

      Dir.glob(glob) do |path|
        next if test('d', path)

        basename = File.basename(path)
        next if basename == 'attributes.yml'

        relative_path = Ro.relative_path(path, to: @path)
        next if relative_path =~ %r{^assets/}

        # basename = File.basename(path)
        # next if basename == 'index.json'
        # FIXME

        path_info, ext = key = relative_path.split('.', 2)

        key = path_info.split('/')

        promise = cd.promise(key) do
          html = Ro.render(path, node)
          html = Ro.expand_asset_urls(html, node)
          # @attributes.set(key => html)
        end

        @attributes.set(key => promise)

        # html = Ro.render(path, node)
        # html = Ro.expand_asset_urls(html, node)
        # @attributes.set(key => html)
      end

      # cd.resolve
    end

    class CycleDector
      attr_accessor :node, :promises, :keys, :key

      def initialize(node)
        @node = node
        @promises = []
        @keys = []
        @key = []
      end

      def cd
        self
      end

      def promise(key, &block)
        promise = Promise.new(cd, key, &block)
      ensure
        keys.push(key)
        promises.push(promise)
      end

      def resolve
        promises.each { |promise| promise.resolve }
      end

      class Promise < BasicObject
        def initialize(cd, key, &block)
          @cd = cd
          @key = key
          @block = block
          @resolved = nil
        end

        def is_a?(other)
          other.instance_of?(Promise)
        end

        def resolve
          return @resolved if @resolved

          if @cd.key.include?(@key)
            cycle = @cd.key + [@key]
            Ro.error! "rendering #{@node.identifier} cycles on #{cycle.join ' -> '}"
          end

          @cd.key.push(@key)

          begin
            @resolved = @block.call.to_s
          ensure
            @cd.key.pop
          end
        end

        def call
          resolve
        end

        def to_s
          call
        end

        def inspect
          call
        end
      end
    end

    def _load_sources
      glob = File.join(@path, 'assets/source/*')

      Dir.glob(glob) do |path|
        next if test('d', path)

        basename = File.basename(path)
        key, ext = basename.split('.', 2)

        next if basename == 'attributes.yml'

        value = Ro.render_source(path, node)

        @attributes.set([:assets, :source, basename] => value)
      end
    end

    def _load_assets
      @attributes.update(asset_urls)
    end

    def asset_urls
      {}.tap do |asset_urls|
        assets.each do |asset|
          key = asset.relative_path
          value = asset.url
          asset_urls[key] = value
        end
      end
    end

    def _cache_key
      glob = File.join(@path, '**/**')

      entries = []

      Dir.glob(glob) do |entry|
        stat =
          begin
            File.stat(entry)
          rescue StandardError
            next
          end

        timestamp = [stat.ctime, stat.mtime].max
        relative_path = Ro.relative_path(entry, to: @path)
        entries.push([relative_path, timestamp.iso8601(2)])
      end

      fingerprint = entries.map { |pair| pair.join('@') }.join(', ')

      md5 = Ro.md5(fingerprint)

      [@path, md5]
    end

    def _attributes_yml
      File.join(@path, 'attributes.yml')
    end
  end
end
