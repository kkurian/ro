begin
  require 'active_model'
  require 'active_support'
  require 'active_support/core_ext/string/inflections.rb'
rescue LoadError => e
  abort "you need to add the 'active_model' and 'active_support' gems to use Ro::Model"
end

module Ro
  class Model
  #
    extend ActiveModel::Naming
    extend ActiveModel::Translation
    include ActiveModel::Validations
    include ActiveModel::Conversion

  #
    Fattr(:collection){ default_collection_name }
    Fattr(:default_collection_name){ self.name.to_s.split(/::/).last.underscore.pluralize } 
    Fattr(:root){ Ro.root }
    Fattr(:prefix){ File.join(root, collection) }

    def Model.nodes(*args, &block)
      root.nodes.send(collection)
    end

    def Model.all(*args, &block)
      nodes
    end

    def Model.first
      all.first
    end

    def Model.last
      all.last
    end

    def Model.find(*args, &block)
      models_for(nodes.find(*args, &block))
    end

    def Model.paginate(*args, &block)
      models_for(nodes.paginate(*args, &block))
    end

    def Model.models_for(result)
      case result
        when Array
          Array(result).flatten.compact.map{|attributes| new(attributes)}
        else
          new(result)
      end
    end

  #
    attr_accessor(:node)

    def initialize(*args, &block)
      attributes = Map.options_for!(args)

      node = args.detect{|arg| arg.is_a?(Node)}
      if node
        @node = node
      else
        path = File.join(prefix, ':new')
        node = Node.new(path)
        @node = node
      end
    end

    def attributes
      @node.attributes
    end

  #
    def prefix
      self.class.prefix
    end

    def directory
      File.join(prefix, id)
    end

  #
    def method_missing(method, *args, &block)
      node.send(method, *args, &block)
    end
  end
end




if __FILE__ == $0

  ENV['RO_ROOT'] = '../sample_ro_data'

  class Person < Ro::Model

    #field(:first_name, :type => :string)
    
  end

  p Person.collection
  p Person.all
  p Person.find(:ara).attributes
  ara = Person.find(:ara)

  p ara.url_for(:ara_glacier)

  p Person.paginate(:per => 2, :page => 1)
  p Person.name

  p Person.prefix
  p ara.id
  p ara.first_name

  require 'pry'
  binding.pry

end
