# Crystal Cross-Platform Demo - Collection Bridge Bindings
#
# High-level Crystal wrappers around the C collection bridge functions.
# Platform-specific code is gated with compile-time flag?() checks so
# only the relevant section compiles for each target.
#
# Usage:
#   require "./collection_bridge"
#
#   # ObjC (macOS/iOS):
#   views = [label_ptr, button_ptr, spacer_ptr]
#   ObjC::NSArray.from_pointers(views)
#
#   # JNI (Android):
#   JNI::ArrayList.create(env, [view1, view2])

# ==========================================================================
# ObjC Collection Bridge (macOS + iOS)
# ==========================================================================

{% if flag?(:darwin) || flag?(:macos) || flag?(:ios) %}
  # Low-level lib bindings for the C bridge functions.
  # These mirror the function signatures in collection_bridge.c exactly.
  @[Link(framework: "Foundation")]
  lib LibCollectionBridge
    # -- NSString --
    fun nsstring_create(utf8_str : UInt8*) : Void*
    fun nsstring_create_with_bytes(bytes : UInt8*, byte_len : UInt64) : Void*
    fun nsstring_to_utf8(nsstring : Void*, out_len : UInt64*) : UInt8*
    fun nsstring_length(nsstring : Void*) : UInt64

    # -- NSArray (immutable) --
    fun nsarray_create(objects : Void**, count : UInt64) : Void*
    fun nsarray_count(nsarray : Void*) : UInt64
    fun nsarray_object_at(nsarray : Void*, index : UInt64) : Void*
    fun nsarray_get_objects(nsarray : Void*, out_buf : Void**, count : UInt64)

    # -- NSMutableArray --
    fun nsmutablearray_create(capacity : UInt64) : Void*
    fun nsmutablearray_create_from(objects : Void**, count : UInt64) : Void*
    fun nsmutablearray_add(marray : Void*, object : Void*)
    fun nsmutablearray_insert(marray : Void*, object : Void*, index : UInt64)
    fun nsmutablearray_remove_at(marray : Void*, index : UInt64)
    fun nsmutablearray_remove_all(marray : Void*)
    fun nsmutablearray_add_batch(marray : Void*, objects : Void**, count : UInt64)
    fun nsmutablearray_count(marray : Void*) : UInt64
    fun nsmutablearray_object_at(marray : Void*, index : UInt64) : Void*

    # -- NSDictionary --
    fun nsdictionary_create(keys : Void**, values : Void**, count : UInt64) : Void*
    fun nsmutabledictionary_create(capacity : UInt64) : Void*
    fun nsmutabledictionary_set(mdict : Void*, key : Void*, value : Void*)
    fun nsdictionary_get(dict : Void*, key : Void*) : Void*
    fun nsdictionary_all_keys(dict : Void*) : Void*
    fun nsdictionary_count(dict : Void*) : UInt64

    # -- Batch view ops --
    fun nsstack_set_views(stack_view : Void*, views : Void**, count : UInt64, gravity : Int64)
    fun objc_add_subviews_batch(parent : Void*, children : Void**, count : UInt64)

    # -- Autorelease pool --
    fun autorelease_pool_push : Void*
    fun autorelease_pool_pop(pool : Void*)

    # -- Retain/Release --
    fun objc_retain_object(obj : Void*) : Void*
    fun objc_release_object(obj : Void*)
    fun objc_autorelease_object(obj : Void*) : Void*
  end

  module ObjC
    # ==========================================================================
    # Autorelease pool scoping.
    #
    # Every render pass should be wrapped in an autorelease scope:
    #   ObjC.autoreleasepool do
    #     array = ObjC::NSArray.from_views(children)
    #     ObjC.stack_set_views(stack, array)
    #   end
    # ==========================================================================
    def self.autoreleasepool(&)
      pool = LibCollectionBridge.autorelease_pool_push
      begin
        yield
      ensure
        LibCollectionBridge.autorelease_pool_pop(pool)
      end
    end

    # Retain an ObjC object (+1). Use when storing a reference in Crystal
    # that must outlive the current autorelease scope.
    def self.retain(obj : Void*) : Void*
      LibCollectionBridge.objc_retain_object(obj)
    end

    # Release an ObjC object (-1). Call when Crystal no longer needs
    # a retained reference.
    def self.release(obj : Void*)
      LibCollectionBridge.objc_release_object(obj)
    end

    # ==========================================================================
    # NSString wrapper
    #
    # Memory ownership:
    #   .from_string / .from_bytes -> AUTORELEASED. Crystal does not own it.
    #     If you need to store it, call nsstring.retain.
    #   .to_string -> Returns a Crystal String (GC-managed copy).
    #     The NSString can be released afterward.
    # ==========================================================================
    struct NSString
      getter ptr : Void*

      def initialize(@ptr : Void*)
      end

      # Create from a Crystal String.
      # The Crystal string is copied into ObjC memory.
      # Returns an autoreleased NSString.
      def self.from_string(str : String) : NSString
        # Use the byte-length variant so embedded NULs are preserved.
        ptr = LibCollectionBridge.nsstring_create_with_bytes(
          str.to_unsafe, str.bytesize.to_u64)
        NSString.new(ptr)
      end

      # Shorthand for common case (no embedded NULs).
      def self.from_cstr(str : String) : NSString
        ptr = LibCollectionBridge.nsstring_create(str.to_unsafe)
        NSString.new(ptr)
      end

      # Convert back to Crystal String.
      # Makes a copy of the UTF-8 bytes so the NSString can be released.
      def to_string : String
        len = uninitialized UInt64
        utf8_ptr = LibCollectionBridge.nsstring_to_utf8(@ptr, pointerof(len))
        String.new(utf8_ptr, len.to_i32)
      end

      # UTF-16 code unit count.
      def length : UInt64
        LibCollectionBridge.nsstring_length(@ptr)
      end

      # Retain this NSString (+1). Returns self for chaining.
      def retain : NSString
        LibCollectionBridge.objc_retain_object(@ptr)
        self
      end

      # Release this NSString (-1).
      def release
        LibCollectionBridge.objc_release_object(@ptr)
      end
    end

    # ==========================================================================
    # NSArray wrapper (immutable)
    #
    # Memory ownership:
    #   .from_pointers -> AUTORELEASED. The array retains its elements.
    #   .from_views    -> AUTORELEASED. Convenience for view arrays.
    #   [index]        -> BORROWED pointer, owned by the array.
    # ==========================================================================
    struct NSArray
      getter ptr : Void*

      def initialize(@ptr : Void*)
      end

      # Create from a Crystal array of ObjC object pointers.
      # This is the primary batch marshalling operation.
      #
      # Example:
      #   ptrs = [label.ptr, button.ptr, spacer.ptr]
      #   arr = ObjC::NSArray.from_pointers(ptrs)
      def self.from_pointers(objects : Array(Void*)) : NSArray
        ptr = LibCollectionBridge.nsarray_create(
          objects.to_unsafe, objects.size.to_u64)
        NSArray.new(ptr)
      end

      # Create from a Slice (avoids Array allocation when building from
      # a stack buffer or pre-allocated region).
      def self.from_slice(objects : Slice(Void*)) : NSArray
        ptr = LibCollectionBridge.nsarray_create(
          objects.to_unsafe, objects.size.to_u64)
        NSArray.new(ptr)
      end

      def size : UInt64
        LibCollectionBridge.nsarray_count(@ptr)
      end

      def [](index : Int) : Void*
        LibCollectionBridge.nsarray_object_at(@ptr, index.to_u64)
      end

      # Copy all elements into a new Crystal Array(Void*).
      def to_a : Array(Void*)
        count = size
        buf = Array(Void*).new(count.to_i32, Pointer(Void).null)
        LibCollectionBridge.nsarray_get_objects(@ptr, buf.to_unsafe, count)
        buf
      end

      # Iterate over elements.
      def each(&)
        count = size
        i = 0_u64
        while i < count
          yield LibCollectionBridge.nsarray_object_at(@ptr, i)
          i += 1
        end
      end

      def retain : NSArray
        LibCollectionBridge.objc_retain_object(@ptr)
        self
      end

      def release
        LibCollectionBridge.objc_release_object(@ptr)
      end
    end

    # ==========================================================================
    # NSMutableArray wrapper
    #
    # Memory ownership:
    #   .new(capacity)     -> AUTORELEASED.
    #   .from_pointers     -> AUTORELEASED.
    #   add/insert/remove  -> Mutates in place. The array manages element retain counts.
    # ==========================================================================
    struct NSMutableArray
      getter ptr : Void*

      def initialize(@ptr : Void*)
      end

      # Create empty with capacity hint.
      def self.new(capacity : Int = 0) : NSMutableArray
        ptr = LibCollectionBridge.nsmutablearray_create(capacity.to_u64)
        NSMutableArray.new(ptr)
      end

      # Create pre-populated from a Crystal array of pointers.
      def self.from_pointers(objects : Array(Void*)) : NSMutableArray
        ptr = LibCollectionBridge.nsmutablearray_create_from(
          objects.to_unsafe, objects.size.to_u64)
        NSMutableArray.new(ptr)
      end

      def add(object : Void*)
        LibCollectionBridge.nsmutablearray_add(@ptr, object)
      end

      def <<(object : Void*) : NSMutableArray
        add(object)
        self
      end

      def insert(object : Void*, at index : Int)
        LibCollectionBridge.nsmutablearray_insert(@ptr, object, index.to_u64)
      end

      def remove_at(index : Int)
        LibCollectionBridge.nsmutablearray_remove_at(@ptr, index.to_u64)
      end

      def clear
        LibCollectionBridge.nsmutablearray_remove_all(@ptr)
      end

      # Batch add: append multiple objects in one bridge crossing.
      def add_batch(objects : Array(Void*))
        LibCollectionBridge.nsmutablearray_add_batch(
          @ptr, objects.to_unsafe, objects.size.to_u64)
      end

      def size : UInt64
        LibCollectionBridge.nsmutablearray_count(@ptr)
      end

      def [](index : Int) : Void*
        LibCollectionBridge.nsmutablearray_object_at(@ptr, index.to_u64)
      end

      def retain : NSMutableArray
        LibCollectionBridge.objc_retain_object(@ptr)
        self
      end

      def release
        LibCollectionBridge.objc_release_object(@ptr)
      end
    end

    # ==========================================================================
    # NSDictionary wrapper
    #
    # Memory ownership:
    #   .from_hash          -> AUTORELEASED.
    #   .from_string_hash   -> AUTORELEASED. Convenience for String->String.
    #   [key]               -> BORROWED, owned by the dictionary.
    # ==========================================================================
    struct NSDictionary
      getter ptr : Void*

      def initialize(@ptr : Void*)
      end

      # Create from parallel arrays of ObjC object pointers.
      def self.from_pointers(keys : Array(Void*), values : Array(Void*)) : NSDictionary
        count = keys.size
        raise "keys and values must have same size" if count != values.size
        ptr = LibCollectionBridge.nsdictionary_create(
          keys.to_unsafe, values.to_unsafe, count.to_u64)
        NSDictionary.new(ptr)
      end

      # Create from a Crystal Hash(String, String).
      # Both keys and values are converted to NSString.
      # This is the common case for view properties.
      #
      # Example:
      #   props = {"accessibilityLabel" => "Submit button", "tag" => "42"}
      #   dict = ObjC::NSDictionary.from_string_hash(props)
      def self.from_string_hash(hash : Hash(String, String)) : NSDictionary
        keys = Array(Void*).new(hash.size)
        values = Array(Void*).new(hash.size)

        hash.each do |k, v|
          keys << LibCollectionBridge.nsstring_create(k.to_unsafe).as(Void*)
          values << LibCollectionBridge.nsstring_create(v.to_unsafe).as(Void*)
        end

        from_pointers(keys, values)
      end

      def [](key : Void*) : Void*
        LibCollectionBridge.nsdictionary_get(@ptr, key)
      end

      def [](key : String) : Void*
        ns_key = LibCollectionBridge.nsstring_create(key.to_unsafe)
        LibCollectionBridge.nsdictionary_get(@ptr, ns_key)
      end

      def keys : NSArray
        NSArray.new(LibCollectionBridge.nsdictionary_all_keys(@ptr))
      end

      def size : UInt64
        LibCollectionBridge.nsdictionary_count(@ptr)
      end

      def retain : NSDictionary
        LibCollectionBridge.objc_retain_object(@ptr)
        self
      end

      def release
        LibCollectionBridge.objc_release_object(@ptr)
      end
    end

    # ==========================================================================
    # NSMutableDictionary wrapper
    # ==========================================================================
    struct NSMutableDictionary
      getter ptr : Void*

      def initialize(@ptr : Void*)
      end

      def self.new(capacity : Int = 0) : NSMutableDictionary
        ptr = LibCollectionBridge.nsmutabledictionary_create(capacity.to_u64)
        NSMutableDictionary.new(ptr)
      end

      def []=(key : Void*, value : Void*)
        LibCollectionBridge.nsmutabledictionary_set(@ptr, key, value)
      end

      # Convenience: set with Crystal strings.
      def []=(key : String, value : String)
        ns_key = LibCollectionBridge.nsstring_create(key.to_unsafe)
        ns_val = LibCollectionBridge.nsstring_create(value.to_unsafe)
        LibCollectionBridge.nsmutabledictionary_set(@ptr, ns_key, ns_val)
      end

      def [](key : Void*) : Void*
        LibCollectionBridge.nsdictionary_get(@ptr, key)
      end

      def [](key : String) : Void*
        ns_key = LibCollectionBridge.nsstring_create(key.to_unsafe)
        LibCollectionBridge.nsdictionary_get(@ptr, ns_key)
      end

      def size : UInt64
        LibCollectionBridge.nsdictionary_count(@ptr)
      end

      def retain : NSMutableDictionary
        LibCollectionBridge.objc_retain_object(@ptr)
        self
      end

      def release
        LibCollectionBridge.objc_release_object(@ptr)
      end
    end

    # ==========================================================================
    # Batch view helpers
    # ==========================================================================

    # Set all arranged subviews of an NSStackView at once.
    # gravity: 0 = top/leading, 1 = center, 2 = bottom/trailing
    #
    # Example (VStack):
    #   child_ptrs = children.map(&.native_ptr)
    #   ObjC.stack_set_views(stack_view_ptr, child_ptrs, gravity: 1)
    def self.stack_set_views(stack_view : Void*, views : Array(Void*), gravity : Int64 = 1_i64)
      LibCollectionBridge.nsstack_set_views(
        stack_view, views.to_unsafe, views.size.to_u64, gravity)
    end

    # Add multiple subviews to any NSView/UIView at once.
    # Single bridge crossing instead of N.
    def self.add_subviews_batch(parent : Void*, children : Array(Void*))
      LibCollectionBridge.objc_add_subviews_batch(
        parent, children.to_unsafe, children.size.to_u64)
    end
  end
{% end %} # flag?(:darwin)

# ==========================================================================
# JNI Collection Bridge (Android)
# ==========================================================================

{% if flag?(:android) %}
  # JNI environment pointer type.
  # On Android, every native method receives JNIEnv* as the first argument.
  alias JNIEnv = Void*

  lib LibJNICollectionBridge
    # -- jstring --
    fun jni_string_create(env : JNIEnv, utf8_str : UInt8*) : Void*
    fun jni_string_create_with_bytes(env : JNIEnv, bytes : UInt8*, byte_len : Int32) : Void*
    fun jni_string_to_utf8(env : JNIEnv, jstr : Void*, out_len : Int32*) : UInt8*
    fun jni_string_release_utf8(env : JNIEnv, jstr : Void*, utf8 : UInt8*)
    fun jni_string_length(env : JNIEnv, jstr : Void*) : Int32

    # -- jobjectArray --
    fun jni_object_array_create(env : JNIEnv, element_class : UInt8*,
                                objects : Void**, count : Int32) : Void*
    fun jni_object_array_length(env : JNIEnv, jarr : Void*) : Int32
    fun jni_object_array_get(env : JNIEnv, jarr : Void*, index : Int32) : Void*

    # -- ArrayList --
    fun jni_arraylist_create(env : JNIEnv, objects : Void**, count : Int32) : Void*
    fun jni_arraylist_size(env : JNIEnv, list : Void*) : Int32
    fun jni_arraylist_get(env : JNIEnv, list : Void*, index : Int32) : Void*
    fun jni_arraylist_add(env : JNIEnv, list : Void*, object : Void*)
    fun jni_arraylist_remove_at(env : JNIEnv, list : Void*, index : Int32) : Void*
    fun jni_arraylist_clear(env : JNIEnv, list : Void*)

    # -- Batch ViewGroup ops --
    fun jni_viewgroup_add_views_batch(env : JNIEnv, view_group : Void*,
                                      children : Void**, count : Int32)
    fun jni_viewgroup_remove_all(env : JNIEnv, view_group : Void*)

    # -- Reference management --
    fun jni_new_global_ref(env : JNIEnv, local_ref : Void*) : Void*
    fun jni_delete_global_ref(env : JNIEnv, global_ref : Void*)
    fun jni_delete_local_ref(env : JNIEnv, local_ref : Void*)
    fun jni_push_local_frame(env : JNIEnv, capacity : Int32) : Int32
    fun jni_pop_local_frame(env : JNIEnv, result : Void*) : Void*

    # -- HashMap --
    fun jni_hashmap_create_string_string(env : JNIEnv, keys : UInt8**,
                                         values : UInt8**, count : Int32) : Void*
  end

  module JNI
    # ==========================================================================
    # Local reference frame scoping.
    #
    # JNI has a limited local reference table (default 512 entries).
    # Bracket batch operations with a local frame to avoid exhaustion.
    #
    #   JNI.local_frame(env, capacity: 64) do
    #     # create up to 64 local refs safely
    #   end
    # ==========================================================================
    def self.local_frame(env : JNIEnv, capacity : Int32 = 32, &)
      if LibJNICollectionBridge.jni_push_local_frame(env, capacity) < 0
        raise "JNI: PushLocalFrame failed (out of memory)"
      end
      begin
        result = yield
        LibJNICollectionBridge.jni_pop_local_frame(env, Pointer(Void).null)
        result
      rescue ex
        LibJNICollectionBridge.jni_pop_local_frame(env, Pointer(Void).null)
        raise ex
      end
    end

    # ==========================================================================
    # JString wrapper
    #
    # Memory ownership:
    #   .from_string     -> JNI LOCAL ref. Must be used before the native method
    #                       returns (or the local frame pops).
    #                       Call .to_global to promote to a global ref.
    #   .to_string       -> Crystal String (GC-managed copy). The jstring can
    #                       then be freed.
    # ==========================================================================
    struct JString
      getter ptr : Void*
      getter env : JNIEnv

      def initialize(@env : JNIEnv, @ptr : Void*)
      end

      # Create from a Crystal String.
      def self.from_string(env : JNIEnv, str : String) : JString
        # Use byte-length variant to handle embedded NULs correctly.
        ptr = LibJNICollectionBridge.jni_string_create_with_bytes(
          env, str.to_unsafe, str.bytesize.to_i32)
        JString.new(env, ptr)
      end

      # Fast path for simple strings (no embedded NULs).
      def self.from_cstr(env : JNIEnv, str : String) : JString
        ptr = LibJNICollectionBridge.jni_string_create(env, str.to_unsafe)
        JString.new(env, ptr)
      end

      # Convert to Crystal String (copies the data).
      def to_string : String
        len = uninitialized Int32
        utf8_ptr = LibJNICollectionBridge.jni_string_to_utf8(@env, @ptr, pointerof(len))
        begin
          String.new(utf8_ptr, len)
        ensure
          LibJNICollectionBridge.jni_string_release_utf8(@env, @ptr, utf8_ptr)
        end
      end

      # UTF-16 code unit count.
      def length : Int32
        LibJNICollectionBridge.jni_string_length(@env, @ptr)
      end

      # Promote to a global reference (survives beyond current native call).
      # Returns a new JString backed by a global ref.
      # Caller MUST call .delete_global when done.
      def to_global : JString
        global = LibJNICollectionBridge.jni_new_global_ref(@env, @ptr)
        JString.new(@env, global)
      end

      # Delete this local reference (free a slot).
      def delete_local
        LibJNICollectionBridge.jni_delete_local_ref(@env, @ptr)
      end

      # Delete a global reference.
      def delete_global
        LibJNICollectionBridge.jni_delete_global_ref(@env, @ptr)
      end
    end

    # ==========================================================================
    # ObjectArray wrapper (fixed-size Java array)
    #
    # Memory ownership:
    #   .create -> JNI LOCAL ref.
    #   [index] -> JNI LOCAL ref (new ref each call -- delete when done).
    # ==========================================================================
    struct ObjectArray
      getter ptr : Void*
      getter env : JNIEnv

      def initialize(@env : JNIEnv, @ptr : Void*)
      end

      # Create from a Crystal array of JNI object pointers.
      # element_class: JNI class descriptor (e.g., "android/view/View").
      def self.create(env : JNIEnv, element_class : String,
                      objects : Array(Void*)) : ObjectArray
        ptr = LibJNICollectionBridge.jni_object_array_create(
          env, element_class.to_unsafe,
          objects.to_unsafe, objects.size.to_i32)
        ObjectArray.new(env, ptr)
      end

      def size : Int32
        LibJNICollectionBridge.jni_object_array_length(@env, @ptr)
      end

      def [](index : Int) : Void*
        LibJNICollectionBridge.jni_object_array_get(@env, @ptr, index.to_i32)
      end

      def delete_local
        LibJNICollectionBridge.jni_delete_local_ref(@env, @ptr)
      end
    end

    # ==========================================================================
    # ArrayList wrapper (dynamic Java list)
    #
    # Memory ownership:
    #   .create / .new  -> JNI LOCAL ref.
    #   add/remove      -> Mutates in place. The list manages element refs.
    #   [index]         -> JNI LOCAL ref.
    # ==========================================================================
    struct ArrayList
      getter ptr : Void*
      getter env : JNIEnv

      def initialize(@env : JNIEnv, @ptr : Void*)
      end

      # Create pre-populated from a Crystal array of JNI object pointers.
      def self.create(env : JNIEnv, objects : Array(Void*)) : ArrayList
        ptr = LibJNICollectionBridge.jni_arraylist_create(
          env, objects.to_unsafe, objects.size.to_i32)
        ArrayList.new(env, ptr)
      end

      # Create empty.
      def self.create(env : JNIEnv) : ArrayList
        empty = Array(Void*).new(0)
        ptr = LibJNICollectionBridge.jni_arraylist_create(
          env, empty.to_unsafe, 0)
        ArrayList.new(env, ptr)
      end

      def size : Int32
        LibJNICollectionBridge.jni_arraylist_size(@env, @ptr)
      end

      def [](index : Int) : Void*
        LibJNICollectionBridge.jni_arraylist_get(@env, @ptr, index.to_i32)
      end

      def add(object : Void*)
        LibJNICollectionBridge.jni_arraylist_add(@env, @ptr, object)
      end

      def <<(object : Void*) : ArrayList
        add(object)
        self
      end

      def remove_at(index : Int) : Void*
        LibJNICollectionBridge.jni_arraylist_remove_at(@env, @ptr, index.to_i32)
      end

      def clear
        LibJNICollectionBridge.jni_arraylist_clear(@env, @ptr)
      end

      def to_global : ArrayList
        global = LibJNICollectionBridge.jni_new_global_ref(@env, @ptr)
        ArrayList.new(@env, global)
      end

      def delete_local
        LibJNICollectionBridge.jni_delete_local_ref(@env, @ptr)
      end

      def delete_global
        LibJNICollectionBridge.jni_delete_global_ref(@env, @ptr)
      end
    end

    # ==========================================================================
    # Batch ViewGroup helpers
    # ==========================================================================

    # Add multiple child views to a ViewGroup in one bridge crossing.
    def self.viewgroup_add_views(env : JNIEnv, view_group : Void*,
                                 children : Array(Void*))
      LibJNICollectionBridge.jni_viewgroup_add_views_batch(
        env, view_group, children.to_unsafe, children.size.to_i32)
    end

    # Remove all child views from a ViewGroup.
    def self.viewgroup_remove_all(env : JNIEnv, view_group : Void*)
      LibJNICollectionBridge.jni_viewgroup_remove_all(env, view_group)
    end

    # ==========================================================================
    # HashMap helper (for view properties)
    # ==========================================================================

    # Create a Java HashMap<String,String> from a Crystal Hash.
    # Returns a JNI LOCAL ref.
    def self.hashmap_from_strings(env : JNIEnv, hash : Hash(String, String)) : Void*
      keys = Array(Pointer(UInt8)).new(hash.size)
      values = Array(Pointer(UInt8)).new(hash.size)

      hash.each do |k, v|
        keys << k.to_unsafe
        values << v.to_unsafe
      end

      LibJNICollectionBridge.jni_hashmap_create_string_string(
        env, keys.to_unsafe, values.to_unsafe, hash.size.to_i32)
    end
  end
{% end %} # flag?(:android)
