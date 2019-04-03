
puts "LOADING JRUBY HACKS"
# Looking into support adding typemap support to ARJDBC but it has not been
# written yet. Hoping these coercions do not take app down.
module PG
  class SimpleDecoder
  end

  class BasicTypeMapForResults
    def rm_coder(a, b)
    end

    def add_coder(d)
    end

    def default_type_map=(a)
    end
  end

  class TypeMapInRuby
  end

  class ReadOnlySqlTransaction
  end

  class Connection
  end
end

# No modern santize
class Sanitize
  module Config
    def self.merge(a, b)
    end
    def self.freeze_config(a)
    end
  end
end

ONEBOX = {}

module Onebox
  module Engine
    class FlashVideoOnebox
      def self.matches_regexp(re)
      end
    end
  end
end
