# LuckyCache Redis Store

A Redis storage backend for [LuckyCache](https://github.com/luckyframework/lucky_cache/), providing distributed caching capabilities for Lucky Framework applications.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     lucky_cache_redis_store:
       github: luckyframework/lucky_cache_redis_store
   ```

2. Run `shards install`

## Usage

```crystal
require "lucky_cache_redis_store"

LuckyCache.configure do |settings|
  settings.storage = LuckyCache::RedisStore.new(
    Redis::Client.new(host: "localhost", port: 6379),
    prefix: "myapp:cache:"
  )
  settings.default_duration = 5.minutes
end
```

### Basic Usage

```crystal
cache = LuckyCache.settings.storage

# Write to cache
cache.write("my_key", expires_in: 1.hour) { "my value" }

# Read from cache
if item = cache.read("my_key")
  puts item.value # => "my value"
end

# Fetch (read-through cache)
value = cache.fetch("computed_key", as: String, expires_in: 10.minutes) do
  # This block is only executed if the key doesn't exist
  expensive_computation
end

# Delete from cache
cache.delete("my_key")

# Clear all cached items with the configured prefix
cache.flush
```

## Expiration Semantics

- `expires_in` is stored with millisecond precision.
- TTL values must be at least `1.millisecond`.
- `0.seconds`, negative durations, and positive durations below `1.millisecond` raise `ArgumentError`.
- `read` restores cache items with their original TTL metadata and the correct absolute expiration time.

## Prefix Operations

- `flush` removes only keys that match the store's configured prefix.
- `size` counts only keys that match the configured prefix.
- Both operations iterate Redis with `SCAN`, not `KEYS`, so they remain safer on larger keyspaces.

### Supported Types

The Redis store supports the following types:
- Basic types: `String`, `Int32`, `Int64`, `Float64`, `Bool`, `Time`, `UUID`, `JSON::Any`
- Arrays of basic types: `Array(String)`, `Array(Int32)`, `Array(Int64)`, `Array(Float64)`, `Array(Bool)`

**Note:** Custom objects that include `LuckyCache::Cachable` are not supported by RedisStore due to serialization limitations. Use MemoryStore for caching custom objects.

### Workaround for Custom Objects

You can cache JSON representations of your objects:

```crystal
# Instead of caching the object directly
# cache.write("user:123") { User.new("test@example.com") } # This will raise an error

# Cache a JSON representation
user_data = {
  "id" => JSON::Any.new(123_i64),
  "email" => JSON::Any.new("test@example.com"),
}
cache.write("user:123") { JSON::Any.new(user_data) }

# Retrieve and reconstruct
cached_data = cache.read("user:123").not_nil!.value.as(JSON::Any)
user = User.new(cached_data["email"].as_s)
```

## Development

To run the tests:

1. Make sure Redis is running locally on the default port (`6379`)
2. Run `crystal spec`

The test suite includes tests for:
- Basic type caching
- Array type caching
- Millisecond TTL handling and TTL validation
- Expiration correctness after Redis deserialization
- Key deletion, prefix-scoped flushing, and prefix-scoped sizing
- Standalone shard loading
- Custom prefix support
- Error handling for non-serializable types

## Contributing

1. Fork it (<https://github.com/your-github-user/lucky_cache_redis_store/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jeremy Woertink](https://github.com/jwoertink) - creator and maintainer
