require "redis"
require "json"

module LuckyCache
  struct RedisStore < BaseStore
    SCAN_BATCH_SIZE = 100

    private getter redis : Redis::Client
    private getter prefix : String

    def initialize(@redis : Redis::Client = Redis::Client.new, @prefix : String = "lucky_cache:")
    end

    def read(key : CacheKey) : CacheItem?
      if data = redis.get(prefixed_key(key))
        deserialize_cache_item(data)
      end
    end

    def write(key : CacheKey, *, expires_in : Time::Span = LuckyCache.settings.default_duration, &)
      data = yield

      # For Redis storage, we need to check if the data is serializable
      # Custom Cachable objects cannot be serialized to JSON without custom serialization logic
      unless serializable?(data)
        raise ArgumentError.new("RedisStore cannot serialize custom Cachable objects. Use MemoryStore for custom objects or store serializable representations (Hash, NamedTuple, JSON::Any).")
      end

      validate_expires_in!(expires_in)

      expiration = Time.utc + expires_in
      serialized = serialize_cache_item(data, expires_in, expiration)

      redis.set(prefixed_key(key), serialized, ex: expires_in)

      data
    end

    def delete(key : CacheKey)
      result = redis.del(prefixed_key(key))
      result > 0 ? result : nil
    end

    def flush : Nil
      batch = [] of String

      each_prefixed_key do |key|
        batch << key
        if batch.size >= SCAN_BATCH_SIZE
          redis.del(batch)
          batch.clear
        end
      end

      redis.del(batch) unless batch.empty?
    end

    def fetch(key : CacheKey, *, as : Array(T).class, expires_in : Time::Span = LuckyCache.settings.default_duration, &) forall T
      if cache_item = read(key)
        case value = cache_item.value
        when Array
          value.map { |v| v.as(T) }
        else
          raise TypeCastError.new("Expected Array but got #{value.class}")
        end
      else
        write(key, expires_in: expires_in) { yield }
      end
    end

    def fetch(key : CacheKey, *, as : T.class, expires_in : Time::Span = LuckyCache.settings.default_duration, &) forall T
      if cache_item = read(key)
        cache_item.value.as(T)
      else
        write(key, expires_in: expires_in) { yield }
      end
    end

    def size : Int32
      count = 0
      each_prefixed_key { count += 1 }
      count
    end

    private def serializable?(value) : Bool
      case value
      when String, Int32, Int64, Float64, Bool, Time, UUID, JSON::Any
        true
      when Array
        value.all? { |v| serializable?(v) }
      else
        false
      end
    end

    private def prefixed_key(key : CacheKey) : String
      "#{prefix}#{key}"
    end

    private def validate_expires_in!(expires_in : Time::Span) : Nil
      if expires_in.total_milliseconds < 1
        raise ArgumentError.new("expires_in must be at least 1 millisecond")
      end
    end

    private def each_prefixed_key(& : String ->) : Nil
      redis.scan_each(match: "#{prefix}*", count: SCAN_BATCH_SIZE) do |key|
        yield key
      end
    end

    private def serialize_cache_item(value : CachableTypes, expires_in : Time::Span, expiration : Time) : String
      {
        "value"         => serialize_value(value),
        "expires_in_ms" => expires_in.total_milliseconds.to_i64,
        "expires_at_ms" => expiration.to_unix_ms,
        "type"          => determine_type(value),
      }.to_json
    end

    private def deserialize_cache_item(data : String) : CacheItem?
      parsed = JSON.parse(data)

      type_name = parsed["type"].as_s
      value_json = parsed["value"]
      expires_in = milliseconds_to_span(parsed["expires_in_ms"].as_i64)
      expiration = Time.unix_ms(parsed["expires_at_ms"].as_i64)
      value = deserialize_value(value_json, type_name)

      return nil if expiration <= Time.utc

      CacheItem.new(value, expires_in, expiration)
    rescue
      nil
    end

    private def milliseconds_to_span(milliseconds : Int64) : Time::Span
      Time::Span.new(nanoseconds: milliseconds * 1_000_000)
    end

    private def serialize_value(value : CachableTypes) : JSON::Any
      case value
      when Array
        serialize_array_value(value)
      else
        serialize_scalar_value(value)
      end
    end

    private def serialize_scalar_value(value : CachableTypes) : JSON::Any
      case value
      when String
        JSON::Any.new(value)
      when Int32
        JSON::Any.new(value.to_i64)
      when Int64
        JSON::Any.new(value)
      when Float64
        JSON::Any.new(value)
      when Bool
        JSON::Any.new(value)
      when Time
        JSON::Any.new(value.to_rfc3339)
      when UUID
        JSON::Any.new(value.to_s)
      when JSON::Any
        value
      else
        raise ArgumentError.new("Cannot serialize value of type #{value.class}")
      end
    end

    private def serialize_array_value(value : Array) : JSON::Any
      case value
      when Array(String)
        JSON::Any.new(value.map { |v| JSON::Any.new(v) })
      when Array(Int32)
        JSON::Any.new(value.map { |v| JSON::Any.new(v.to_i64) })
      when Array(Int64)
        JSON::Any.new(value.map { |v| JSON::Any.new(v) })
      when Array(Float64)
        JSON::Any.new(value.map { |v| JSON::Any.new(v) })
      when Array(Bool)
        JSON::Any.new(value.map { |v| JSON::Any.new(v) })
      else
        raise ArgumentError.new("Cannot serialize value of type #{value.class}")
      end
    end

    private def deserialize_value(json : JSON::Any, type_name : String) : CachableTypes
      if type_name.starts_with?("Array(")
        deserialize_array_value(json, type_name)
      else
        deserialize_scalar_value(json, type_name)
      end
    end

    private def deserialize_scalar_value(json : JSON::Any, type_name : String) : CachableTypes
      case type_name
      when "String"
        json.as_s
      when "Int32"
        json.as_i
      when "Int64"
        json.as_i64
      when "Float64"
        json.as_f
      when "Bool"
        json.as_bool
      when "Time"
        Time.parse_rfc3339(json.as_s)
      when "UUID"
        UUID.new(json.as_s)
      when "JSON::Any"
        json
      else
        raise ArgumentError.new("Cannot deserialize type #{type_name}")
      end
    end

    private def deserialize_array_value(json : JSON::Any, type_name : String) : CachableTypes
      case type_name
      when "Array(String)"
        json.as_a.map(&.as_s)
      when "Array(Int32)"
        json.as_a.map(&.as_i)
      when "Array(Int64)"
        json.as_a.map(&.as_i64)
      when "Array(Float64)"
        json.as_a.map(&.as_f)
      when "Array(Bool)"
        json.as_a.map(&.as_bool)
      else
        raise ArgumentError.new("Cannot deserialize type #{type_name}")
      end
    end

    private def determine_type(value : CachableTypes) : String
      case value
      when Array
        determine_array_type(value)
      else
        determine_scalar_type(value)
      end
    end

    private def determine_scalar_type(value : CachableTypes) : String
      case value
      when String
        "String"
      when Int32
        "Int32"
      when Int64
        "Int64"
      when Float64
        "Float64"
      when Bool
        "Bool"
      when Time
        "Time"
      when UUID
        "UUID"
      when JSON::Any
        "JSON::Any"
      else
        "Unknown"
      end
    end

    private def determine_array_type(value : Array) : String
      case value
      when Array(String)
        "Array(String)"
      when Array(Int32)
        "Array(Int32)"
      when Array(Int64)
        "Array(Int64)"
      when Array(Float64)
        "Array(Float64)"
      when Array(Bool)
        "Array(Bool)"
      else
        "Unknown"
      end
    end
  end
end
