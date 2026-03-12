module LuckyCache
  struct CacheItem
    # Preserve the original TTL alongside the absolute expiration restored from Redis.
    def initialize(@value : CachableTypes, @expires_in : Time::Span, @expiration : Time)
    end
  end
end
