// Crystal Cross-Platform Demo - Android JNI Bridge
//
// Bridges between Android Java and Crystal's exported C functions.
// Crystal functions are compiled into a .o object file, then this
// bridge is compiled and linked together into libcrystal.so.

#include <jni.h>
#include <android/log.h>

#define TAG "CrystalDemo"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

// Crystal functions (from app_core.cr compiled with --prelude=empty)
extern int crystal_add(int a, int b);
extern int crystal_multiply(int a, int b);
extern long long crystal_fibonacci(int n);
extern long long crystal_factorial(int n);
extern int crystal_get_platform_id(void);
extern long long crystal_power(int base, int exp);

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    LOGI("Crystal native library loaded");
    LOGI("crystal_add(17,25) = %d", crystal_add(17, 25));
    LOGI("crystal_fibonacci(20) = %lld", crystal_fibonacci(20));
    LOGI("crystal_get_platform_id() = %d", crystal_get_platform_id());
    return JNI_VERSION_1_6;
}

JNIEXPORT jint JNICALL
Java_com_crystal_demo_CrystalLib_add(JNIEnv *env, jclass cls, jint a, jint b) {
    return crystal_add(a, b);
}

JNIEXPORT jint JNICALL
Java_com_crystal_demo_CrystalLib_multiply(JNIEnv *env, jclass cls, jint a, jint b) {
    return crystal_multiply(a, b);
}

JNIEXPORT jlong JNICALL
Java_com_crystal_demo_CrystalLib_fibonacci(JNIEnv *env, jclass cls, jint n) {
    return crystal_fibonacci(n);
}

JNIEXPORT jlong JNICALL
Java_com_crystal_demo_CrystalLib_factorial(JNIEnv *env, jclass cls, jint n) {
    return crystal_factorial(n);
}

JNIEXPORT jint JNICALL
Java_com_crystal_demo_CrystalLib_getPlatformId(JNIEnv *env, jclass cls) {
    return crystal_get_platform_id();
}

JNIEXPORT jlong JNICALL
Java_com_crystal_demo_CrystalLib_power(JNIEnv *env, jclass cls, jint base, jint exp) {
    return crystal_power(base, exp);
}
