// Crystal Cross-Platform Demo - Collection Bridge
//
// Marshals Crystal collections (Array, Hash, String) to/from native
// platform collections (NSArray, NSDictionary, NSString for ObjC;
// jobjectArray, ArrayList, jstring for JNI).
//
// DESIGN PRINCIPLES:
//   1. Batch operations: pass entire arrays across the bridge in one call.
//      For a VStack with 20 children, that's 1 bridge crossing not 20.
//   2. Clear ownership: every function documents who owns the returned
//      object and whether the caller must release it.
//   3. Autorelease pool scoping: callers manage @autoreleasepool boundaries.
//      These helpers return autoreleased objects by default (ObjC convention
//      for convenience constructors), or +1 retained where noted.
//   4. JNI local reference hygiene: batch helpers use PushLocalFrame /
//      PopLocalFrame to avoid exhausting the default 512-ref limit.
//
// Compile (macOS/iOS):
//   clang -c collection_bridge.c -o collection_bridge.o -fobjc-arc
//   (or without ARC -- all functions use explicit retain/release/autorelease)
//
// Compile (Android, within NDK):
//   $NDK_CLANG --target=aarch64-linux-android31 -c collection_bridge.c \
//     -o collection_bridge.o -I$JAVA_HOME/include

// ============================================================================
// Platform gate: compile only the relevant section
// ============================================================================

#if defined(__APPLE__)
// ============================================================================
//
//  SECTION 1: Objective-C Collection Bridge (macOS + iOS)
//
// ============================================================================

#include <objc/runtime.h>
#include <objc/message.h>
#include <string.h>
#include <stdlib.h>

// Forward: we use these ObjC classes via the runtime
// NSString, NSArray, NSMutableArray, NSDictionary, NSMutableDictionary,
// NSAutoreleasePool, NSNumber

// ---- Selector cache (initialized on first use) ----
// Caching selectors avoids repeated sel_registerName lookups in hot loops.

static SEL sel_alloc                   = 0;
static SEL sel_init                    = 0;
static SEL sel_autorelease             = 0;
static SEL sel_retain                  = 0;
static SEL sel_release                 = 0;
static SEL sel_count                   = 0;
static SEL sel_objectAtIndex           = 0;
static SEL sel_addObject               = 0;
static SEL sel_removeObjectAtIndex     = 0;
static SEL sel_insertObjectAtIndex     = 0;
static SEL sel_replaceObjectAtIndex    = 0;
static SEL sel_removeAllObjects        = 0;
static SEL sel_setObjectForKey         = 0;
static SEL sel_objectForKey            = 0;
static SEL sel_allKeys                 = 0;
static SEL sel_stringWithUTF8String    = 0;
static SEL sel_UTF8String              = 0;
static SEL sel_length                  = 0;
static SEL sel_lengthOfBytesUsingEnc   = 0;
static SEL sel_initWithCapacity        = 0;
static SEL sel_arrayWithObjectsCount   = 0;

static void ensure_selectors(void) {
    if (sel_alloc) return; // already initialized
    sel_alloc                 = sel_registerName("alloc");
    sel_init                  = sel_registerName("init");
    sel_autorelease           = sel_registerName("autorelease");
    sel_retain                = sel_registerName("retain");
    sel_release               = sel_registerName("release");
    sel_count                 = sel_registerName("count");
    sel_objectAtIndex         = sel_registerName("objectAtIndex:");
    sel_addObject             = sel_registerName("addObject:");
    sel_removeObjectAtIndex   = sel_registerName("removeObjectAtIndex:");
    sel_insertObjectAtIndex   = sel_registerName("insertObject:atIndex:");
    sel_replaceObjectAtIndex  = sel_registerName("replaceObject:atIndex:withObject:");
    sel_removeAllObjects      = sel_registerName("removeAllObjects");
    sel_setObjectForKey       = sel_registerName("setObject:forKey:");
    sel_objectForKey          = sel_registerName("objectForKey:");
    sel_allKeys               = sel_registerName("allKeys");
    sel_stringWithUTF8String  = sel_registerName("stringWithUTF8String:");
    sel_UTF8String            = sel_registerName("UTF8String");
    sel_length                = sel_registerName("length");
    sel_lengthOfBytesUsingEnc = sel_registerName("lengthOfBytesUsingEncoding:");
    sel_initWithCapacity      = sel_registerName("initWithCapacity:");
    sel_arrayWithObjectsCount = sel_registerName("arrayWithObjects:count:");
}

// ============================================================================
// 1A. NSString <-> Crystal String
// ============================================================================

// Create an autoreleased NSString from a UTF-8 C string.
// Ownership: AUTORELEASED (+0). Caller does NOT own; lives until pool drains.
// Crystal side should retain if storing beyond the current autorelease scope.
void* nsstring_create(const char* utf8_str) {
    ensure_selectors();
    void* cls = (void*)objc_getClass("NSString");
    return ((void* (*)(void*, SEL, const char*))objc_msgSend)(
        cls, sel_stringWithUTF8String, utf8_str);
}

// Create an NSString from UTF-8 bytes with explicit length.
// Handles strings with embedded NULs (Crystal strings can contain \0).
// Ownership: AUTORELEASED (+0).
void* nsstring_create_with_bytes(const char* bytes, unsigned long byte_len) {
    ensure_selectors();
    void* cls = (void*)objc_getClass("NSString");
    // NSString initWithBytes:length:encoding: (NSUTF8StringEncoding = 4)
    SEL sel_initWithBytes = sel_registerName("initWithBytes:length:encoding:");
    void* obj = ((void* (*)(void*, SEL))objc_msgSend)(cls, sel_alloc);
    obj = ((void* (*)(void*, SEL, const char*, unsigned long, unsigned long))objc_msgSend)(
        obj, sel_initWithBytes, bytes, byte_len, 4UL);
    return ((void* (*)(void*, SEL))objc_msgSend)(obj, sel_autorelease);
}

// Extract UTF-8 bytes from an NSString.
// Returns a pointer to an internal buffer valid until the NSString is released.
// Ownership: The returned pointer is BORROWED. Do NOT free it.
//            Crystal must copy the bytes before the NSString goes away.
// out_len receives the byte length (not including any NUL terminator).
const char* nsstring_to_utf8(void* nsstring, unsigned long* out_len) {
    ensure_selectors();
    const char* cstr = ((const char* (*)(void*, SEL))objc_msgSend)(
        nsstring, sel_UTF8String);
    // lengthOfBytesUsingEncoding: NSUTF8StringEncoding (4)
    unsigned long byte_len = ((unsigned long (*)(void*, SEL, unsigned long))objc_msgSend)(
        nsstring, sel_lengthOfBytesUsingEnc, 4UL);
    if (out_len) *out_len = byte_len;
    return cstr;
}

// Get NSString character count (UTF-16 code units, same as -[NSString length]).
unsigned long nsstring_length(void* nsstring) {
    ensure_selectors();
    return ((unsigned long (*)(void*, SEL))objc_msgSend)(nsstring, sel_length);
}

// ============================================================================
// 1B. NSArray (immutable) from C array of id pointers
// ============================================================================

// Create an autoreleased NSArray from a C array of ObjC object pointers.
// This is the primary batch operation: Crystal builds a Slice(Void*) of
// native view pointers, passes it across the bridge ONCE.
//
// Ownership: AUTORELEASED (+0). The array retains its elements.
//            Caller does NOT own the returned NSArray.
// Parameters:
//   objects - C array of (id) pointers; each must be a valid ObjC object
//   count   - number of elements
void* nsarray_create(const void** objects, unsigned long count) {
    ensure_selectors();
    void* cls = (void*)objc_getClass("NSArray");
    return ((void* (*)(void*, SEL, const void**, unsigned long))objc_msgSend)(
        cls, sel_arrayWithObjectsCount, objects, count);
}

// Get the count of an NSArray.
unsigned long nsarray_count(void* nsarray) {
    ensure_selectors();
    return ((unsigned long (*)(void*, SEL))objc_msgSend)(nsarray, sel_count);
}

// Get an object at index from NSArray.
// Ownership: BORROWED (+0). The object is owned by the array.
void* nsarray_object_at(void* nsarray, unsigned long index) {
    ensure_selectors();
    return ((void* (*)(void*, SEL, unsigned long))objc_msgSend)(
        nsarray, sel_objectAtIndex, index);
}

// Copy all NSArray elements into a caller-provided C buffer.
// Useful for reading an ObjC collection back into Crystal.
// The buffer must have room for nsarray_count(nsarray) pointers.
// Ownership: Each pointer in out_buf is BORROWED from the array.
void nsarray_get_objects(void* nsarray, void** out_buf, unsigned long count) {
    ensure_selectors();
    for (unsigned long i = 0; i < count; i++) {
        out_buf[i] = ((void* (*)(void*, SEL, unsigned long))objc_msgSend)(
            nsarray, sel_objectAtIndex, i);
    }
}

// ============================================================================
// 1C. NSMutableArray with add/remove/insert/replace
// ============================================================================

// Create an autoreleased NSMutableArray with an initial capacity hint.
// Ownership: AUTORELEASED (+0).
void* nsmutablearray_create(unsigned long capacity) {
    ensure_selectors();
    void* cls = (void*)objc_getClass("NSMutableArray");
    void* obj = ((void* (*)(void*, SEL))objc_msgSend)(cls, sel_alloc);
    obj = ((void* (*)(void*, SEL, unsigned long))objc_msgSend)(
        obj, sel_initWithCapacity, capacity);
    return ((void* (*)(void*, SEL))objc_msgSend)(obj, sel_autorelease);
}

// Create an NSMutableArray pre-populated from a C array (batch init).
// Ownership: AUTORELEASED (+0).
void* nsmutablearray_create_from(const void** objects, unsigned long count) {
    ensure_selectors();
    void* cls = (void*)objc_getClass("NSMutableArray");
    // Create immutable first, then mutableCopy
    void* immutable = ((void* (*)(void*, SEL, const void**, unsigned long))objc_msgSend)(
        cls, sel_arrayWithObjectsCount, objects, count);
    SEL sel_mutableCopy = sel_registerName("mutableCopy");
    void* mutable_arr = ((void* (*)(void*, SEL))objc_msgSend)(immutable, sel_mutableCopy);
    // mutableCopy returns +1; autorelease to match convention
    return ((void* (*)(void*, SEL))objc_msgSend)(mutable_arr, sel_autorelease);
}

// Append an object to NSMutableArray.
void nsmutablearray_add(void* marray, void* object) {
    ensure_selectors();
    ((void (*)(void*, SEL, void*))objc_msgSend)(marray, sel_addObject, object);
}

// Insert an object at index.
void nsmutablearray_insert(void* marray, void* object, unsigned long index) {
    ensure_selectors();
    ((void (*)(void*, SEL, void*, unsigned long))objc_msgSend)(
        marray, sel_insertObjectAtIndex, object, index);
}

// Remove the object at index.
void nsmutablearray_remove_at(void* marray, unsigned long index) {
    ensure_selectors();
    ((void (*)(void*, SEL, unsigned long))objc_msgSend)(
        marray, sel_removeObjectAtIndex, index);
}

// Remove all objects.
void nsmutablearray_remove_all(void* marray) {
    ensure_selectors();
    ((void (*)(void*, SEL))objc_msgSend)(marray, sel_removeAllObjects);
}

// Batch add: append count objects from a C array.
// More efficient than calling nsmutablearray_add in a loop because
// this is a single bridge crossing.
void nsmutablearray_add_batch(void* marray, const void** objects, unsigned long count) {
    ensure_selectors();
    for (unsigned long i = 0; i < count; i++) {
        ((void (*)(void*, SEL, void*))objc_msgSend)(
            marray, sel_addObject, (void*)objects[i]);
    }
}

// Get count of NSMutableArray (same as NSArray).
unsigned long nsmutablearray_count(void* marray) {
    return nsarray_count(marray);
}

// Get object at index (same as NSArray).
void* nsmutablearray_object_at(void* marray, unsigned long index) {
    return nsarray_object_at(marray, index);
}

// ============================================================================
// 1D. NSDictionary / NSMutableDictionary
// ============================================================================

// Create an autoreleased NSDictionary from parallel C arrays of keys and values.
// keys[i] and values[i] must be valid ObjC objects (typically NSString).
// Ownership: AUTORELEASED (+0). The dictionary retains its keys and values.
void* nsdictionary_create(const void** keys, const void** values, unsigned long count) {
    ensure_selectors();
    void* cls = (void*)objc_getClass("NSDictionary");
    SEL sel_dictWithObjsForKeys = sel_registerName("dictionaryWithObjects:forKeys:count:");
    return ((void* (*)(void*, SEL, const void**, const void**, unsigned long))objc_msgSend)(
        cls, sel_dictWithObjsForKeys, values, keys, count);
}

// Create an autoreleased empty NSMutableDictionary with capacity hint.
// Ownership: AUTORELEASED (+0).
void* nsmutabledictionary_create(unsigned long capacity) {
    ensure_selectors();
    void* cls = (void*)objc_getClass("NSMutableDictionary");
    void* obj = ((void* (*)(void*, SEL))objc_msgSend)(cls, sel_alloc);
    obj = ((void* (*)(void*, SEL, unsigned long))objc_msgSend)(
        obj, sel_initWithCapacity, capacity);
    return ((void* (*)(void*, SEL))objc_msgSend)(obj, sel_autorelease);
}

// Set a key-value pair in NSMutableDictionary.
void nsmutabledictionary_set(void* mdict, void* key, void* value) {
    ensure_selectors();
    ((void (*)(void*, SEL, void*, void*))objc_msgSend)(
        mdict, sel_setObjectForKey, value, key);
}

// Get a value for key from NSDictionary.
// Ownership: BORROWED (+0), owned by the dictionary.
void* nsdictionary_get(void* dict, void* key) {
    ensure_selectors();
    return ((void* (*)(void*, SEL, void*))objc_msgSend)(dict, sel_objectForKey, key);
}

// Get all keys as NSArray.
// Ownership: AUTORELEASED (+0).
void* nsdictionary_all_keys(void* dict) {
    ensure_selectors();
    return ((void* (*)(void*, SEL))objc_msgSend)(dict, sel_allKeys);
}

// Get count.
unsigned long nsdictionary_count(void* dict) {
    ensure_selectors();
    return ((unsigned long (*)(void*, SEL))objc_msgSend)(dict, sel_count);
}

// ============================================================================
// 1E. Batch view operations (NSStackView / UIStackView helpers)
// ============================================================================

// Set all arranged subviews of an NSStackView at once.
// Calls setViews:inGravity: with NSStackViewGravityCenter (2).
// Much faster than N individual addArrangedSubview: calls.
//
// Parameters:
//   stack_view - the NSStackView (id)
//   views      - C array of NSView* pointers
//   count      - number of views
//   gravity    - NSStackViewGravity (0=top/leading, 1=center, 2=bottom/trailing)
void nsstack_set_views(void* stack_view, const void** views, unsigned long count,
                       long gravity) {
    ensure_selectors();
    // First create an NSArray from the views
    void* cls = (void*)objc_getClass("NSArray");
    void* views_array = ((void* (*)(void*, SEL, const void**, unsigned long))objc_msgSend)(
        cls, sel_arrayWithObjectsCount, views, count);

    // setViews:inGravity:
    SEL sel_setViewsInGravity = sel_registerName("setViews:inGravity:");
    ((void (*)(void*, SEL, void*, long))objc_msgSend)(
        stack_view, sel_setViewsInGravity, views_array, gravity);
}

// Add multiple subviews to any NSView/UIView in one bridge crossing.
// Iterates on the C side to avoid N Crystal->C transitions.
void objc_add_subviews_batch(void* parent, const void** children, unsigned long count) {
    SEL sel_addSubview = sel_registerName("addSubview:");
    for (unsigned long i = 0; i < count; i++) {
        ((void (*)(void*, SEL, void*))objc_msgSend)(
            parent, sel_addSubview, (void*)children[i]);
    }
}

// ============================================================================
// 1F. Autorelease pool management
// ============================================================================

// Push a new autorelease pool. Returns the pool object.
// Every push MUST be matched by a pop.
// Crystal code should bracket render passes with push/pop.
void* autorelease_pool_push(void) {
    ensure_selectors();
    void* cls = (void*)objc_getClass("NSAutoreleasePool");
    void* pool = ((void* (*)(void*, SEL))objc_msgSend)(cls, sel_alloc);
    return ((void* (*)(void*, SEL))objc_msgSend)(pool, sel_init);
}

// Drain and release an autorelease pool.
// All autoreleased objects created since the matching push are released.
void autorelease_pool_pop(void* pool) {
    ensure_selectors();
    SEL sel_drain = sel_registerName("drain");
    ((void (*)(void*, SEL))objc_msgSend)(pool, sel_drain);
}

// ============================================================================
// 1G. Retain / Release helpers (for Crystal to manage ownership)
// ============================================================================

// Retain an ObjC object. Returns the object.
// Use when Crystal needs to store a reference beyond the current autorelease scope.
void* objc_retain_object(void* obj) {
    ensure_selectors();
    return ((void* (*)(void*, SEL))objc_msgSend)(obj, sel_retain);
}

// Release an ObjC object. Crystal calls this when it no longer needs the reference.
void objc_release_object(void* obj) {
    ensure_selectors();
    ((void (*)(void*, SEL))objc_msgSend)(obj, sel_release);
}

// Autorelease an ObjC object. Returns the object.
void* objc_autorelease_object(void* obj) {
    ensure_selectors();
    return ((void* (*)(void*, SEL))objc_msgSend)(obj, sel_autorelease);
}

#endif // __APPLE__


#if defined(__ANDROID__) || defined(ANDROID)
// ============================================================================
//
//  SECTION 2: JNI Collection Bridge (Android)
//
// ============================================================================

#include <jni.h>
#include <string.h>
#include <stdlib.h>

// The JNIEnv pointer is thread-local in Android. All JNI bridge functions
// receive it as the first parameter (passed from Crystal, which gets it
// from the JNI entry points).

// ============================================================================
// 2A. jstring <-> Crystal String (Modified UTF-8)
// ============================================================================

// Create a jstring from a UTF-8 C string.
// JNI uses Modified UTF-8 internally. For strings without embedded NULs
// or supplementary characters (U+10000+), standard UTF-8 == Modified UTF-8.
// For the common case of UI text this is fine.
//
// Ownership: Returns a JNI LOCAL reference. Must be used or deleted before
//            returning from the native method (or before 512 local refs).
//            If Crystal needs to store it, call jni_new_global_ref.
void* jni_string_create(JNIEnv* env, const char* utf8_str) {
    return (void*)(*env)->NewStringUTF(env, utf8_str);
}

// Create a jstring from bytes with explicit length.
// For strings with embedded NULs, we must go through byte[] -> new String(bytes, "UTF-8").
void* jni_string_create_with_bytes(JNIEnv* env, const char* bytes, int byte_len) {
    // Fast path: no embedded NULs
    int has_nul = 0;
    for (int i = 0; i < byte_len; i++) {
        if (bytes[i] == '\0') { has_nul = 1; break; }
    }
    if (!has_nul) {
        // Temporarily NUL-terminate
        char* tmp = (char*)malloc(byte_len + 1);
        if (!tmp) return NULL;
        memcpy(tmp, bytes, byte_len);
        tmp[byte_len] = '\0';
        jstring result = (*env)->NewStringUTF(env, tmp);
        free(tmp);
        return (void*)result;
    }

    // Slow path: use byte array -> String constructor
    jbyteArray barr = (*env)->NewByteArray(env, byte_len);
    if (!barr) return NULL;
    (*env)->SetByteArrayRegion(env, barr, 0, byte_len, (const jbyte*)bytes);

    jclass str_cls = (*env)->FindClass(env, "java/lang/String");
    jmethodID ctor = (*env)->GetMethodID(env, str_cls, "<init>", "([BLjava/lang/String;)V");
    jstring charset = (*env)->NewStringUTF(env, "UTF-8");
    jstring result = (*env)->NewObject(env, str_cls, ctor, barr, charset);

    (*env)->DeleteLocalRef(env, barr);
    (*env)->DeleteLocalRef(env, charset);
    (*env)->DeleteLocalRef(env, str_cls);

    return (void*)result;
}

// Extract UTF-8 bytes from a jstring.
// Returns a pointer to a JNI-managed buffer. Crystal must copy the data.
// Call jni_string_release_utf8 when done.
//
// out_len receives the byte length.
// Ownership: BORROWED. Must call jni_string_release_utf8 after copying.
const char* jni_string_to_utf8(JNIEnv* env, void* jstr, int* out_len) {
    const char* utf8 = (*env)->GetStringUTFChars(env, (jstring)jstr, NULL);
    if (out_len) {
        *out_len = (int)(*env)->GetStringUTFLength(env, (jstring)jstr);
    }
    return utf8;
}

// Release the UTF-8 buffer obtained from jni_string_to_utf8.
void jni_string_release_utf8(JNIEnv* env, void* jstr, const char* utf8) {
    (*env)->ReleaseStringUTFChars(env, (jstring)jstr, utf8);
}

// Get jstring length in UTF-16 code units.
int jni_string_length(JNIEnv* env, void* jstr) {
    return (int)(*env)->GetStringLength(env, (jstring)jstr);
}

// ============================================================================
// 2B. jobjectArray creation from C array
// ============================================================================

// Create a jobjectArray from a C array of jobject pointers.
// element_class is the Java class of the elements (e.g., "android/view/View").
//
// Ownership: Returns a JNI LOCAL reference.
//
// Uses PushLocalFrame/PopLocalFrame for reference safety when count is large.
void* jni_object_array_create(JNIEnv* env, const char* element_class_name,
                               const void** objects, int count) {
    jclass element_class = (*env)->FindClass(env, element_class_name);
    if (!element_class) return NULL;

    jobjectArray arr = (*env)->NewObjectArray(env, count, element_class, NULL);
    if (!arr) {
        (*env)->DeleteLocalRef(env, element_class);
        return NULL;
    }

    for (int i = 0; i < count; i++) {
        (*env)->SetObjectArrayElement(env, arr, i, (jobject)objects[i]);
    }

    (*env)->DeleteLocalRef(env, element_class);
    return (void*)arr;
}

// Get count of a jobjectArray.
int jni_object_array_length(JNIEnv* env, void* jarr) {
    return (*env)->GetArrayLength(env, (jarray)jarr);
}

// Get element at index from jobjectArray.
// Ownership: Returns a JNI LOCAL reference.
void* jni_object_array_get(JNIEnv* env, void* jarr, int index) {
    return (void*)(*env)->GetObjectArrayElement(env, (jobjectArray)jarr, index);
}

// ============================================================================
// 2C. ArrayList<View> via JNI (for ViewGroup operations)
// ============================================================================

// Cached class/method IDs (per-thread via JNIEnv, but class IDs are global).
// We cache after first lookup since FindClass is expensive.

// Create a java.util.ArrayList and populate it from a C array.
// This is the JNI equivalent of NSMutableArray for Android.
//
// Ownership: Returns a JNI LOCAL reference.
void* jni_arraylist_create(JNIEnv* env, const void** objects, int count) {
    // Push local frame: count objects + ArrayList + class refs
    if ((*env)->PushLocalFrame(env, count + 8) < 0) return NULL;

    jclass cls = (*env)->FindClass(env, "java/util/ArrayList");
    if (!cls) { (*env)->PopLocalFrame(env, NULL); return NULL; }

    jmethodID ctor = (*env)->GetMethodID(env, cls, "<init>", "(I)V");
    jmethodID add  = (*env)->GetMethodID(env, cls, "add", "(Ljava/lang/Object;)Z");

    jobject list = (*env)->NewObject(env, cls, ctor, (jint)count);
    if (!list) { (*env)->PopLocalFrame(env, NULL); return NULL; }

    for (int i = 0; i < count; i++) {
        (*env)->CallBooleanMethod(env, list, add, (jobject)objects[i]);
    }

    // PopLocalFrame returns the list promoted out of the frame
    return (void*)(*env)->PopLocalFrame(env, list);
}

// Get the size of an ArrayList.
int jni_arraylist_size(JNIEnv* env, void* list) {
    jclass cls = (*env)->FindClass(env, "java/util/ArrayList");
    jmethodID size_mid = (*env)->GetMethodID(env, cls, "size", "()I");
    int result = (*env)->CallIntMethod(env, (jobject)list, size_mid);
    (*env)->DeleteLocalRef(env, cls);
    return result;
}

// Get element at index from ArrayList.
// Ownership: Returns a JNI LOCAL reference.
void* jni_arraylist_get(JNIEnv* env, void* list, int index) {
    jclass cls = (*env)->FindClass(env, "java/util/ArrayList");
    jmethodID get_mid = (*env)->GetMethodID(env, cls, "get", "(I)Ljava/lang/Object;");
    void* result = (void*)(*env)->CallObjectMethod(env, (jobject)list, get_mid, (jint)index);
    (*env)->DeleteLocalRef(env, cls);
    return result;
}

// Add an element to ArrayList.
void jni_arraylist_add(JNIEnv* env, void* list, void* object) {
    jclass cls = (*env)->FindClass(env, "java/util/ArrayList");
    jmethodID add_mid = (*env)->GetMethodID(env, cls, "add", "(Ljava/lang/Object;)Z");
    (*env)->CallBooleanMethod(env, (jobject)list, add_mid, (jobject)object);
    (*env)->DeleteLocalRef(env, cls);
}

// Remove element at index from ArrayList.
void* jni_arraylist_remove_at(JNIEnv* env, void* list, int index) {
    jclass cls = (*env)->FindClass(env, "java/util/ArrayList");
    jmethodID remove_mid = (*env)->GetMethodID(env, cls, "remove", "(I)Ljava/lang/Object;");
    void* result = (void*)(*env)->CallObjectMethod(env, (jobject)list, remove_mid, (jint)index);
    (*env)->DeleteLocalRef(env, cls);
    return result;
}

// Clear all elements from ArrayList.
void jni_arraylist_clear(JNIEnv* env, void* list) {
    jclass cls = (*env)->FindClass(env, "java/util/ArrayList");
    jmethodID clear_mid = (*env)->GetMethodID(env, cls, "clear", "()V");
    (*env)->CallVoidMethod(env, (jobject)list, clear_mid);
    (*env)->DeleteLocalRef(env, cls);
}

// ============================================================================
// 2D. Batch ViewGroup operations
// ============================================================================

// Add multiple child views to an Android ViewGroup in one bridge crossing.
// Equivalent to calling viewGroup.addView(child) for each child.
//
// Parameters:
//   env        - JNI environment
//   view_group - the ViewGroup (LinearLayout, etc.)
//   children   - C array of View jobject pointers
//   count      - number of children
void jni_viewgroup_add_views_batch(JNIEnv* env, void* view_group,
                                    const void** children, int count) {
    // Push frame: count children + ViewGroup class ref + method ID overhead
    if ((*env)->PushLocalFrame(env, count + 4) < 0) return;

    jclass cls = (*env)->FindClass(env, "android/view/ViewGroup");
    if (!cls) { (*env)->PopLocalFrame(env, NULL); return; }

    jmethodID addView = (*env)->GetMethodID(env, cls, "addView",
                                             "(Landroid/view/View;)V");

    for (int i = 0; i < count; i++) {
        (*env)->CallVoidMethod(env, (jobject)view_group, addView,
                               (jobject)children[i]);
    }

    (*env)->PopLocalFrame(env, NULL);
}

// Remove all views from a ViewGroup.
void jni_viewgroup_remove_all(JNIEnv* env, void* view_group) {
    jclass cls = (*env)->FindClass(env, "android/view/ViewGroup");
    jmethodID removeAll = (*env)->GetMethodID(env, cls, "removeAllViews", "()V");
    (*env)->CallVoidMethod(env, (jobject)view_group, removeAll);
    (*env)->DeleteLocalRef(env, cls);
}

// ============================================================================
// 2E. JNI reference management
// ============================================================================

// Create a global reference from a local reference.
// Global refs survive beyond the current native method call.
// Crystal objects that hold JNI references long-term must use these.
// Ownership: GLOBAL (+1). Must call jni_delete_global_ref when done.
void* jni_new_global_ref(JNIEnv* env, void* local_ref) {
    return (void*)(*env)->NewGlobalRef(env, (jobject)local_ref);
}

// Delete a global reference.
void jni_delete_global_ref(JNIEnv* env, void* global_ref) {
    (*env)->DeleteGlobalRef(env, (jobject)global_ref);
}

// Delete a local reference (free a slot in the local ref table).
void jni_delete_local_ref(JNIEnv* env, void* local_ref) {
    (*env)->DeleteLocalRef(env, (jobject)local_ref);
}

// Push a local reference frame. Crystal should bracket batch operations.
// capacity = expected number of local refs in this frame.
// Returns 0 on success, negative on failure.
int jni_push_local_frame(JNIEnv* env, int capacity) {
    return (*env)->PushLocalFrame(env, capacity);
}

// Pop a local reference frame. All local refs created since the
// matching push are freed. 'result' (if non-NULL) is promoted out of
// the frame as a local ref in the outer frame.
void* jni_pop_local_frame(JNIEnv* env, void* result) {
    return (void*)(*env)->PopLocalFrame(env, (jobject)result);
}

// ============================================================================
// 2F. HashMap<String, Object> via JNI (for view properties)
// ============================================================================

// Create a java.util.HashMap from parallel C arrays of key/value strings.
// For view properties like layout params, accessibility labels, etc.
//
// Ownership: Returns a JNI LOCAL reference.
void* jni_hashmap_create_string_string(JNIEnv* env,
                                        const char** keys,
                                        const char** values,
                                        int count) {
    if ((*env)->PushLocalFrame(env, count * 2 + 8) < 0) return NULL;

    jclass cls = (*env)->FindClass(env, "java/util/HashMap");
    jmethodID ctor = (*env)->GetMethodID(env, cls, "<init>", "(I)V");
    jmethodID put = (*env)->GetMethodID(env, cls, "put",
        "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");

    jobject map = (*env)->NewObject(env, cls, ctor, (jint)(count * 4 / 3 + 1));
    if (!map) { (*env)->PopLocalFrame(env, NULL); return NULL; }

    for (int i = 0; i < count; i++) {
        jstring jkey = (*env)->NewStringUTF(env, keys[i]);
        jstring jval = (*env)->NewStringUTF(env, values[i]);
        (*env)->CallObjectMethod(env, map, put, jkey, jval);
        // Local refs freed when frame pops
    }

    return (void*)(*env)->PopLocalFrame(env, map);
}

#endif // __ANDROID__
