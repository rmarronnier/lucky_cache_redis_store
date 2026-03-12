require "../spec_helper"
require "redis"

private def project_root : String
  File.expand_path("../..", __DIR__)
end

private def with_cache(prefix = "spec:#{UUID.random}:", &)
  redis_client = Redis::Client.new
  cache = LuckyCache::RedisStore.new(redis_client, prefix: prefix)
  cache.flush

  begin
    yield cache, redis_client
  ensure
    cache.flush
  end
end

private def read_item(cache : LuckyCache::RedisStore, key : String) : LuckyCache::CacheItem
  cache.read(key) || raise "Expected cache item for #{key}"
end

describe LuckyCache::RedisStore do
  describe "entrypoint" do
    it "loads standalone without requiring lucky_cache first" do
      output = IO::Memory.new
      error = IO::Memory.new
      binary_path = "/tmp/lucky_cache_redis_store_entrypoint_check"

      begin
        status = Process.run(
          "crystal",
          ["build", "src/lucky_cache_redis_store.cr", "-o", binary_path],
          chdir: project_root,
          output: output,
          error: error
        )

        raise "standalone require failed\nstdout:\n#{output}\nstderr:\n#{error}" unless status.success?

        File.exists?(binary_path).should eq(true)
      ensure
        File.delete(binary_path) if File.exists?(binary_path)
      end
    end
  end

  describe "#fetch" do
    it "raises an error for custom cachable objects" do
      with_cache do |cache, _|
        expect_raises(ArgumentError, "RedisStore cannot serialize custom Cachable objects") do
          cache.write("user") { User.new("test@example.com") }
        end
      end
    end

    it "caches basic types" do
      with_cache do |cache, _|
        cache.fetch("string:key", as: String) { "test" }.should eq("test")
        cache.fetch("int:key", as: Int64) { 0_i64 }.should eq(0_i64)
        cache.fetch("bool:key", as: Bool) { false }.should eq(false)
        cache.fetch("time:key", as: Time) { Time.local(1999, 10, 31, 18, 30) }.should eq(Time.local(1999, 10, 31, 18, 30))
      end
    end

    it "caches arrays of basic types" do
      with_cache do |cache, _|
        cache.fetch("strings", as: Array(String)) { ["hello", "world"] }.should eq(["hello", "world"])
        cache.fetch("ints", as: Array(Int32)) { [1, 2, 3] }.should eq([1, 2, 3])
        cache.fetch("bools", as: Array(Bool)) { [true, false, true] }.should eq([true, false, true])
      end
    end

    it "supports sub-second expirations" do
      with_cache do |cache, _|
        cache.fetch("coupon", expires_in: 750.milliseconds, as: UUID) { UUID.random }

        cache.read("coupon").should_not be_nil
        sleep 900.milliseconds
        cache.read("coupon").should be_nil
      end
    end
  end

  describe "#read" do
    it "returns nil when no key is found" do
      with_cache do |cache, _|
        cache.read("missing").should be_nil
      end
    end

    it "returns nil when the item is expired" do
      with_cache do |cache, _|
        cache.write("key", expires_in: 1.second) { "some data" }

        sleep 1200.milliseconds
        cache.read("key").should be_nil
      end
    end

    it "preserves the original ttl and absolute expiration after deserialization" do
      with_cache do |cache, _|
        cache.write("key", expires_in: 2.seconds) { "some data" }

        sleep 1.second
        item = read_item(cache, "key")
        item.expires_in.should eq(2.seconds)
        item.expired?.should eq(false)

        sleep 1200.milliseconds
        item.expired?.should eq(true)
        cache.read("key").should be_nil
      end
    end
  end

  describe "#write" do
    it "supports JSON::Any values" do
      with_cache do |cache, _|
        json = JSON.parse(%({"name": "test", "count": 42}))
        cache.write("json_data") { json }

        result = read_item(cache, "json_data").value.as(JSON::Any)
        result["name"].as_s.should eq("test")
        result["count"].as_i.should eq(42)
      end
    end

    it "stores UUID values" do
      with_cache do |cache, _|
        uuid = UUID.random
        cache.write("uuid_key") { uuid }

        read_item(cache, "uuid_key").value.as(UUID).should eq(uuid)
      end
    end

    it "stores arrays of basic types" do
      with_cache do |cache, _|
        str_array = ["hello", "world"]
        int_array = [1, 2, 3]
        bool_array = [true, false, true]

        cache.write("strings") { str_array }
        cache.write("ints") { int_array }
        cache.write("bools") { bool_array }

        read_item(cache, "strings").value.as(Array(String)).should eq(str_array)
        read_item(cache, "ints").value.as(Array(Int32)).should eq(int_array)
        read_item(cache, "bools").value.as(Array(Bool)).should eq(bool_array)
      end
    end

    it "rejects ttl values below one millisecond" do
      with_cache do |cache, _|
        expect_raises(ArgumentError, "expires_in must be at least 1 millisecond") do
          cache.write("tiny", expires_in: 500.microseconds) { "value" }
        end
      end
    end

    it "rejects zero ttl values" do
      with_cache do |cache, _|
        expect_raises(ArgumentError, "expires_in must be at least 1 millisecond") do
          cache.write("zero", expires_in: 0.seconds) { "value" }
        end
      end
    end

    it "rejects negative ttl values" do
      with_cache do |cache, _|
        expect_raises(ArgumentError, "expires_in must be at least 1 millisecond") do
          cache.write("negative", expires_in: -1.second) { "value" }
        end
      end
    end
  end

  describe "#delete" do
    it "returns nil when no item exists" do
      with_cache do |cache, _|
        cache.delete("key").should be_nil
      end
    end

    it "deletes the value from cache" do
      with_cache do |cache, _|
        cache.write("key") { 123 }
        cache.read("key").should_not be_nil

        cache.delete("key").should eq(1)
        cache.read("key").should be_nil
      end
    end
  end

  describe "#flush" do
    it "removes only keys for the configured prefix" do
      redis_client = Redis::Client.new
      main_cache = LuckyCache::RedisStore.new(redis_client, prefix: "spec:flush:main:")
      other_cache = LuckyCache::RedisStore.new(redis_client, prefix: "spec:flush:other:")

      begin
        main_cache.flush
        other_cache.flush
        redis_client.del("spec:flush:outside")

        main_cache.write("numbers") { 123 }
        main_cache.write("letters") { "abc" }
        other_cache.write("letters") { "keep me" }
        redis_client.set("spec:flush:outside", "keep me")

        main_cache.flush

        main_cache.read("numbers").should be_nil
        main_cache.read("letters").should be_nil
        read_item(other_cache, "letters").value.as(String).should eq("keep me")
        redis_client.get("spec:flush:outside").should eq("keep me")
      ensure
        main_cache.flush
        other_cache.flush
        redis_client.del("spec:flush:outside")
      end
    end
  end

  describe "#size" do
    it "counts only items for the configured prefix" do
      redis_client = Redis::Client.new
      main_cache = LuckyCache::RedisStore.new(redis_client, prefix: "spec:size:main:")
      other_cache = LuckyCache::RedisStore.new(redis_client, prefix: "spec:size:other:")

      begin
        main_cache.flush
        other_cache.flush
        redis_client.del("spec:size:outside")

        main_cache.size.should eq(0)

        main_cache.write("numbers") { 123 }
        main_cache.write("letters") { "abc" }
        other_cache.write("letters") { "elsewhere" }
        redis_client.set("spec:size:outside", "value")

        main_cache.size.should eq(2)
        other_cache.size.should eq(1)
      ensure
        main_cache.flush
        other_cache.flush
        redis_client.del("spec:size:outside")
      end
    end
  end

  describe "with custom prefix" do
    it "uses the custom prefix for keys" do
      with_cache("myapp:") do |cache, redis_client|
        cache.write("test") { "value" }

        redis_client.get("myapp:test").should_not be_nil
      end
    end
  end

  describe "workaround for custom objects" do
    it "can cache JSON representations of custom objects" do
      with_cache do |cache, _|
        user_data = {
          "email" => JSON::Any.new("fred@email.net"),
        }

        cache.write("user:fred") { JSON::Any.new(user_data) }

        cached_data = read_item(cache, "user:fred").value.as(JSON::Any)
        cached_data["email"].as_s.should eq("fred@email.net")
      end
    end
  end
end

class User
  include LuckyCache::Cachable
  property email : String

  def initialize(@email : String)
  end
end
